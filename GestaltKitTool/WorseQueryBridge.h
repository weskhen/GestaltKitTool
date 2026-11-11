//
//  WorseQueryBridge.h
//  GestaltKitTool
//
//  worse_query sandbox escape (successor to bad_query).
//  Discovered & published by Taj C (forcequit), GPL-3.0.
//  https://github.com/forcequitOS/worse_query
//
//  Mechanism (vs bad_query):
//    bad_query  : container class 13 (SystemGroup) with a
//                 "systemgroup.com.apple.mobilegestaltcache" identifier and a
//                 "../../.." path-traversal partDomain.
//    worse_query: container class 7 (appGroup) with an App Group identifier
//                 the app itself controls. The trick: replace the App Group's
//                 Library/Caches directory with a SYMLINK pointing at the
//                 escape target, then ask containermanagerd for the Caches
//                 directory. containermanagerd resolves the symlink BEFORE
//                 validating the path, and issues a sandbox extension for the
//                 REAL (escaped) path. The symlink is restored afterwards.
//
//  Supported (per author): iOS 26.0 – 26.7.2 / 27.2 (27.3 beta reported working).
//  Requires the com.apple.security.application-groups entitlement with a group
//  the app controls (see GestaltKitTool.entitlements).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES when the worse_query ContainerManager symbols are present
/// on this OS build (i.e. the exploit is potentially usable).
BOOL WorseQueryBridgeAvailable(void);

/// Returns YES when the current App Group container is accessible from this
/// process (entitlement present + container created). worse_query cannot work
/// without this.
BOOL WorseQueryGroupContainerAvailable(void);

/// The App Group identifier used by worse_query.
/// Default: "group.com.wesk.vtool" (matches the app's entitlement).
/// Override at runtime via NSUserDefaults key "GKTLAppGroupID"
/// (useful for sideload setups where the group name differs).
NSString *WorseQueryGroupIdentifier(void);

/// Runs the worse_query escape for `path` and returns a sandbox extension
/// handle (> 0) on success, or a negative error code:
///   -255 target doesn't exist (lstat pre-check failed)
///   -1   App Group container inaccessible
///   -2   ContainerManager symbols unavailable (unsupported OS)
///   -3   query creation failed
///   -4   symlink creation failed
///   -5   query rejected by containermanagerd
///   -6   kernel refused to issue the sandbox extension
///   -7   sandbox_extension_consume failed
///
/// The Library/Caches symlink is always cleaned up (real directory restored)
/// before this function returns — even on the failure paths. Serialized
/// process-wide with all other acquires (see WorseQueryEscapeLock).
int64_t WorseQueryAcquire(NSString *path, BOOL altFlags);

/// Releases a handle previously returned by WorseQueryAcquire.
void WorseQueryRelease(int64_t handle);

/// Exploratory variant with EXPLICIT flags and part values, used by
/// the --flag-scan automation to probe MAC-blocked paths (TCC.db,
/// keychain-2.db…). Returns a sandbox handle > 0 on success.
/// Pass 0 for flags/part to use worse_query defaults.
int64_t WorseQueryAcquireWithParams(NSString *path,
                                    uint64_t flags,
                                    uint64_t part);

NS_ASSUME_NONNULL_END
