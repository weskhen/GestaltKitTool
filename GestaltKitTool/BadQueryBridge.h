//
//  BadQueryBridge.h
//  GestaltKitTool
//
//  Path-based ContainerManager query interface.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BadQueryLease : NSObject

@property(nonatomic, copy, readonly) NSString *targetPath;
@property(nonatomic, readonly, getter=isActive) BOOL active;

/// Acquire a sandbox extension for a specific **file** path.
/// Note: the kernel typically refuses to issue sandbox extensions
/// for directories — use bad_query_list_directory for those.
+ (nullable instancetype)leaseForPath:(NSString *)path
                                error:(NSString * _Nullable * _Nullable)error;
- (void)invalidate;

@end

/// Enumerate directory entries using fsgetpath (inode enumeration).
/// This bypasses the sandbox entirely — no extension needed.
/// Returns an array of absolute paths (one per entry).
/// `maxInode` limits the scan range; 200000 is a reasonable default.
/// The scan range is internally clamped to [1, 1_000_000] to prevent
/// runaway loops on filesystems with unusually high inode counts.
FOUNDATION_EXPORT NSArray<NSString *> *bad_query_list_directory(NSString *path, int64_t maxInode);

FOUNDATION_EXPORT BOOL BadQueryBridgeAvailable(void);

/// Probe various flag combinations to find one that grants read-write
/// access on the current iOS build. Diagnostic only — logs results
/// to NSLog with [GKTL-ObjC] prefix.
FOUNDATION_EXPORT void BadQueryProbeFlags(NSString *targetPath);

NS_ASSUME_NONNULL_END
