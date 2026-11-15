/*
 * MFCarPlayLog.m - 把 CarPlay 日志同时写进沙盒 Documents/carplay.log
 * 设计要点见 MFCarPlayLog.h。
 *
 * 注意：
 *   - 只在 DEBUG 或显式打开时才写，避免正式包无谓 IO？—— 不，
 *     CarPlay 排查期必须始终写，体积可控（512KB 轮转），所以始终启用。
 *   - 用 NSFileHandle seekToEndOfFile 追加，避免每次整文件重写。
 *   - 首次写时打一条 header（构建号 / 系统版本 / 时间），方便对照版本。
 */
#import "MFCarPlayLog.h"
#import <UIKit/UIKit.h>        /* UIDevice：取系统版本 / 机型写进日志 header */
#import <dispatch/dispatch.h>  /* dispatch_queue_create / dispatch_async（显式依赖，别靠间接包含） */

static dispatch_queue_t sLogQueue = nil;
static NSFileHandle *sHandle = nil;
static NSString *sPath = nil;
static unsigned long long sWritten = 0;
static BOOL sHeaderDone = NO;

static const unsigned long long kMFLogMaxBytes = 512ULL * 1024ULL;

static NSString *MFDocumentsPath(void) {
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return dirs.count > 0 ? dirs[0] : NSTemporaryDirectory();
}

NSString *MFCarPlayLogFilePath(void) {
    if (sPath) {
        return sPath;
    }
    return [MFDocumentsPath() stringByAppendingPathComponent:@"carplay.log"];
}

static void MFEnsureQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLogQueue = dispatch_queue_create("app.musicfree.carplaylog", DISPATCH_QUEUE_SERIAL);
    });
}

static void MFRotateIfNeeded(void) {
    if (sWritten < kMFLogMaxBytes) {
        return;
    }
    @try {
        [sHandle closeFile];
    } @catch (NSException *e) {
        (void)e;
    }
    sHandle = nil;
    NSString *cur = MFCarPlayLogFilePath();
    NSString *old = [MFDocumentsPath() stringByAppendingPathComponent:@"carplay.1.log"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:old error:NULL];
    [fm moveItemAtPath:cur toPath:old error:NULL];
    sWritten = 0;
}

static void MFEnsureHandle(void) {
    if (sHandle) {
        return;
    }
    NSString *path = MFCarPlayLogFilePath();
    sPath = path;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:[NSData data] attributes:nil];
    }
    sHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [sHandle seekToEndOfFile];
        sWritten = [sHandle offsetInFile];
    } @catch (NSException *e) {
        (void)e;
        sWritten = 0;
    }

    if (!sHeaderDone) {
        sHeaderDone = YES;
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *ver = info[@"CFBundleVersion"] ?: @"?";
        NSString *shortVer = info[@"CFBundleShortVersionString"] ?: @"?";
        NSString *sys = [[UIDevice currentDevice] systemVersion] ?: @"?";
        NSString *model = [[UIDevice currentDevice] model] ?: @"?";
        NSString *header = [NSString stringWithFormat:
            @"\n===== MusicFree CarPlay log =====\n"
            @"build      = %@ (short %@)\n"
            @"iOS        = %@  model = %@\n"
            @"started at = %@\n"
            @"file       = %@\n"
            @"=================================\n",
            ver, shortVer, sys, model,
            [NSDate date], path];
        NSData *d = [header dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            [sHandle writeData:d];
            sWritten += d.length;
        } @catch (NSException *e) {
            (void)e;
        }
    }
}

static void MFWriteLine(NSString *line) {
    MFEnsureQueue();
    dispatch_async(sLogQueue, ^{
        MFEnsureHandle();
        MFRotateIfNeeded();
        MFEnsureHandle();
        if (!sHandle) {
            return;
        }
        NSString *stamped = [NSString stringWithFormat:@"%@ %@\n",
                             [NSDate date], line ?: @""];
        NSData *d = [stamped dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            [sHandle writeData:d];
            sWritten += d.length;
        } @catch (NSException *e) {
            (void)e;
        }
    });
}

void MFCarPlayLog(NSString *format, ...) {
    if (!format) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    MFWriteLine(msg);
}

void MFCarPlayLogBoth(NSString *format, ...) {
    if (!format) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[MusicFree][CarPlay] %@", msg);
    MFWriteLine([NSString stringWithFormat:@"[MusicFree][CarPlay] %@", msg]);
}
