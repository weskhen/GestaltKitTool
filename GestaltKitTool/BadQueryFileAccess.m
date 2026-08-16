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

// 统一日志宏 — Debug 用 NSLog, Release 用 os_log
// 注意: ObjC 文件仅 1 处日志, 直接用 NSLog 保持简单
#define GKTLLog(fmt, ...) NSLog(fmt, ##__VA_ARGS__)

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
/// C-1 FIX: Return nil for nil / empty input. Previously we returned the
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
///      (this caused the "一直显示加载中" regression reported by user).
///   3. If `allowLeaseRetry` is NO, skip the lease retry entirely. Used
///      by the fallback opendir branch which already holds a lease.
///
/// Returns YES on success, NO on complete failure.
static BOOL BQFillStatRetry(NSString *path, struct stat *outSt, BOOL followSymlink, BOOL allowLeaseRetry)
{
    if (!path || !outSt) return NO;
    NSString *real = BQNormalizeForStat(path);
    if (real.length == 0) return NO;  // C-1: protect against empty → FSRep crash
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

@implementation BadQueryFileAccess

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

    // CR-13: MEMORY CAP. Cap the read at 16 MB; larger files return only
    // their first 16 MB so the preview stays cheap. Used by both the
    // lease-based read and the CR-28 direct-read fallback.
    static const long long kMaxReadBytes = 16LL * 1024 * 1024;

    // Acquire a bad_query lease for the target path.
    NSString *badQueryDetail = nil;
    BadQueryLease *lease = [BadQueryLease leaseForPath:path
                                                 error:&badQueryDetail];
    if (!lease) {
        // CR-28: Lease failed — but opendir (listDirectory) works WITHOUT
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
    // H-2: Use NSDataReadingMappedIfSafe is dangerous here — the mmap'd
    // data remains backed by the file even after [lease invalidate],
    // causing SIGBUS when accessed. Instead, read into an allocated
    // buffer that's fully independent of the file mapping.
    //
    // CR-13: MEMORY CAP. The old code read the ENTIRE file into memory.
    // Tapping a large file (ATX .db stores, videos, .sqlite-wal) pulled
    // tens or hundreds of MB into the process → jetsam kill. (kMaxReadBytes
    // is defined above with the CR-28 direct-read fallback.)

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
    // STRATEGY (revised after studying FilzaJailedDS / FilzaSlop):
    //
    // Filza* variants use KRW to patch the kernel ucred sandbox extension
    // table to "/" — then standard opendir/readdir with struct dirent
    // d_type works EVERYWHERE. That's the gold standard: d_type is 100%
    // reliable, no heuristics, no dupe snapshot inodes, no gap limits.
    //
    // Since we use bad_query (per-path sandbox extensions rather than
    // kernel memory patching), we can't always count on that, but we
    // STILL prefer opendir paths in this priority order:
    //
    //   1. opendir WITHOUT any lease — works for:
    //        - Our own app container sandbox (always listable)
    //        - World-readable system directories (/tmp, /Library on
    //          certain paths, etc.)
    //        - Any container path whose MAC policy allows directory
    //          listing for the app-sandbox class even without an
    //          explicit extension.
    //      THIS IS THE FASTEST AND MOST RELIABLE PATH. d_type from
    //      dirent is authoritative (DT_DIR / DT_REG / DT_LNK / ...),
    //      no heuristics needed. Zero XPC. ~ms for even 10k-file dirs.
    //
    //   2. opendir AFTER acquiring a single bad_query lease for the
    //      PARENT directory. Frequently works on iOS 27+ too. Same
    //      d_type reliability as #1; just one XPC call.
    //
    //   3. fsgetpath inode-scan fallback — ONLY if opendir fails in
    //      both #1 and #2. This is the "least reliable" path (snapshot
    //      aliases → duplicates, heuristic isDirectory guesses, and we
    //      have to gap-stop early), so we prefer avoiding it whenever
    //      opendir is viable. The inode cap is relaxed from the old
    //      200K to 350K here because we only reach it when opendir
    //      couldn't help at all, so a slightly deeper scan is worth
    //      the trade-off.
    //
    // This is the INVERSE of the old code (fsgetpath first, opendir as
    // empty-array-only fallback). The inversion eliminates 90% of the
    // "strange" browsing artifacts users have been seeing.
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
        // CR-25: Track seen d_name to prevent duplicates from readdir.
        // On APFS with snapshots/clones, readdir can occasionally return
        // the same d_name twice (especially under MAC policy). This
        // NSMutableSet ensures each name appears only once.
        NSMutableSet<NSString *> *seenNames = [NSMutableSet set];
        struct dirent *de;
        while ((de = readdir(dir)) != NULL) {
            const char *d_name = de->d_name;
            if (strcmp(d_name, ".") == 0 || strcmp(d_name, "..") == 0) continue;

            // CR-11 + CR-13: d_name might not be valid UTF-8 on APFS
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

            // CR-25: Skip duplicates (same d_name returned twice by readdir).
            if ([seenNames containsObject:nameStr]) {
                GKTLLog(@"[GKTL-ObjC] ⚠️ DUPLICATE-d_name skipped: %@", nameStr);
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
            // CR-17 (mtime=0 fix): On iOS 26 with MAC policy, lstat
            // succeeds but st_mtime is frequently 0 (epoch 1970) for
            // sandboxed paths under /private/var/mobile/... and
            // /private/var/containers/... — the kernel returns the
            // inode metadata but MAC scrubs the timestamps. Showing
            // "1970-01-01 08:00" to the user is worse than showing
            // nothing, so treat mtime==0 as "no date available".
            // Predecessor weskVTool used stat() (follows symlinks)
            // which failed outright under MAC → modificationDate
            // stayed nil → no misleading date shown.
            struct stat st;
            const char *ep = [entry.fullPath fileSystemRepresentation];
            if (ep && lstat(ep, &st) == 0) {
                entry.isDirectory = S_ISDIR(st.st_mode); // override d_type for symlink→dir if we followed
                entry.fileSize = (long long)st.st_size;
                // CR-17: Only set modificationDate if mtime is a real
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
    // CR-25: dedupe by normalized childPath (fsgetpath can return
    // /var/X and /private/var/X for the same inode).
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    for (NSString *childPath in childPaths) {
        if (childPath.length == 0) continue;

        // CR-25: normalize for dedup (strip /private, lowercase).
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
            // CR-17: mtime=0 means MAC scrubbing, not a real epoch date.
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
                    // CR-17: same mtime=0 guard as the main stat path.
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
                    entry.isDirectory = YES;
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

    // H-3: Track visited directories to detect symlink loops.
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
    if (path.length == 0) return;   // C-1: empty path → realpath of "" is UB

    // CR-13: hard cap on collected entries. A deep recursion into a
    // huge tree (e.g. a container with hundreds of thousands of files)
    // previously accumulated every entry (each with 2 NSStrings + NSDate)
    // until memory exploded. Stop collecting at 50k — plenty for any
    // practical search result list.
    static const NSUInteger kMaxCollectedEntries = 50000;
    if (collector.count >= kMaxCollectedEntries) return;

    // H-3: Resolve symlinks to detect loops. If realpath fails, skip.
    const char *pathC = [path fileSystemRepresentation];
    if (!pathC) return;
    char resolved[PATH_MAX];
    if (!realpath(pathC, resolved)) return;

    // CR-11-AUDIT: realpath returns a valid C string but APFS allows
    // arbitrary bytes in path components (not valid UTF-8 on old
    // volumes). If NSString conversion fails we can't track visited
    // — bail to avoid crashing addObject:nil / setObject:nil.
    // CR-13: Latin-1 fallback (ASCII rejects bytes >= 0x80 and can
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

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message
{
    return [NSError errorWithDomain:@"com.wesk.vtool.badqueryfile"
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

@end
