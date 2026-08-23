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

/// Writes data to a file at the given absolute path using a bad_query
/// sandbox extension. The extension acquired with flags 0x8000000000
/// may grant read-write access; if the kernel denies writes, the
/// operation fails gracefully with an error.
/// Returns YES on success, NO + sets error on failure.
- (BOOL)writeFileAtPath:(NSString *)path
                    data:(NSData *)data
                   error:(NSError **)error;

/// Recursively copies a directory tree from source to destination.
/// Both paths must be absolute. The destination directory is created
/// if it doesn't exist. Returns the number of files copied, or -1 on
/// error (with error populated).
- (NSInteger)copyDirectoryFromPath:(NSString *)sourcePath
                      toDestination:(NSString *)destinationPath
                               error:(NSError **)error;

/// Deletes a single file at the given absolute path.
/// Uses a bad_query sandbox extension with RW flags.
/// Returns YES on success, NO + sets error on failure.
- (BOOL)deleteFileAtPath:(NSString *)path
                    error:(NSError **)error;

/// Recursively deletes all contents inside a directory (the directory
/// itself is preserved). Each child file is deleted via bad_query
/// sandbox extension; subdirectories are recursed into and then
/// emptied. Returns the number of items deleted, or -1 on error.
/// If `maxItems` > 0, deletion stops after that many items.
- (NSInteger)deleteDirectoryContentsAtPath:(NSString *)path
                                  maxItems:(NSInteger)maxItems
                                     error:(NSError **)error;

/// Creates a directory at the given absolute path.
/// Intermediate directories are created as needed.
/// Returns YES on success, NO + sets error on failure.
- (BOOL)createDirectoryAtPath:(NSString *)path
                         error:(NSError **)error;

/// Moves/renames a file from source to destination.
/// Both paths must be absolute. Returns YES on success.
- (BOOL)moveFileFromPath:(NSString *)sourcePath
                   toPath:(NSString *)destinationPath
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
