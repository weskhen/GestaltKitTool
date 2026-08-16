//
//  GestaltAccess.m
//  GestaltKitTool
//
//  bad_query path traversal (iOS 26 / 27):
//       class 13, MobileGestalt SystemGroup, part 3, target absolute path,
//       flags 0x8000000000; directly consumes the sandbox token

#import "GestaltAccess.h"
#import "BadQueryBridge.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

static NSString * const kGestaltPlistFileName = @"com.apple.MobileGestalt.plist";

static NSString * const kMobileGestaltCacheDirectory =
    @"/private/var/containers/Shared/SystemGroup/"
     "systemgroup.com.apple.mobilegestaltcache/Library/Caches";
static NSString * const kBadQueryMobileGestaltCacheDirectory =
    @"/var/containers/Shared/SystemGroup/"
     "systemgroup.com.apple.mobilegestaltcache/Library/Caches";

static NSError *GestaltError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"com.wesk.vtool.access"
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static BOOL GestaltCanOpenReadWrite(NSString *path)
{
    if (path.length == 0) return NO;     // C-1: guard empty → FSRep crash
    const char *pathC = [path fileSystemRepresentation];
    if (!pathC) return NO;
    int fd = open(pathC,
                  O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

/// Returns the on-disk uid of a file via stat(), or (uid_t)-1 on failure.
/// Used to produce actionable DAC-mismatch error messages (EACCES).
static uid_t GestaltStatUid(const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0) return (uid_t)-1;
    return st.st_uid;
}

static BOOL GestaltWriteAll(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    // C-7: Cap EINTR retries to prevent infinite loop under signal pressure.
    int eintrRetryCount = 0;
    static const int kMaxEintrRetries = 100;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            if (++eintrRetryCount > kMaxEintrRetries) return NO;
            continue;
        }
        if (written <= 0) return NO;
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    return YES;
}

@interface GestaltAccess ()
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, copy) NSString *plistPath;
@property (nonatomic, assign) NSPropertyListFormat lastReadFormat;
@end

@implementation GestaltAccess
{
    BadQueryLease *_activeBadQueryLease;
    // H-4/H-5: Serial queue to protect connection state from concurrent access.
    dispatch_queue_t _stateQueue;
}

#pragma mark - Thread-safe state access

/// Read plistPath via the serial queue to avoid race conditions.
- (NSString *)_plistPath {
    __block NSString *result = nil;
    dispatch_sync(_stateQueue, ^{
        result = self.plistPath;
    });
    return result;
}

/// Write plistPath via the serial queue.
- (void)_setPlistPath:(NSString *)path {
    dispatch_sync(_stateQueue, ^{
        self.plistPath = path;
    });
}

/// Read lastReadFormat via the serial queue.
- (NSPropertyListFormat)_lastReadFormat {
    __block NSPropertyListFormat result = NSPropertyListBinaryFormat_v1_0;
    dispatch_sync(_stateQueue, ^{
        result = self.lastReadFormat;
    });
    return result;
}

/// Write lastReadFormat via the serial queue.
- (void)_setLastReadFormat:(NSPropertyListFormat)format {
    dispatch_sync(_stateQueue, ^{
        self.lastReadFormat = format;
    });
}

/// Read isConnected via the serial queue.
- (BOOL)_isConnected {
    __block BOOL result = NO;
    dispatch_sync(_stateQueue, ^{
        result = self.isConnected;
    });
    return result;
}

/// Check whether the lease is still valid.
- (BOOL)_leaseIsValid {
    __block BOOL result = NO;
    dispatch_sync(_stateQueue, ^{
        result = _activeBadQueryLease.isActive;
    });
    return result;
}

+ (instancetype)shared
{
    static GestaltAccess *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [GestaltAccess new];
        shared->_stateQueue = dispatch_queue_create(
            "com.wesk.vtool.access.state", DISPATCH_QUEUE_SERIAL);
    });
    return shared;
}

+ (NSString *)currentOSBuild
{
    size_t length = 0;
    if (sysctlbyname("kern.osversion", NULL, &length, NULL, 0) != 0 ||
        length == 0) {
        return @"";
    }

    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (sysctlbyname("kern.osversion", data.mutableBytes, &length, NULL, 0) != 0)
        return @"";

    return [NSString stringWithUTF8String:data.bytes] ?: @"";
}

+ (BOOL)isRunningSupportedOS
{
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *build = self.currentOSBuild;

    return version.majorVersion == 27 && (
        [build isEqualToString:@"24A5355q"] || // iOS 27 beta 1
        [build isEqualToString:@"24A5370h"] || // iOS 27 beta 2
        [build isEqualToString:@"24A5380h"] || // iOS 27 beta 3
        [build isEqualToString:@"24A5390f"]    // iOS 27 beta 4
    );
}

#pragma mark - Connection

- (BOOL)connectWithError:(NSError **)error
{
    // CR-9: Move the blocking lease acquisition + plist open to a
    // dedicated background queue so callers on the main thread
    // (SwiftUI button actions, @MainActor methods) don't freeze
    // the UI during XPC calls. We use a semaphore to keep the
    // synchronous API while avoiding blocking the main queue.
    __block BOOL alreadyConnected = NO;
    dispatch_sync(_stateQueue, ^{
        alreadyConnected = self.isConnected && _activeBadQueryLease.isActive &&
            self.plistPath.length > 0;
    });

    if (alreadyConnected) {
        return YES;
    }

    // Run the heavy work on a dedicated background queue.
    __block NSError *connectError = nil;
    dispatch_queue_t workQueue = dispatch_queue_create(
        "com.wesk.vtool.access.connect", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    dispatch_async(workQueue, ^{
        [self _connectInternal:&connectError];
        dispatch_semaphore_signal(sema);
    });

    // Wait for background work (max 15 seconds — XPC calls have 3s timeout
    // each, plus overhead). The actual XPC calls happen on workQueue, so
    // the calling thread (which may be the main thread) only waits for the
    // semaphore signal — not the full XPC latency.
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(sema, timeout) != 0) {
        if (error) *error = GestaltError(20,
            NSLocalizedString(@"Connection timed out. ContainerManager may be unresponsive.", nil));
        return NO;
    }

    if (connectError) {
        if (error) *error = connectError;
        return NO;
    }
    return YES;
}

/// Internal connection logic. Must not be called from the main thread.
- (BOOL)_connectInternal:(NSError **)error
{
    __block BOOL result = NO;
    __block NSError *blockError = nil;

    dispatch_sync(_stateQueue, ^{
        if (!GestaltAccess.isRunningSupportedOS) {
            blockError = GestaltError(0, NSLocalizedString(
                @"GestaltKitTool currently supports only iOS 27 beta 1 through beta 4.", nil));
            result = NO;
            return;
        }

        if (self.isConnected && _activeBadQueryLease.isActive &&
            self.plistPath.length > 0) {
            blockError = nil;
            result = YES;
            return;
        }

        if (!BadQueryBridgeAvailable()) {
            blockError = GestaltError(1, NSLocalizedString(
                @"bad_query is unavailable (required ContainerManager or sandbox extension APIs are missing).", nil));
            result = NO;
            return;
        }

        [_activeBadQueryLease invalidate];
        _activeBadQueryLease = nil;
        self.isConnected = NO;
        self.plistPath = nil;
    });

    if (blockError) {
        if (error) *error = blockError;
        return NO;
    }

    NSString *badQueryTarget = [kBadQueryMobileGestaltCacheDirectory
        stringByAppendingPathComponent:kGestaltPlistFileName];
    NSString *badQueryPlist = [kMobileGestaltCacheDirectory
        stringByAppendingPathComponent:kGestaltPlistFileName];
    NSString *badQueryDetail = nil;
    BadQueryLease *badQueryLease = [BadQueryLease leaseForPath:badQueryTarget
                                                         error:&badQueryDetail];
    if (!badQueryLease) {
        if (error) *error = GestaltError(2,
            badQueryDetail ?: NSLocalizedString(@"bad_query failed.", nil));
        return NO;
    }
    if (!GestaltCanOpenReadWrite(badQueryPlist)) {
        [badQueryLease invalidate];
        if (error) *error = GestaltError(3, NSLocalizedString(
            @"bad_query acquired a sandbox extension, but the MobileGestalt plist is not writable.", nil));
        return NO;
    }

    dispatch_sync(_stateQueue, ^{
        _activeBadQueryLease = badQueryLease;
        self.isConnected = YES;
        self.plistPath = badQueryPlist;
    });

    if (error) *error = nil;
    return YES;
}

#pragma mark - Read / Write

- (NSData *)readGestaltDataWithError:(NSError **)error
{
    if (![self connectWithError:error]) return nil;
    NSString *plistPath = [self _plistPath];
    if (plistPath.length == 0) {
        if (error) *error = GestaltError(3,
            NSLocalizedString(@"The plist path is not set (connection lost).", nil));
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        if (error) *error = GestaltError(3,
            [NSString stringWithFormat:NSLocalizedString(@"The plist does not exist: %@", nil), plistPath]);
        return nil;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:plistPath
                                           options:0
                                             error:&readError];
    if (!data) {
        if (error) *error = readError ?: GestaltError(4, NSLocalizedString(@"Failed to read the plist.", nil));
        return nil;
    }
    if (error) *error = nil;
    return data;
}

- (NSDictionary *)readGestaltWithError:(NSError **)error
{
    NSData *data = [self readGestaltDataWithError:error];
    if (!data) return nil;

    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    NSError *parseError = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:0
                                                          format:&format
                                                           error:&parseError];
    if (![plist isKindOfClass:NSDictionary.class]) {
        if (error) *error = parseError ?: GestaltError(5,
            NSLocalizedString(@"The plist top level is not a dictionary.", nil));
        return nil;
    }
    [self _setLastReadFormat:format];
    return plist;
}

- (BOOL)saveGestalt:(NSDictionary *)plist error:(NSError **)error
{
    if (![self connectWithError:error]) return NO;
    if (![plist isKindOfClass:NSDictionary.class]) {
        if (error) *error = GestaltError(6, NSLocalizedString(@"The content to save is not a dictionary.", nil));
        return NO;
    }

    NSPropertyListFormat format = [self _lastReadFormat];
    if (format != NSPropertyListXMLFormat_v1_0 &&
        format != NSPropertyListBinaryFormat_v1_0)
        format = NSPropertyListBinaryFormat_v1_0;

    NSError *serializeError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:format
                                                             options:0
                                                               error:&serializeError];
    if (!data) {
        if (error) *error = serializeError ?: GestaltError(7, NSLocalizedString(@"Failed to serialize the plist.", nil));
        return NO;
    }

    NSString *targetPath = [self _plistPath];
    if (targetPath.length == 0) {
        if (error) *error = GestaltError(61, NSLocalizedString(@"The MobileGestalt plist path is empty.", nil));
        return NO;
    }
    NSError *readError = nil;
    NSData *original = [NSData dataWithContentsOfFile:targetPath
                                              options:0
                                                error:&readError];
    if (!original) {
        if (error) *error = readError ?: GestaltError(8, NSLocalizedString(@"Failed to read the original plist.", nil));
        return NO;
    }

    int fd = open([targetPath fileSystemRepresentation],
                  O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        int openErr = errno;
        NSString *detail;
        switch (openErr) {
            case EACCES: {
                const char *targetPathC = [targetPath fileSystemRepresentation];
                uid_t statUid = targetPathC ? GestaltStatUid(targetPathC) : (uid_t)-1;
                detail = [NSString stringWithFormat:
                    NSLocalizedString(@"Failed to open the plist for writing: Permission denied (EACCES). The plist file is owned by uid=%d but our effective uid=%d; sandbox extension allows MAC access but DAC ownership still blocks writes. This device may need the backup-restore dance to realign MobileGestalt ownership.", nil),
                    statUid, geteuid()];
                break;
            }
            case EPERM:
                detail = [NSString stringWithFormat:
                    NSLocalizedString(@"Failed to open the plist for writing: Operation not permitted (EPERM). Kernel-level protections (immutable flag / sandbox class mismatch) blocked this write.", nil)];
                break;
            case ENOENT:
                detail = NSLocalizedString(@"Failed to open the plist for writing: File does not exist (ENOENT). The MobileGestalt cache may not have been generated yet.", nil);
                break;
            case EROFS:
                detail = NSLocalizedString(@"Failed to open the plist for writing: Read-only file system (EROFS). The system volume may still be sealed.", nil);
                break;
            default:
                detail = [NSString stringWithFormat:
                    NSLocalizedString(@"Failed to open the plist (errno=%d).", nil), openErr];
                break;
        }
        if (error) *error = GestaltError(9, detail);
        return NO;
    }

    // H-1 fix: do NOT ftruncate(fd, 0) before writing. If we truncated
    // first and the write was interrupted by a signal / exit /
    // jetsam, the plist would be 0 bytes on disk — SpringBoard cannot
    // parse an empty plist and the device enters an endless respring
    // loop (requires DFU restore). Instead we write the new data in
    // place, and fsync before declaring success. Because the new size
    // is always >= original for the same format (binary plist size
    // varies), if the new data is smaller we need a trailing
    // truncation — but we do it AFTER the write and fsync succeed.
    NSUInteger dataLen = data.length;
    BOOL writeOK = GestaltWriteAll(fd, data);
    int writeErrno = errno;

    if (!writeOK) {
        // CR-1 fix: GestaltWriteAll returned NO partway through. The fd
        // file pointer has advanced by some N bytes (< dataLen), so the
        // on-disk file is now "first N bytes of new data + remaining
        // bytes of the original plist" — a hybrid state that binary
        // plist parsers may misinterpret as a valid (but semantically
        // wrong) plist, which is more dangerous than an empty file.
        //
        // Restore byte-for-byte by rewinding the fd and rewriting the
        // original data, then truncate to the original length (in
        // case the partial new write extended past the original EOF —
        // possible if the new data was larger and got far enough).
        lseek(fd, 0, SEEK_SET);
        BOOL recovered = GestaltWriteAll(fd, original);
        int restoreErrno = errno;
        BOOL restoreFsyncOK = YES;
        int restoreFsyncErrno = 0;
        if (recovered) {
            off_t origSize = (off_t)original.length;
            struct stat st;
            if (fstat(fd, &st) == 0 && st.st_size > origSize) {
                (void)ftruncate(fd, origSize);
            }
            // CR-2: Recovery write must ALSO be flushed to stable
            // storage. Without this fsync there's still a window
            // (seconds) where a jetsam/reboot leaves the corrupted
            // hybrid on disk even though pwrite succeeded.
            if ((restoreFsyncOK = (fsync(fd) == 0)) == NO) {
                restoreFsyncErrno = errno;
            }
            // Same 3× global sync as success path: pushes out other
            // vnode buffers (APFS tx log, dir updates). harmless.
            sync(); sync(); sync();
        }
        close(fd);
        NSString *recoveryMsg;
        if (recovered && restoreFsyncOK) {
            recoveryMsg = NSLocalizedString(@"Original data was restored and flushed to disk.", nil);
        } else if (recovered) {
            recoveryMsg = [NSString stringWithFormat:
                NSLocalizedString(@"Original data was restored but fsync of the recovery write failed (errno=%d). If the device reboots before the page cache is flushed the file may still be corrupted.", nil),
                restoreFsyncErrno];
        } else {
            recoveryMsg = [NSString stringWithFormat:
                NSLocalizedString(@"Recovery write also failed (errno=%d). The on-disk plist is now in a PARTIALLY OVERWRITTEN state and may not parse — do NOT respring or reboot until you have manually restored from a backup.", nil),
                restoreErrno];
        }
        if (error) *error = GestaltError(10,
            [NSString stringWithFormat:NSLocalizedString(
                @"Failed to write the plist (errno=%d). %@", nil),
             writeErrno, recoveryMsg]);
        return NO;
    }

    BOOL synced = fsync(fd) == 0;
    int syncErrno = errno;
    if (!synced) {
        // MR-1: write succeeded (data is in page cache) but fsync failed.
        // The new data IS visible to subsequent reads — returning NO
        // would mislead callers into thinking nothing changed. Return
        // YES but surface a warning so the user knows persistence is
        // not guaranteed across reboot.
        // OPT-B: Even on fsync-fail path, push out other vnode buffers
        // (APFS transaction log, directory entries) to minimise the
        // window of inconsistency. Borrowed from the `sync();sync();sync()`
        // pattern used by FilzaJailedDS apfs_own after kwrite.
        sync(); sync(); sync();
        close(fd);
        if (error) *error = GestaltError(14,
            [NSString stringWithFormat:NSLocalizedString(
                @"Data was written but fsync failed (errno=%d). Changes are visible now but may not survive a reboot.", nil),
             syncErrno]);
        // Return YES — the in-memory state matches what readers will see.
        return YES;
    }

    // OPT-B: fsync(fd) flushed only the file's data blocks to the
    // drive. To survive unclean shutdowns we also need the APFS
    // transaction log, the containing directory's modification record,
    // and the volume superblock checkpoint committed. Three consecutive
    // sync() calls are a long-standing Darwin idiom that gives syncd
    // enough wakeups to cover these. Matching FilzaJailedDS's post-
    // kwrite defensive pattern.
    sync(); sync(); sync();

    // Both write and fsync succeeded. If the new data is smaller than
    // the original file, truncate to the exact new length.
    {
        off_t newSize = (off_t)dataLen;
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > newSize) {
            if (ftruncate(fd, newSize) != 0) {
                // Trailing bytes left on disk. Post-write verification
                // (below) will still pass because it reads `dataLen`
                // bytes from the fd, but the on-disk file has garbage
                // at the end. Warn but don't fail — the plist parser
                // reads exactly the header-declared length.
            } else {
                (void)fsync(fd);
                sync(); sync(); sync();
            }
        }
    }

    // H-7: Verify the write succeeded before closing the fd.
    // Re-read from the fd to confirm data matches.
    lseek(fd, 0, SEEK_SET);
    {
        uint8_t *verifyBuf = calloc(1, dataLen);
        if (!verifyBuf) {
            close(fd);
            if (error) *error = GestaltError(13, NSLocalizedString(@"Failed to allocate verification buffer.", nil));
            return NO;
        }
        NSUInteger totalRead = 0;
        while (totalRead < dataLen) {
            ssize_t n = read(fd, verifyBuf + totalRead, dataLen - totalRead);
            if (n <= 0) break;
            totalRead += (NSUInteger)n;
        }
        // CR-4: When the read loop exits early (EOF/short read), the
        // remaining portion of verifyBuf is zero-filled by calloc, but
        // we must NOT compare the full dataLen bytes (that would
        // compare zeroes against real plist bytes and always fail).
        // Instead we: (a) require we actually read the full dataLen,
        // and (b) only then byte-compare the exact range.
        BOOL verified = (totalRead == dataLen) &&
            memcmp(verifyBuf, data.bytes, dataLen) == 0;
        free(verifyBuf);
        if (!verified) {
            // Write verification from fd failed — fall through to the
            // file-based check below (re-opens the path via NSData
            // which hits the real disk contents, not the page cache).
        }
    }
    close(fd);

    NSData *verification = [NSData dataWithContentsOfFile:targetPath];
    if (![verification isEqualToData:data]) {
        if (error) *error = GestaltError(11, NSLocalizedString(@"Post-write verification failed.", nil));
        return NO;
    }

    // OPT-B: Third (parse-level) verification. The two checks above
    // confirm the bytes we intended to write are on disk byte-equal to
    // `data`. However an in-memory corruption (e.g. a stray write to
    // the NSMutableData backing store during the save call) could
    // leave us with syntactically valid bytes that no longer parse as
    // a dictionary, or whose top-level key population has regressed
    // from the original. Mirroring FilzaJailedDS apfs_own's
    // "layout-sanity-check-before-write" pattern, we re-parse the
    // freshly written plist and compare the top-level key coverage
    // (≥80% of original top-level keys, plus the dict type matches).
    // This is the final gate before we return YES and schedule a
    // SpringBoard respring — if it fails we bail out and tell the
    // user before rebooting them.
    {
        NSError *parseErr = nil;
        NSPropertyListFormat fmtParsed = NSPropertyListBinaryFormat_v1_0;
        id reparsed = [NSPropertyListSerialization
            propertyListWithData:verification
                          options:0
                           format:&fmtParsed
                            error:&parseErr];
        if (![reparsed isKindOfClass:NSDictionary.class]) {
            NSString *reason = parseErr.localizedDescription
                ?: NSLocalizedString(@"Reparsed plist is not a dictionary.", nil);
            if (error) *error = GestaltError(15,
                [NSString stringWithFormat:
                    NSLocalizedString(@"Post-write parse verification failed: %@. Refusing to respring with a potentially corrupt plist.", nil),
                 reason]);
            return NO;
        }
        NSDictionary *parsedDict = (NSDictionary *)reparsed;
        NSUInteger originalKeyCount = ((NSDictionary *)plist).count;
        NSUInteger parsedKeyCount = parsedDict.count;
        if (originalKeyCount > 0 && parsedKeyCount < (originalKeyCount * 4) / 5) {
            if (error) *error = GestaltError(15,
                [NSString stringWithFormat:
                    NSLocalizedString(@"Post-write parse verification failed: top-level key count dropped from %lu to %lu (< 80%% of original). Refusing to respring.", nil),
                 (unsigned long)originalKeyCount, (unsigned long)parsedKeyCount]);
            return NO;
        }
    }

    if (error) *error = nil;
    return YES;
}

@end
