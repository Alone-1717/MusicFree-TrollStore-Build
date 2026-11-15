/*
 * MFCarPlayLog.h — CarPlay 日志双写
 *
 * 为什么需要它：
 *   爱思 / 3uTools 的“实时日志”只给系统 framework 层，
 *   抓不到 app 自己的 NSLog（实测 4427 行日志里 [MusicFree][CarPlay] = 0 条）。
 *   为了能在没有 Mac / 没有 idevicesyslog 的 Windows 上拿到 CarPlay 日志，
 *   这里把每条日志**同时**写进 App 沙盒：
 *       <沙盒>/Documents/carplay.log
 *   配合 Info.plist 的 UIFileSharingEnabled=true，
 *   用 3uTools「文件管理 → 应用 → MusicFree → Documents」可直接拖出。
 *
 * 两种调用方式：
 *   MFCarPlayLog(fmt, ...)        —— 只写文件，不打印
 *   MFCarPlayLogBoth(fmt, ...)    —— 同时 NSLog + 写文件（推荐，兼容已有的 syslog 抓法）
 *
 * 线程安全：内部用 dispatch_queue 串行追加。
 * 体积控制：超过 512KB 自动轮转（carplay.log -> carplay.1.log），最多保留 2 个。
 */
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void MFCarPlayLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void MFCarPlayLogBoth(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/* 返回当前日志文件绝对路径（便于在别处打一行提示） */
NSString *MFCarPlayLogFilePath(void);

#ifdef __cplusplus
}
#endif
