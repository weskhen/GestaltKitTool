//
//  WorseQueryProbe.m
//  GestaltKitTool
//
//  Wraps WorseQueryAcquireWithParams for Swift automation.
//

#import "WorseQueryProbe.h"
#import "WorseQueryBridge.h"
#import <os/log.h>
#import <fcntl.h>
#import <unistd.h>

#define GKTLLogObjC(fmt, ...) os_log(OS_LOG_DEFAULT, "%{public}s", [[NSString stringWithFormat:@"[GKTL-ObjC] " fmt, ##__VA_ARGS__] UTF8String])

@implementation WorseQueryProbe

+ (BOOL)probePath:(NSString *)path flag:(uint64_t)flag part:(uint64_t)part
{
    int64_t handle = WorseQueryAcquireWithParams(path, flag, part);
    BOOL ok = handle > 0;
    if (ok) {
        GKTLLogObjC(@"[GKTL-FlagScan] token OK flag=0x%llx part=%llu handle=%lld",
                    (unsigned long long)flag, (unsigned long long)part,
                    (long long)handle);
        WorseQueryRelease(handle);
    }
    return ok;
}

+ (nullable NSData *)readPath:(NSString *)path flag:(uint64_t)flag part:(uint64_t)part
{
    if (path.length == 0) return nil;
    const char *c = path.fileSystemRepresentation;
    if (!c) return nil;

    int64_t handle = WorseQueryAcquireWithParams(path, flag, part);
    if (handle <= 0) return nil;
    int fd = open(c, O_RDONLY);
    if (fd < 0) {
        WorseQueryRelease(handle);
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    char buf[65536];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
        if (data.length > 8 * 1024 * 1024) break; // cap at 8 MB
    }
    close(fd);
    WorseQueryRelease(handle);
    return data;
}

+ (BOOL)probeWrite:(NSString *)path flag:(uint64_t)flag part:(uint64_t)part
{
    if (path.length == 0) return NO;
    const char *c = path.fileSystemRepresentation;
    if (!c) return NO;

    int64_t handle = WorseQueryAcquireWithParams(path, flag, part);
    if (handle <= 0) return NO;
    int fd = open(c, O_WRONLY | O_CLOEXEC);
    BOOL ok = (fd >= 0);
    if (ok) close(fd);
    else GKTLLogObjC(@"[GKTL-WriteScan] open(O_WRONLY) failed errno=%d flag=0x%llx part=%llu",
                     errno, (unsigned long long)flag, (unsigned long long)part);
    WorseQueryRelease(handle);
    return ok;
}

@end
