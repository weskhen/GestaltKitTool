//
//  BadQueryFileAccess.m
//  GestaltKitTool
//

#import "BadQueryFileAccess.h"
#import "BadQueryBridge.h"

#import <fcntl.h>
#import <limits.h>
#import <sys/stat.h>
#import <dirent.h>
#import <unistd.h>
#import <os/log.h>

// Unified logging macro — uses os_log, matching Swift-side GKTLLog.
// Migrated from NSLog to reduce console noise.
#undef GKTLLog
#define GKTLLog(fmt, ...) os_log(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__)

#pragma mark - Path helpers for stat-time correctness

/// Normalize /var/foo → /private/var/foo so that stat/lstat operates
/// on the REAL filesystem path instead of following the /var symlink.
///
/// Why this matters for modification dates:
///   stat("/var/mobile/...")    → follows the symlink → sandbox MAC
///                                 policy intercepts → returns st_mtime=0
///                                 → NSDate 1970-01-01 → UI "Jan 1"
///   stat("/private/var/...")  → direct real-path lookup → real mtime
///
/// Return nil for nil / empty input. Previously we returned the
/// empty string untouched, which then caused `-[NSString
/// fileSystemRepresentation]` to raise an
///   `NSInvalidArgumentException: Cannot form file system representation
///    of empty string`
/// exception on any downstream stat/opendir/realpath call.
/// Returning nil lets every call site guard with `if (!real) return`.
static NSString *BQNormalizeForStat(NSString *path)
{
    if (path.length == 0) return nil;
    if ([path hasPrefix:@"/private/"]) return path; // already real
    if ([path hasPrefix:@"/var/"]) {
        return [@"/private" stringByAppendingString:path];
    }
    return path;
}

/// Fill `outSt` for `path` using the real (/private/var) path form.
///
/// Behaviour:
///   1. Always lstat/stat the normalized real path first. One syscall.
///   2. ONLY acquire a bad_query lease if step 1 failed *completely*
///      (stat returned non-zero). If step 1 returned 0 but mtime=0, we
///      trust the kernel's result — inodes DO legitimately have mtime 0
///      on freshly-created-but-never-touched files, and retrying with a
///      lease for every single file would mean 200 XPC round-trips for
///      a 200-file directory, blocking the UI thread for 2–3 seconds
///      (this caused the "stuck on loading" regression reported by user).
///   3. If `allowLeaseRetry` is NO, skip the lease retry entirely. Used
///      by the fallback opendir branch which already holds a lease.
///
/// Returns YES on success, NO on complete failure.
static BOOL BQFillStatRetry(NSString *path, struct stat *outSt, BOOL followSymlink, BOOL allowLeaseRetry)
{
    if (!path || !outSt) return NO;
    NSString *real = BQNormalizeForStat(path);
    if (real.length == 0) return NO;  // protect against empty → FSRep crash
    const char *cpath = [real fileSystemRepresentation];
    if (!cpath) return NO;

    int (*statfn)(const char *, struct stat *) = followSymlink ? stat : lstat;
    if (statfn(cpath, outSt) == 0) {
        return YES; // took at face value — UI will show what we got
    }

    if (!allowLeaseRetry) return NO;

    // Stat failed outright — EACCES, ENOENT, or similar. Bad_query lease
    // retry is justified here (single-digit percent of files in practice,
    // not every file).
    NSString *detail = nil;
    BadQueryLease *lease = [BadQueryLease leaseForPath:real error:&detail];
    if (!lease) return NO;
    BOOL ok = statfn(cpath, outSt) == 0;
    [lease invalidate];
    return ok;
}

// Back-compat wrapper for call sites that always want the lease retry
// (statFileAtPath single-shot lookups, fsgetpath path where the caller
// has no outer lease active).
static BOOL BQFillStat(NSString *path, struct stat *outSt, BOOL followSymlink)
{
    return BQFillStatRetry(path, outSt, followSymlink, YES);
}

#pragma mark - Critical path guard

// Critical-path guard for mutating operations. Refuses writes,
// deletes, creates, and moves to /System/, /usr/, /bin/, /sbin/,
// /private/var/db/, /private/etc/. Uses realpath() to catch symlinks.
static NSArray<NSString *> *BQCriticalPaths(void)
{
    static NSArray<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @[
            @"/System/", @"/usr/", @"/bin/", @"/sbin/",
            @"/private/var/db/", @"/private/etc/"
        ];
    });
    return paths;
}

static BOOL BQIsCriticalSystemPath(NSString *path)
{
    NSArray<NSString *> *critical = BQCriticalPaths();
    for (NSString *prefix in critical) {
        if ([path hasPrefix:prefix]) return YES;
    }
    const char *pathC = path.fileSystemRepresentation;
    char resolved[PATH_MAX];
    if (realpath(pathC, resolved)) {
        NSString *resolvedPath = [NSString stringWithUTF8String:resolved];
        for (NSString *prefix in critical) {
            if ([resolvedPath hasPrefix:prefix]) return YES;
        }
    }
    return NO;
}

#pragma mark - BQFileEntry

@interface BQFileEntry ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *fullPath;
@property (nonatomic, assign, readwrite) BOOL isDirectory;
@property (nonatomic, assign, readwrite) long long fileSize;
@property (nonatomic, copy, readwrite, nullable) NSDate *modificationDate;
@end

@implementation BQFileEntry
@end

#pragma mark - BadQueryFileAccess

// Serial queue for all mutating operations (write, delete,
// createDirectory, move, copyDirectory, deleteDirectoryContents).
@interface BadQueryFileAccess ()
{
    dispatch_queue_t _mutationQueue;
}
@end

@implementation BadQueryFileAccess

- (instancetype)init
{
    self = [super init];
    if (self) {
        _mutationQueue = dispatch_queue_create("com.wesk.badquery.mutation", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (instancetype)shared
{
    static BadQueryFileAccess *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [BadQueryFileAccess new]; });
    return shared;
}
- (nullable NSData *)readFileAtPath:(NSString *)path error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return nil;
    }

    // MEMORY CAP. Cap the read at 16 MB; larger files return only
    // their first 16 MB so the preview stays cheap. Used by both the
    // lease-based read and the direct-read fallback.
    static const long long kMaxReadBytes = 16LL * 1024 * 1024;

    // Acquire a bad_query lease for the target path.
    NSString *badQueryDetail = nil;
    BadQueryLease *lease = [BadQueryLease leaseForPath:path
                                                 error:&badQueryDetail];
    if (!lease) {
        // Lease failed — but opendir (listDirectory) works WITHOUT
        // a lease for many paths (e.g. /var/mobile/Library/). Try direct
        // open() the same way opendir works. If the MAC policy allows
        // directory listing, it may also allow file reading.
        NSData *directData = [NSData dataWithContentsOfFile:path
                                                     options:NSDataReadingUncached
                                                       error:nil];
        if (directData != nil) {
            // Cap at 16 MB (same as leased read below).
            if (directData.length > kMaxReadBytes) {
                return [directData subdataWithRange:NSMakeRange(0, (NSUInteger)kMaxReadBytes)];
            }
            return directData;
        }
        // Both lease and direct read failed — genuine sandbox denial.
        if (error) *error = [self errorWithCode:2
                                         message:badQueryDetail ?: @"bad_query failed to acquire access."];
        return nil;
    }

    // The lease grants sandbox access, but we still read via NSFileManager
    // since the sandbox extension applies to the process.
    // Use NSDataReadingMappedIfSafe is dangerous here — the mmap'd
    // data remains backed by the file even after [lease invalidate],
    // causing SIGBUS when accessed. Instead, read into an allocated
    // buffer that's fully independent of the file mapping.
    //
    // MEMORY CAP: kMaxReadBytes limits direct reads to avoid jetsam kills
    // on large files (ATX .db stores, videos, .sqlite-wal).

    long long fileSize = 0;
    struct stat st;
    const char *pathC = [path fileSystemRepresentation];
    if (pathC && stat(pathC, &st) == 0) {
        fileSize = (long long)st.st_size;
    }

    NSData *data = nil;
    NSError *readError = nil;
    if (fileSize > kMaxReadBytes) {
        // Large file — stream only the first kMaxReadBytes.
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) {
            [lease invalidate];
            if (error) *error = [self errorWithCode:3
                                             message:@"Failed to open file for reading."];
            return nil;
        }
        data = [fh readDataOfLength:(NSUInteger)kMaxReadBytes];
        [fh closeFile];
        if (!data) {
            [lease invalidate];
            if (error) *error = [self errorWithCode:3
                                             message:@"Failed to read file data."];
            return nil;
        }
    } else {
        data = [NSData dataWithContentsOfFile:path
                                       options:0
                                         error:&readError];
    }
    [lease invalidate];

    if (!data) {
        if (error) *error = readError ?: [self errorWithCode:3
                                                      message:@"Failed to read file data."];
        return nil;
    }
    if (error) *error = nil;
    return data;
}

- (NSArray<BQFileEntry *> *)listDirectoryAtPath:(NSString *)path
                                           error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return @[];
    }

    // =====================================================================
    // Strategy: try opendir in priority order:
    //   1. opendir without lease (fastest, works for own container + world-readable dirs).
    //   2. opendir after acquiring a bad_query lease for the parent directory.
    //   3. fsgetpath inode-scan fallback (last resort, cap 350K inodes).
    // =====================================================================

    NSString *realDir = BQNormalizeForStat(path);
    if (realDir.length == 0) {
        if (error) *error = [self errorWithCode:2
                                         message:@"Invalid path encoding."];
        return @[];
    }
    const char *realDirC = [realDir fileSystemRepresentation];
    if (!realDirC) {
        if (error) *error = [self errorWithCode:2
                                         message:@"Invalid filesystem representation."];
        return @[];
    }

    NSMutableArray<BQFileEntry *> *(^collectFromDir)(DIR *) =
        ^NSMutableArray<BQFileEntry *> *(DIR *dir) {
        NSMutableArray<BQFileEntry *> *entries = [NSMutableArray array];
        // Track seen d_name to prevent duplicates from readdir.
        // On APFS with snapshots/clones, readdir can occasionally return
        // the same d_name twice (especially under MAC policy). This
        // NSMutableSet ensures each name appears only once.
        NSMutableSet<NSString *> *seenNames = [NSMutableSet set];
        struct dirent *de;
        while ((de = readdir(dir)) != NULL) {
            const char *d_name = de->d_name;
            if (strcmp(d_name, ".") == 0 || strcmp(d_name, "..") == 0) continue;

            // + d_name might not be valid UTF-8 on APFS
            // snapshots / FUSE mounts. Fall back to Latin-1 which
            // can never return nil (maps all 256 byte values 1:1).
            NSString *nameStr = [NSString stringWithUTF8String:d_name];
            if (!nameStr) {
                NSData *dNameData = [NSData dataWithBytesNoCopy:(void *)d_name
                                                         length:strnlen(d_name, sizeof(de->d_name))
                                                   freeWhenDone:NO];
                nameStr = [[NSString alloc] initWithData:dNameData
                                                encoding:NSISOLatin1StringEncoding];
            }
            if (nameStr.length == 0) continue;

            // Skip duplicates (same d_name returned twice by readdir).
            if ([seenNames containsObject:nameStr]) {
                os_log(OS_LOG_DEFAULT, "[GKTL-ObjC] DUPLICATE-d_name skipped: %{public}@", nameStr);
                continue;
            }
            [seenNames addObject:nameStr];

            BQFileEntry *entry = [BQFileEntry new];
            entry.name = nameStr;
            entry.fullPath = [realDir stringByAppendingPathComponent:nameStr];

            // Reliable d_type from the kernel's dirent — 100% truth.
            switch (de->d_type) {
                case DT_DIR:  entry.isDirectory = YES; break;
                case DT_LNK:  entry.isDirectory = NO;  break; // treat as file; browse fallback would work anyway
                case DT_REG:  entry.isDirectory = NO;  break;
                default:
                    // DT_FIFO / DT_CHR / DT_BLK / DT_SOCK / DT_WHT
                    // Treat as non-directory; browse will fallback.
                    entry.isDirectory = NO;
                    break;
            }

            // Try to stat for size + mtime (no XPC — instant). Even if
            // the directory opened without a lease, most child paths
            // inside a listed directory respond to direct lstat.
            //
            // (mtime=0 fix): On iOS 26 with MAC policy, lstat
            // succeeds but st_mtime is frequently 0 (epoch 1970) for
            // sandboxed paths under /private/var/mobile/... and
            // /private/var/containers/... — the kernel returns the
            // inode metadata but MAC scrubs the timestamps. Showing
            // "1970-01-01 08:00" to the user is worse than showing
            // nothing, so treat mtime==0 as "no date available".
            // stat() follows symlinks
            // which failed outright under MAC → modificationDate
            // stayed nil → no misleading date shown.
            struct stat st;
            const char *ep = [entry.fullPath fileSystemRepresentation];
            if (ep && lstat(ep, &st) == 0) {
                entry.isDirectory = S_ISDIR(st.st_mode); // override d_type for symlink→dir if we followed
                entry.fileSize = (long long)st.st_size;
                // Only set modificationDate if mtime is a real
                // Unix timestamp (> 0). mtime=0 almost always means MAC
                // scrubbing, not a real "Jan 1 1970" file.
                if (st.st_mtime > 0) {
                    entry.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtime];
                } else {
                    entry.modificationDate = nil;
                }
            } else if (ep && stat(ep, &st) == 0) {
                entry.isDirectory = S_ISDIR(st.st_mode);
                entry.fileSize = (long long)st.st_size;
                if (st.st_mtime > 0) {
                    entry.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtime];
                } else {
                    entry.modificationDate = nil;
                }
            }

            if (entry.fullPath.length == 0) continue;
            [entries addObject:entry];
        }
        return entries;
    };

    // ——————————————————————————————————————————————————————————
    // Phase 1: opendir with NO lease (fastest, no XPC, most reliable)
    // ——————————————————————————————————————————————————————————
    DIR *dir = opendir(realDirC);
    if (dir) {
        NSMutableArray<BQFileEntry *> *entries = collectFromDir(dir);
        closedir(dir);
        if (entries.count > 0 || errno == 0) {
            // Got entries or a legitimately empty directory.
            if (error) *error = nil;
            [entries sortUsingComparator:^NSComparisonResult(BQFileEntry *a, BQFileEntry *b) {
                if (a.isDirectory != b.isDirectory) {
                    return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                }
                return [a.name localizedCaseInsensitiveCompare:b.name];
            }];
            return entries;
        }
    }

    // ——————————————————————————————————————————————————————————
    // Phase 2: acquire one directory lease, then opendir (1 XPC call)
    // ——————————————————————————————————————————————————————————
    NSString *leaseDetail = nil;
    BadQueryLease *lease = [BadQueryLease leaseForPath:path error:&leaseDetail];
    if (lease) {
        DIR *dir2 = opendir(realDirC);
        if (dir2) {
            NSMutableArray<BQFileEntry *> *entries = collectFromDir(dir2);
            closedir(dir2);
            [lease invalidate];
            if (error) *error = nil;
            [entries sortUsingComparator:^NSComparisonResult(BQFileEntry *a, BQFileEntry *b) {
                if (a.isDirectory != b.isDirectory) {
                    return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                }
                return [a.name localizedCaseInsensitiveCompare:b.name];
            }];
            return entries;
        }
        [lease invalidate];
    }

    // ——————————————————————————————————————————————————————————
    // Phase 3 (fallback): fsgetpath inode scan
    //
    // Only reached when opendir was not possible even with a lease.
    // This path exists for completeness; in practice most containers
    // list successfully in Phase 1 or 2.
    // ——————————————————————————————————————————————————————————
    NSArray<NSString *> *childPaths = bad_query_list_directory(path, 350000);

    if (childPaths.count == 0) {
        if (error) *error = [self errorWithCode:2
                                         message:leaseDetail ?: @"Directory listing failed. The directory may be empty or inaccessible."];
        return @[];
    }

    NSMutableArray<BQFileEntry *> *entries = [NSMutableArray array];
    NSMutableArray<BQFileEntry *> *entriesNeedingLease = [NSMutableArray array];
    // dedupe by normalized childPath (fsgetpath can return
    // /var/X and /private/var/X for the same inode).
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    for (NSString *childPath in childPaths) {
        if (childPath.length == 0) continue;

        // normalize for dedup (strip /private, lowercase).
        NSString *normPath = [childPath stringByStandardizingPath];
        if ([normPath hasPrefix:@"/private/"]) {
            normPath = [normPath substringFromIndex:@"/private".length];
        }
        NSString *key = [normPath lowercaseString];
        if ([seenPaths containsObject:key]) continue;
        [seenPaths addObject:key];

        BQFileEntry *entry = [BQFileEntry new];
        entry.fullPath = childPath;

        NSString *name = childPath.lastPathComponent;
        if (name.length == 0) name = childPath;
        if (name.length == 0) name = @"(unnamed)";
        entry.name = name;

        struct stat st;
        const char *cpath = [childPath fileSystemRepresentation];
        if (!cpath) {
            entry.isDirectory = NO;
            entry.fileSize = 0;
            entry.modificationDate = nil;
            [entries addObject:entry];
            continue;
        }

        if (lstat(cpath, &st) == 0) {
            entry.isDirectory = S_ISDIR(st.st_mode);
            entry.fileSize = (long long)st.st_size;
            // mtime=0 means MAC scrubbing, not a real epoch date.
            entry.modificationDate = (st.st_mtime > 0)
                ? [NSDate dateWithTimeIntervalSince1970:st.st_mtime]
                : nil;
        } else if (stat(cpath, &st) == 0) {
            entry.isDirectory = S_ISDIR(st.st_mode);
            entry.fileSize = (long long)st.st_size;
            entry.modificationDate = (st.st_mtime > 0)
                ? [NSDate dateWithTimeIntervalSince1970:st.st_mtime]
                : nil;
        } else {
            entry.isDirectory = NO;
            entry.fileSize = 0;
            entry.modificationDate = nil;
            [entriesNeedingLease addObject:entry];
        }
        [entries addObject:entry];
    }

    if (entriesNeedingLease.count > 0) {
        NSString *lfDetail = nil;
        BadQueryLease *l2 = [BadQueryLease leaseForPath:path error:&lfDetail];
        if (l2) {
            for (BQFileEntry *entry in entriesNeedingLease) {
                if (entry.fullPath.length == 0) continue;
                struct stat st2;
                const char *entryC = [entry.fullPath fileSystemRepresentation];
                if (entryC && lstat(entryC, &st2) == 0) {
                    entry.isDirectory = S_ISDIR(st2.st_mode);
                    entry.fileSize = (long long)st2.st_size;
                    // same mtime=0 guard as the main stat path.
                    entry.modificationDate = (st2.st_mtime > 0)
                        ? [NSDate dateWithTimeIntervalSince1970:st2.st_mtime]
                        : nil;
                }
            }
            [l2 invalidate];
        } else {
            static NSArray<NSString *> *knownDirPrefixes = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                knownDirPrefixes = @[
                    @"/private/var/containers/Shared/SystemGroup",
                    @"/var/containers/Shared/SystemGroup",
                    @"/private/var/containers/Data/System",
                    @"/var/containers/Data/System",
                    @"/private/var/containers/Bundle/Application",
                    @"/var/containers/Bundle/Application",
                    @"/private/var/mobile/Containers/Data/Application",
                    @"/var/mobile/Containers/Data/Application",
                    @"/private/var/mobile/Containers/Data/InternalDaemon",
                    @"/var/mobile/Containers/Data/InternalDaemon",
                    @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                    @"/var/mobile/Containers/Data/PluginKitPlugin",
                    @"/private/var/mobile/Containers/Shared/AppGroup",
                    @"/var/mobile/Containers/Shared/AppGroup",
                ];
            });

            NSString *normPath = path;
            if (normPath.length > 1 && [normPath hasSuffix:@"/"]) {
                normPath = [normPath substringToIndex:normPath.length - 1];
            }
            BOOL parentIsKnownContainerRoot = NO;
            for (NSString *pfx in knownDirPrefixes) {
                if ([normPath isEqualToString:pfx]) {
                    parentIsKnownContainerRoot = YES;
                    break;
                }
            }

            for (BQFileEntry *entry in entriesNeedingLease) {
                NSString *name = entry.name;
                if (name.length == 0) continue;

                if (parentIsKnownContainerRoot) {
                    entry.isDirectory = YES;
                    continue;
                }

                NSString *ext = name.pathExtension;
                BOOL looksLikeUUID = (name.length == 36) &&
                    [[name stringByReplacingOccurrencesOfString:@"-" withString:@""]
                        rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location == NSNotFound;
                if (looksLikeUUID) {
                    entry.isDirectory = YES;
                } else if (ext.length == 0) {
                    // No extension and not a UUID — could be either.
                    // Default to file: if it is actually a directory,
                    // handleEntryTap's browse-first fallback will
                    // navigate into it on the next tap. Classifying a
                    // file as a directory causes a confusing empty-list
                    // flash; classifying a directory as a file costs one
                    // extra tap but is clearly recoverable.
                    entry.isDirectory = NO;
                } else {
                    NSSet<NSString *> *commonFileExts = [NSSet setWithArray:@[
                        @"plist", @"sqlite", @"db", @"sqlitedb",
                        @"jpg", @"jpeg", @"png", @"gif", @"heic",
                        @"mp4", @"mov", @"mp3", @"wav", @"aac",
                        @"txt", @"json", @"xml", @"html", @"log",
                        @"pdf", @"doc", @"docx", @"zip", @"tar",
                        @"gz", @"dylib", @"framework", @"strings",
                        @"nib", @"storyboardc", @"momd", @"ttf",
                        @"otf", @"cfg", @"ini", @"sh", @"plist~",
                    ]];
                    entry.isDirectory = ![commonFileExts containsObject:ext.lowercaseString];
                }
            }
        }
    }

    if (error) *error = nil;
    [entries sortUsingComparator:^NSComparisonResult(BQFileEntry *a, BQFileEntry *b) {
        if (a.isDirectory != b.isDirectory) {
            return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return entries;
}

- (nullable BQFileEntry *)statFileAtPath:(NSString *)path
                                    error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return nil;
    }

    struct stat st;
    if (BQFillStat(path, &st, YES)) {
        BQFileEntry *entry = [BQFileEntry new];
        entry.name = path.lastPathComponent;
        entry.fullPath = BQNormalizeForStat(path);
        entry.isDirectory = S_ISDIR(st.st_mode);
        entry.fileSize = (long long)st.st_size;
        entry.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtime];
        if (error) *error = nil;
        return entry;
    }

    // BQFillStat already tried with+without lease — truly unreachable.
    if (error) *error = [self errorWithCode:5
                                     message:[NSString stringWithFormat:@"stat failed for %@ (sandbox policy or missing file).", path]];
    return nil;
}

- (NSArray<BQFileEntry *> *)recursiveListAtPath:(NSString *)path
                                       maxDepth:(NSInteger)maxDepth
                                          error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return @[];
    }

    // Track visited directories to detect symlink loops.
    // Use canonicalized paths (resolved symlinks) for the visited set.
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSMutableArray<BQFileEntry *> *allEntries = [NSMutableArray array];
    [self recursiveCollect:path
                     depth:0
                   maxDepth:maxDepth
                    visited:visited
                      into:allEntries];
    if (error) *error = nil;
    return allEntries;
}

#pragma mark - Private

- (void)recursiveCollect:(NSString *)path
                    depth:(NSInteger)depth
                 maxDepth:(NSInteger)maxDepth
                visited:(NSMutableSet<NSString *> *)visited
                    into:(NSMutableArray<BQFileEntry *> *)collector
{
    if (maxDepth >= 0 && depth > maxDepth) return;
    if (path.length == 0) return;   // empty path → realpath of "" is UB

    // Hard cap on collected entries to prevent memory growth in deep trees.
    static const NSUInteger kMaxCollectedEntries = 50000;
    if (collector.count >= kMaxCollectedEntries) return;

    // Resolve symlinks to detect loops. If realpath fails, skip.
    const char *pathC = [path fileSystemRepresentation];
    if (!pathC) return;
    char resolved[PATH_MAX];
    if (!realpath(pathC, resolved)) return;

    // -AUDIT: realpath returns a valid C string but APFS allows
    // arbitrary bytes in path components (not valid UTF-8 on old
    // volumes). If NSString conversion fails we can't track visited
    // — bail to avoid crashing addObject:nil / setObject:nil.
    // Latin-1 fallback (ASCII rejects bytes >= 0x80 and can
    // still return nil; Latin-1 maps all 256 bytes and never fails).
    NSString *resolvedPath = [NSString stringWithUTF8String:resolved];
    if (!resolvedPath) {
        NSData *d = [NSData dataWithBytesNoCopy:resolved
                                         length:strnlen(resolved, sizeof(resolved))
                                   freeWhenDone:NO];
        resolvedPath = [[NSString alloc] initWithData:d
                                              encoding:NSISOLatin1StringEncoding];
    }
    if (resolvedPath.length == 0) return;

    // Already visited — symlink loop detected.
    [visited addObject:resolvedPath];

    NSError *error = nil;
    NSArray<BQFileEntry *> *entries = [self listDirectoryAtPath:path error:&error];
    if (error) return;

    for (BQFileEntry *entry in entries) {
        if (collector.count >= kMaxCollectedEntries) return;
        [collector addObject:entry];
        if (entry.isDirectory) {
            [self recursiveCollect:entry.fullPath
                            depth:depth + 1
                         maxDepth:maxDepth
                          visited:visited
                            into:collector];
        }
    }
}

#pragma mark - Write / Copy / Delete / Create / Move ()

- (BOOL)writeFileAtPath:(NSString *)path data:(NSData *)data error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return NO;
    }

    if (BQIsCriticalSystemPath(path)) {
        if (error) *error = [self errorWithCode:8
            message:[NSString stringWithFormat:
                @"Refusing to write to critical system path: %@", path]];
        return NO;
    }

    __block BOOL result = NO;
    __block NSError *blockError = nil;
    dispatch_sync(_mutationQueue, ^{
        NSString *badQueryDetail = nil;
        BadQueryLease *lease = [BadQueryLease leaseForPath:path
                                                     error:&badQueryDetail];
        if (!lease) {
            blockError = [self errorWithCode:2
                                      message:badQueryDetail ?: @"bad_query failed to acquire write access."];
            return;
        }

        NSError *writeError = nil;
        result = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];

        if (!result) {
            writeError = nil;
            result = [data writeToFile:path options:0 error:&writeError];
        }

        [lease invalidate];

        if (!result) {
            blockError = writeError ?: [self errorWithCode:6
                                                  message:@"Write denied — sandbox extension may be read-only for this path."];
        }
    });
    if (error) *error = blockError;
    return result;
}

- (NSInteger)copyDirectoryFromPath:(NSString *)sourcePath
                     toDestination:(NSString *)destinationPath
                              error:(NSError **)error
{
    if (!sourcePath.isAbsolutePath || !destinationPath.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"Absolute paths are required."];
        return -1;
    }

    NSString *normalizedSource = sourcePath;
    if (![normalizedSource hasSuffix:@"/"]) {
        normalizedSource = [normalizedSource stringByAppendingString:@"/"];
    }

    NSError *listError = nil;
    NSArray<BQFileEntry *> *entries = [self recursiveListAtPath:sourcePath
                                                       maxDepth:10
                                                          error:&listError];
    if (listError) {
        if (error) *error = listError;
        return -1;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger copied = 0;

    [fm createDirectoryAtPath:destinationPath
   withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    for (BQFileEntry *entry in entries) {
        NSString *relative = nil;
        if ([entry.fullPath hasPrefix:normalizedSource]) {
            relative = [entry.fullPath substringFromIndex:normalizedSource.length];
        } else if ([entry.fullPath isEqualToString:sourcePath]) {
            continue;
        } else {
            continue;
        }
        if (relative.length == 0) continue;

        NSString *destPath = [destinationPath stringByAppendingPathComponent:relative];

        if (entry.isDirectory) {
            [fm createDirectoryAtPath:destPath
          withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
            continue;
        }

        NSError *readErr = nil;
        NSData *data = [self readFileAtPath:entry.fullPath error:&readErr];
        if (!data) continue;

        NSError *writeErr = nil;
        NSString *parentDir = [destPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parentDir
      withIntermediateDirectories:YES
                     attributes:nil
                          error:nil];
        if ([data writeToFile:destPath options:0 error:&writeErr]) {
            copied++;
        }
    }

    if (error) *error = nil;
    return copied;
}

- (BOOL)deleteFileAtPath:(NSString *)path error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return NO;
    }

    if (BQIsCriticalSystemPath(path)) {
        if (error) *error = [self errorWithCode:8
            message:[NSString stringWithFormat:
                @"Refusing to delete critical system path: %@", path]];
        return NO;
    }

    __block BOOL result = NO;
    __block NSError *blockError = nil;
    dispatch_sync(_mutationQueue, ^{
        NSString *badQueryDetail = nil;
        BadQueryLease *lease = [BadQueryLease leaseForPath:path
                                                     error:&badQueryDetail];
        if (!lease) {
            blockError = [self errorWithCode:2
                                      message:badQueryDetail ?: @"bad_query failed to acquire delete access."];
            return;
        }

        NSError *deleteError = nil;
        result = [[NSFileManager defaultManager] removeItemAtPath:path
                                                            error:&deleteError];
        [lease invalidate];

        if (!result) {
            blockError = deleteError ?: [self errorWithCode:9
                                                  message:@"Delete denied — sandbox extension may be read-only."];
        }
    });
    if (error) *error = blockError;
    return result;
}

- (NSInteger)deleteDirectoryContentsAtPath:(NSString *)path
                                  maxItems:(NSInteger)maxItems
                                     error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return -1;
    }

    __block NSInteger result = 0;
    __block NSError *blockError = nil;
    dispatch_sync(_mutationQueue, ^{
        NSError *listError = nil;
        NSArray<BQFileEntry *> *entries = [self listDirectoryAtPath:path
                                                               error:&listError];
        if (listError) {
            blockError = listError;
            result = -1;
            return;
        }

        NSInteger deleted = 0;
        for (BQFileEntry *entry in entries) {
            if (maxItems > 0 && deleted >= maxItems) break;

            if (entry.isDirectory) {
                NSError *subError = nil;
                NSInteger subDeleted = [self deleteDirectoryContentsAtPath:entry.fullPath
                                                                  maxItems:(maxItems > 0 ? maxItems - deleted : 0)
                                                                     error:&subError];
                deleted += subDeleted;

                NSString *badQueryDetail = nil;
                BadQueryLease *lease = [BadQueryLease leaseForPath:entry.fullPath
                                                             error:&badQueryDetail];
                if (lease) {
                    [[NSFileManager defaultManager] removeItemAtPath:entry.fullPath
                                                               error:nil];
                    [lease invalidate];
                    deleted++;
                }
            } else {
                NSError *delError = nil;
                if ([self deleteFileAtPath:entry.fullPath error:&delError]) {
                    deleted++;
                }
            }
        }
        result = deleted;
    });
    if (result < 0) {
        if (error) *error = blockError;
        return -1;
    }
    if (error) *error = nil;
    return result;
}

- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"An absolute path is required."];
        return NO;
    }

    if (BQIsCriticalSystemPath(path)) {
        if (error) *error = [self errorWithCode:8
            message:@"Refusing to create directory in critical system path."];
        return NO;
    }

    __block BOOL result = NO;
    __block NSError *blockError = nil;
    dispatch_sync(_mutationQueue, ^{
        NSString *badQueryDetail = nil;
        BadQueryLease *lease = [BadQueryLease leaseForPath:path
                                                     error:&badQueryDetail];
        if (!lease) {
            blockError = [self errorWithCode:2
                                      message:badQueryDetail ?: @"bad_query failed to acquire access for directory creation."];
            return;
        }

        NSError *createError = nil;
        result = [[NSFileManager defaultManager] createDirectoryAtPath:path
                                                  withIntermediateDirectories:YES
                                                                  attributes:nil
                                                                       error:&createError];
        [lease invalidate];

        if (!result) {
            blockError = createError ?: [self errorWithCode:10
                                                  message:@"Failed to create directory."];
        }
    });
    if (error) *error = blockError;
    return result;
}

- (BOOL)moveFileFromPath:(NSString *)sourcePath
                   toPath:(NSString *)destinationPath
                    error:(NSError **)error
{
    if (!sourcePath.isAbsolutePath || !destinationPath.isAbsolutePath) {
        if (error) *error = [self errorWithCode:1
                                         message:@"Absolute paths are required."];
        return NO;
    }

    if (BQIsCriticalSystemPath(sourcePath) || BQIsCriticalSystemPath(destinationPath)) {
        if (error) *error = [self errorWithCode:8
            message:@"Refusing to move to/from critical system path."];
        return NO;
    }

    __block BOOL result = NO;
    __block NSError *blockError = nil;
    dispatch_sync(_mutationQueue, ^{
        NSString *badQueryDetail = nil;
        BadQueryLease *lease = [BadQueryLease leaseForPath:sourcePath
                                                     error:&badQueryDetail];
        if (!lease) {
            blockError = [self errorWithCode:2
                                      message:badQueryDetail ?: @"bad_query failed to acquire move access."];
            return;
        }

        NSString *destParent = [destinationPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:destParent
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        NSError *moveError = nil;
        result = [[NSFileManager defaultManager] moveItemAtPath:sourcePath
                                                           toPath:destinationPath
                                                            error:&moveError];
        [lease invalidate];

        if (!result) {
            NSError *readErr = nil;
            NSData *data = [self readFileAtPath:sourcePath error:&readErr];
            if (data) {
                NSError *writeErr = nil;
                if ([self writeFileAtPath:destinationPath data:data error:&writeErr]) {
                    [self deleteFileAtPath:sourcePath error:nil];
                    result = YES;
                    return;
                }
            }
            blockError = moveError ?: [self errorWithCode:11
                                              message:@"Move failed."];
        }
    });
    if (error) *error = blockError;
    return result;
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message
{
    return [NSError errorWithDomain:@"com.wesk.vtool.badqueryfile"
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

@end
