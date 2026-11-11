//
//  WorseQueryProbe.h
//  GestaltKitTool
//
//  Exploratory wrapper around the worse_query ContainerManager escape
//  that accepts arbitrary flags / part values, for probing MAC-blocked
//  paths (TCC.db, keychain-2.db…). Headless automation only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WorseQueryProbe : NSObject

/// Sends one worse_query for `path` with the given flags/part and
/// reports whether containermanagerd issued a sandbox token.
+ (BOOL)probePath:(NSString *)path flag:(uint64_t)flag part:(uint64_t)part;

/// Attempts a full read of `path` using the given flags/part combo.
+ (nullable NSData *)readPath:(NSString *)path flag:(uint64_t)flag part:(uint64_t)part;

/// Probes whether the sandbox extension granted by the given flags/part
/// allows opening `path` for writing (O_WRONLY). Does NOT write data.
+ (BOOL)probeWrite:(NSString *)path flag:(uint64_t)flag part:(uint64_t)part;

@end

NS_ASSUME_NONNULL_END
