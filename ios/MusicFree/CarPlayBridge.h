//
//  CarPlayBridge.h
//  Phase 1: RN <-> CarPlay 双向桥
//
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

/**
 * 车机 -> JS 事件通过 NSNotificationCenter 发到本类，再 sendEvent 给 RN。
 * JS -> 车机 数据（歌单/曲目/播放状态）通过 exported methods 传入，
 * 存到静态单例，CarPlaySceneDelegate 读取后刷新模板。
 */
@interface MFCarPlayBridge : RCTEventEmitter <RCTBridgeModule>

/** 单例，供 CarPlaySceneDelegate 读取 JS 推来的数据 */
+ (instancetype)shared;

/** JS 推送歌单列表：@[{id, title, count}] */
- (void)setSheets:(NSArray *)sheets;
/** JS 推送某歌单的曲目：@[{id, title, artist}] */
- (void)setTracks:(NSArray *)tracks forSheetId:(NSString *)sheetId;
/** JS 推送正在播放信息 */
- (void)setNowPlayingTitle:(NSString *)title artist:(NSString *)artist;

/** 车机侧读取 */
- (NSArray *)sheets;
- (NSArray *)tracksForSheetId:(NSString *)sheetId;
- (NSDictionary *)nowPlaying;

/** 车机点击某首曲目 -> 通知 JS */
+ (void)emitPlayTrack:(NSString *)trackId sheetId:(NSString *)sheetId;
/** 车机点某个歌单 -> 请求 JS 推该歌单曲目 */
+ (void)emitRequestTracks:(NSString *)sheetId;
/** 车机播放控制 */
+ (void)emitControl:(NSString *)action;

/* ============ 11142655：JS -> 原生 新通道 ============ */

/**
 * 原生 -> JS：请求联网搜索。
 * JS 收到后调插件搜索，再用 setSearchResults:query: 回传。
 */
+ (void)emitSearch:(NSString *)query;

/**
 * JS 运行时是否已就绪。
 * 原生搜索页据此决定：
 *   已就绪 -> 发 emitSearch 请求联网
 *   未就绪 -> 只显示本地结果 + 提示
 */
+ (BOOL)isJSReady;

/** 最近一次联网搜索结果（JS 回传后保存在此） */
- (NSArray *)searchResults;
/** 最近一次搜索词（用于校验结果是否过期） */
- (NSString *)lastSearchQuery;
/** 最近一次播放状态快照 */
- (NSDictionary *)nowPlayingState;
/** 11142657：当前歌词 @[{time, lrc, translation}] */
- (NSArray *)lyric;

/* ============ 11142662：榜单 ============ */

/**
 * 原生 -> JS：请求某个榜单的曲目。
 * JS 收到后调插件 getTopListDetail，再用 setTopListTracks:listId: 回传。
 */
+ (void)emitTopListDetail:(NSString *)pluginHash
                   listId:(NSString *)listId
                    title:(NSString *)title;

/** 榜单列表（平铺所有插件） */
- (NSArray *)topLists;
/** 最近一次榜单曲目 */
- (NSArray *)topListTracks;
/** 上面曲目属于哪个榜单 */
- (NSString *)topListTracksListId;

/** JS 监听器注册完成后主动冲刷 RN 就绪前排队的车机事件 */
- (void)carPlayJSReady;

@end
