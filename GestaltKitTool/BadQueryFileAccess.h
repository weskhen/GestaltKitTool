//
//  BadQueryFileAccess.h
//  GestaltKitTool
//
//  Generic file system access via bad_query path traversal.
//  Uses BadQueryLease to acquire sandbox extensions for arbitrary
//  absolute paths, enabling cross-application data reads and
//  system file inspection.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a directory entry (file or subdirectory).
@interface BQFileEntry : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *fullPath;
@property (nonatomic, assign, readonly) BOOL isDirectory;
@property (nonatomic, assign, readonly) long long fileSize;
@property (nonatomic, copy, readonly, nullable) NSDate *modificationDate;

@end

/// Provides read-only file system access to arbitrary paths using
/// bad_query sandbox extensions. Each operation acquires a fresh
/// lease for the target path.
@interface BadQueryFileAccess : NSObject

+ (instancetype)shared;

/// Reads the entire contents of a file at the given absolute path.
/// Returns nil and sets error if the file cannot be read.
- (nullable NSData *)readFileAtPath:(NSString *)path
                              error:(NSError **)error;

/// Lists the contents of a directory at the given absolute path.
/// Returns an empty array if the directory is empty or inaccessible.
- (NSArray<BQFileEntry *> *)listDirectoryAtPath:(NSString *)path
                                          error:(NSError **)error;

/// Returns metadata for a single file, or nil if it doesn't exist.
- (nullable BQFileEntry *)statFileAtPath:(NSString *)path
                                   error:(NSError **)error;

/// Recursively lists all files under a directory, up to a maximum
/// depth. Depth 0 means only the immediate contents.
- (NSArray<BQFileEntry *> *)recursiveListAtPath:(NSString *)path
                                      maxDepth:(NSInteger)maxDepth
                                         error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
