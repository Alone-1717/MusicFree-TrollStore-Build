/*
 * MFCarPlayNativeData.m — CarPlay 原生数据源（不依赖 React Native 运行时）
 *
 * 背景：
 *   11142620 真机日志证明，无线 CarPlay 以 intent background 冷启动 App 时，
 *   RN 运行时没有初始化（bridge init / carPlayJSReady 零出现）。
 *   因此"等 JS 推歌单"这条路在车机上是死的 —— 必须由原生直接读数据。
 *
 * 数据来源：
 *   App 的歌单存在 MMKV 里：
 *     实例 id = "LocalSheet.music-sheets"，key = "data"，值是 JSON 字符串
 *     实例 id = "LocalSheet.<sheetId>"，  key = "data"，值是曲目 JSON 数组
 *   MMKV 的 pod 名是 MMKV，头文件 <MMKV/MMKV.h>。
 *
 * 重要设计原则：
 *   1) 任何一步失败都返回空数组，绝不抛异常。车机上宁可显示"暂无歌单",
 *      也不能因为读数据把 CarPlay 场景搞崩。
 *   2) MMKV 未就绪（例如它依赖的 JSI 还没起来）时，用 @try 兜住，
 *      并把失败原因写进诊断字符串，方便下次日志定位。
 *   3) 不缓存：车机每次进模板都重新读，确保手机上新增歌单能立刻看到。
 */
#import "MFCarPlayNativeData.h"
#import "MFCarPlayLog.h"

#if __has_include(<MMKV/MMKV.h>)
#import <MMKV/MMKV.h>
#define MF_HAVE_MMKV 1
#elif __has_include("MMKV.h")
#import "MMKV.h"
#define MF_HAVE_MMKV 1
#else
#define MF_HAVE_MMKV 0
#endif

static NSString *const kMFSheetDirKey = @"LocalSheet.music-sheets";
static NSString *const kMFDataKey = @"data";

/* 诊断信息累积，供 MFCarPlayNativeDataDiagnosis 返回 */
static NSMutableArray<NSString *> *sDiag = nil;

static void MFDiag(NSString *fmt, ...) {
    if (!fmt) { return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDiag = [NSMutableArray array];
    });
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (sDiag.count < 40) {
        [sDiag addObject:msg];
    }
    MFCarPlayLog(@"[native-data] %@", msg);
}

/* 从 MMKV 读某个实例的 data 键并解析成 JSON 对象 */
static id MFReadJSON(NSString *mmkvId) {
#if MF_HAVE_MMKV
    @try {
        MMKV *kv = [MMKV mmkvWithID:mmkvId];
        if (!kv) {
            MFDiag(@"mmkv(%@) = nil", mmkvId);
            return nil;
        }
        NSString *raw = [kv getStringForKey:kMFDataKey];
        if (!raw || raw.length == 0) {
            MFDiag(@"mmkv(%@) data = empty", mmkvId);
            return nil;
        }
        NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
        if (!obj) {
            MFDiag(@"mmkv(%@) json parse failed: %@", mmkvId, err.localizedDescription);
            return nil;
        }
        MFDiag(@"mmkv(%@) ok, type=%@ len=%lu",
               mmkvId, NSStringFromClass([obj class]), (unsigned long)raw.length);
        return obj;
    } @catch (NSException *e) {
        MFDiag(@"mmkv(%@) threw: %@", mmkvId, e.reason);
        return nil;
    }
#else
    MFDiag(@"MMKV header not available at compile time");
    return nil;
#endif
}

NSArray<NSDictionary *> *MFCarPlayNativeSheets(void) {
    id obj = MFReadJSON(kMFSheetDirKey);
    if (![obj isKindOfClass:[NSArray class]]) {
        MFDiag(@"sheets: not an array (%@)", NSStringFromClass([obj class]));
        return @[];
    }
    NSArray *arr = (NSArray *)obj;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];

    for (id item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *d = (NSDictionary *)item;
        NSString *sid = nil;
        id rawId = d[@"id"];
        if ([rawId isKindOfClass:[NSString class]]) {
            sid = rawId;
        } else if ([rawId respondsToSelector:@selector(stringValue)]) {
            sid = [rawId stringValue];
        }
        if (sid.length == 0) {
            continue;
        }
        NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : @"未命名歌单";
        /* count 字段可能不存在，就实时数一下曲目 */
        NSNumber *count = nil;
        if ([d[@"count"] isKindOfClass:[NSNumber class]]) {
            count = d[@"count"];
        } else {
            id tracks = MFReadJSON([NSString stringWithFormat:@"LocalSheet.%@", sid]);
            if ([tracks isKindOfClass:[NSArray class]]) {
                count = @([(NSArray *)tracks count]);
            }
        }
        [out addObject:@{
            @"id": sid,
            @"title": title,
            @"count": count ?: @(0),
        }];
    }
    MFDiag(@"sheets total = %lu (raw %lu)", (unsigned long)out.count, (unsigned long)arr.count);
    return out;
}

NSArray<NSDictionary *> *MFCarPlayNativeTracks(NSString *sheetId) {
    if (sheetId.length == 0) {
        return @[];
    }
    id obj = MFReadJSON([NSString stringWithFormat:@"LocalSheet.%@", sheetId]);
    if (![obj isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSArray *arr = (NSArray *)obj;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];

    for (id item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *d = (NSDictionary *)item;
        NSString *tid = nil;
        /* MusicFree 的曲目 id 可能是 id / primaryKey / platform+id 组合 */
        id rawId = d[@"id"] ?: d[@"primaryKey"];
        if ([rawId isKindOfClass:[NSString class]]) {
            tid = rawId;
        } else if ([rawId respondsToSelector:@selector(stringValue)]) {
            tid = [rawId stringValue];
        }
        if (tid.length == 0) {
            continue;
        }
        NSString *title = nil;
        if ([d[@"title"] isKindOfClass:[NSString class]]) {
            title = d[@"title"];
        } else {
            title = @"未知歌曲";
        }
        NSString *artist = @"";
        id ar = d[@"artist"];
        if ([ar isKindOfClass:[NSString class]]) {
            artist = ar;
        } else if ([ar isKindOfClass:[NSArray class]]) {
            /* 部分插件给的是数组 */
            NSMutableArray *names = [NSMutableArray array];
            for (id a in (NSArray *)ar) {
                if ([a isKindOfClass:[NSString class]]) {
                    [names addObject:a];
                }
            }
            artist = [names componentsJoinedByString:@"/"];
        }
        [out addObject:@{
            @"id": tid,
            @"title": title,
            @"artist": artist,
        }];
    }
    MFDiag(@"tracks sheet=%@ total = %lu", sheetId, (unsigned long)out.count);
    return out;
}

NSString *MFCarPlayNativeDataDiagnosis(void) {
    if (!sDiag) {
        return @"(no diagnosis yet)";
    }
    return [sDiag componentsJoinedByString:@" | "];
}
