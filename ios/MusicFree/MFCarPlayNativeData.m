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

/*
 * 11142649：可指定 key 的 MMKV JSON 读取。
 *
 * 现有的 MFReadJSON(mmkvId) 硬编码 kMFDataKey(@"data")，
 * 那是 LocalSheet.* 的格式。而最近播放用的是
 *   music.MusicHistory 实例 + "history" key，
 * 所以需要这个通用版本。
 */
static id MFReadMMKVJSON(NSString *mmkvId, NSString *key) {
#if MF_HAVE_MMKV
    @try {
        MMKV *kv = [MMKV mmkvWithID:mmkvId];
        if (!kv) {
            MFDiag(@"mmkv(%@) = nil", mmkvId);
            return nil;
        }
        NSString *raw = [kv getStringForKey:key];
        if (!raw || raw.length == 0) {
            MFDiag(@"mmkv(%@)[%@] = empty", mmkvId, key);
            return nil;
        }
        NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
        if (!obj) {
            MFDiag(@"mmkv(%@)[%@] parse failed: %@", mmkvId, key, err.localizedDescription);
            return nil;
        }
        MFDiag(@"mmkv(%@)[%@] ok, type=%@ len=%lu",
               mmkvId, key, NSStringFromClass([obj class]), (unsigned long)raw.length);
        return obj;
    } @catch (NSException *e) {
        MFDiag(@"mmkv(%@)[%@] threw: %@", mmkvId, key, e.reason);
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
        /*
         * 11142652: add coverImg for the CarPlay sheet list.
         *
         * JS side (src/core/musicSheet/index.ts) sets:
         *   coverImg: musicList.at(0)?.artwork
         * i.e. the first track's artwork. So prefer coverImg,
         * fall back to the first track's artwork field.
         */
        NSString *cover = @"";
        id cimg = d[@"coverImg"];
        if ([cimg isKindOfClass:[NSString class]] && [cimg length] > 0) {
            cover = (NSString *)cimg;
        }
        if (cover.length == 0) {
            id tr = MFReadJSON([NSString stringWithFormat:@"LocalSheet.%@", sid]);
            if ([tr isKindOfClass:[NSArray class]] && [tr count] > 0) {
                id first = [tr firstObject];
                if ([first isKindOfClass:[NSDictionary class]]) {
                    id art = ((NSDictionary *)first)[@"artwork"];
                    if ([art isKindOfClass:[NSString class]]) {
                        cover = (NSString *)art;
                    }
                }
            }
        }

        [out addObject:@{
            @"id": sid,
            @"title": title,
            @"count": count ?: @(0),
            @"coverImg": cover ?: @"",
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

#pragma mark - 11142649：最近播放 + 搜索

/*
 * 把 IMusic.IMusicItem 归一化成车机用的 dict。
 * 字段映射与 MFCarPlayNativeTracks 保持一致，另加 platform 供点播定位。
 */
static NSDictionary *MFNormalizeTrack(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *tid = nil;
    for (NSString *k in @[@"id", @"musicItemId"]) {
        id v = d[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            tid = (NSString *)v;
            break;
        }
    }
    if (tid.length == 0) {
        return nil;
    }
    NSString *title = [d[@"title"] isKindOfClass:[NSString class]]
        ? d[@"title"] : @"未知歌曲";

    NSString *artist = @"";
    id ar = d[@"artist"];
    if ([ar isKindOfClass:[NSString class]]) {
        artist = (NSString *)ar;
    } else if ([ar isKindOfClass:[NSArray class]]) {
        NSMutableArray *names = [NSMutableArray array];
        for (id a in (NSArray *)ar) {
            if ([a isKindOfClass:[NSString class]]) {
                [names addObject:a];
            }
        }
        artist = [names componentsJoinedByString:@"/"];
    }

    NSString *platform = [d[@"platform"] isKindOfClass:[NSString class]]
        ? d[@"platform"] : @"";

    /*
     * 11142653: include artwork/album so the CarPlay lists can show covers.
     * History (music.MusicHistory) items do carry artwork, but the old
     * normalizer dropped it, which is why the 最近播放 tab had no covers.
     */
    NSString *artwork = [d[@"artwork"] isKindOfClass:[NSString class]]
        ? d[@"artwork"] : @"";
    NSString *album = [d[@"album"] isKindOfClass:[NSString class]]
        ? d[@"album"] : @"";

    return @{
        @"id": tid,
        @"title": title,
        @"artist": artist,
        @"platform": platform,
        @"artwork": artwork ?: @"",
        @"album": album ?: @"",
    };
}

NSArray<NSDictionary *> *MFCarPlayNativeHistory(NSUInteger limit) {
    /*
     * 数据源：src/core/musicHistory.ts
     *   getOrCreateMMKV("music.MusicHistory")，key = "history"
     *   值为 IMusic.IMusicItem[] JSON（最新在前）
     */
    @try {
        id obj = MFReadMMKVJSON(@"music.MusicHistory", @"history");
        if (![obj isKindOfClass:[NSArray class]]) {
            MFDiag(@"history: not an array (%@)", NSStringFromClass([obj class]));
            return @[];
        }
        NSArray *arr = (NSArray *)obj;
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        NSUInteger max = (limit == 0) ? arr.count : MIN(limit, arr.count);
        for (NSUInteger i = 0; i < max; i++) {
            NSDictionary *n = MFNormalizeTrack(arr[i]);
            if (n) {
                [out addObject:n];
            }
        }
        MFDiag(@"history total = %lu (requested %lu)",
              (unsigned long)out.count, (unsigned long)limit);
        return out;
    } @catch (NSException *e) {
        MFDiag(@"history threw: %@", e.reason);
        return @[];
    }
}

NSArray<NSDictionary *> *MFCarPlayNativeSearchTracks(NSString *query) {
    if (![query isKindOfClass:[NSString class]] || query.length == 0) {
        return @[];
    }
    NSString *q = [query lowercaseString];

    @try {
        NSArray<NSDictionary *> *sheets = MFCarPlayNativeSheets();
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];

        for (NSDictionary *s in sheets) {
            NSString *sid = [s[@"id"] isKindOfClass:[NSString class]] ? s[@"id"] : nil;
            if (sid.length == 0) {
                continue;
            }
            NSString *sheetTitle = [s[@"title"] isKindOfClass:[NSString class]]
                ? s[@"title"] : @"";
            NSArray<NSDictionary *> *tracks = MFCarPlayNativeTracks(sid);
            for (NSDictionary *tr in tracks) {
                NSString *tt = tr[@"title"] ?: @"";
                NSString *ar = tr[@"artist"] ?: @"";
                BOOL hit = [[tt lowercaseString] containsString:q]
                        || [[ar lowercaseString] containsString:q];
                if (!hit) {
                    continue;
                }
                NSString *tid = tr[@"id"] ?: @"";
                NSString *key = [NSString stringWithFormat:@"%@|%@", sid, tid];
                if ([seen containsObject:key]) {
                    continue;
                }
                [seen addObject:key];
                [out addObject:@{
                    @"id": tid,
                    @"title": tt,
                    @"artist": ar,
                    @"platform": tr[@"platform"] ?: @"",
                    @"sheetId": sid,
                    @"sheetTitle": sheetTitle,
                }];
                if (out.count >= 100) {
                    break;
                }
            }
            if (out.count >= 100) {
                break;
            }
        }
        MFDiag(@"search '%@' hits = %lu", query, (unsigned long)out.count);
        return out;
    } @catch (NSException *e) {
        MFDiag(@"search threw: %@", e.reason);
        return @[];
    }
}

#pragma mark - 11142650：当前播放状态 + 播放队列

/*
 * 读 App.PersistStatus 里的单个值（非 JSON，直接是 MMKV 原生类型或字符串）。
 */
static NSString *MFReadPersistString(NSString *key) {
#if MF_HAVE_MMKV
    @try {
        MMKV *kv = [MMKV mmkvWithID:@"App.PersistStatus"];
        if (!kv) {
            MFDiag(@"persist = nil");
            return nil;
        }
        return [kv getStringForKey:key];
    } @catch (NSException *e) {
        MFDiag(@"persist(%@) threw: %@", key, e.reason);
        return nil;
    }
#else
    return nil;
#endif
}

static double MFReadPersistDouble(NSString *key) {
#if MF_HAVE_MMKV
    @try {
        MMKV *kv = [MMKV mmkvWithID:@"App.PersistStatus"];
        if (!kv) {
            return 0;
        }
        return [kv getDoubleForKey:key];
    } @catch (NSException *e) {
        return 0;
    }
#else
    return 0;
#endif
}

static id MFReadPersistJSON(NSString *key) {
    NSString *raw = MFReadPersistString(key);
    if (!raw || raw.length == 0) {
        return nil;
    }
    NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) {
        return nil;
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (!obj) {
        MFDiag(@"persist(%@) parse failed: %@", key, err.localizedDescription);
    }
    return obj;
}

/*
 * IMusicItem -> 车机 dict，含专辑/封面/时长。
 */
static NSDictionary *MFTrackFull(NSDictionary *d) {
    NSDictionary *base = MFNormalizeTrack(d);
    if (!base) {
        return nil;
    }
    NSMutableDictionary *out = [base mutableCopy];

    NSString *album = [d[@"album"] isKindOfClass:[NSString class]] ? d[@"album"] : @"";
    out[@"album"] = album;

    NSString *artwork = [d[@"artwork"] isKindOfClass:[NSString class]] ? d[@"artwork"] : @"";
    out[@"artwork"] = artwork;

    id dur = d[@"duration"];
    out[@"duration"] = [dur isKindOfClass:[NSNumber class]] ? dur : @(0);

    return out;
}

NSDictionary *MFCarPlayNativeNowPlaying(void) {
    @try {
        id raw = MFReadPersistJSON(@"music.musicItem");
        if (![raw isKindOfClass:[NSDictionary class]]) {
            MFDiag(@"nowPlaying: no current music (%@)",
                   NSStringFromClass([raw class]));
            return nil;
        }
        NSMutableDictionary *np = [MFTrackFull((NSDictionary *)raw) mutableCopy];
        if (!np) {
            return nil;
        }

        np[@"progress"] = @(MFReadPersistDouble(@"music.progress"));
        np[@"rate"] = @(MFReadPersistDouble(@"music.rate"));

        NSString *repeat = MFReadPersistString(@"music.repeatMode");
        np[@"repeatMode"] = repeat ?: @"loop";

        NSString *quality = MFReadPersistString(@"music.quality");
        np[@"quality"] = quality ?: @"standard";

        id queue = MFReadPersistJSON(@"music.playList");
        np[@"queueCount"] = [queue isKindOfClass:[NSArray class]]
            ? @([(NSArray *)queue count]) : @(0);

        MFDiag(@"nowPlaying: %@ / %@ duration=%@ progress=%@ queue=%@",
               np[@"title"], np[@"artist"], np[@"duration"],
               np[@"progress"], np[@"queueCount"]);
        return np;
    } @catch (NSException *e) {
        MFDiag(@"nowPlaying threw: %@", e.reason);
        return nil;
    }
}

NSArray<NSDictionary *> *MFCarPlayNativePlayQueue(void) {
    @try {
        id raw = MFReadPersistJSON(@"music.playList");
        if (![raw isKindOfClass:[NSArray class]]) {
            MFDiag(@"playQueue: not an array (%@)", NSStringFromClass([raw class]));
            return @[];
        }
        NSArray *arr = (NSArray *)raw;
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        for (id item in arr) {
            NSDictionary *n = MFTrackFull(item);
            if (n) {
                [out addObject:n];
            }
        }
        MFDiag(@"playQueue total = %lu", (unsigned long)out.count);
        return out;
    } @catch (NSException *e) {
        MFDiag(@"playQueue threw: %@", e.reason);
        return @[];
    }
}

NSString *MFCarPlayNativeDataDiagnosis(void) {
    if (!sDiag) {
        return @"(no diagnosis yet)";
    }
    return [sDiag componentsJoinedByString:@" | "];
}
