//
//  CarPlayBridge.m — Phase 1 stable
//
//  冷启动竞态修复：
//    车机以 `intent background` 拉起 App 时，MFCarPlaySceneDelegate 会立刻
//    emitControl:@"requestSheets"，但 RN bundle / RCTEventEmitter 还没实例化，
//    旧实现直接 post 一个没人接的 NSNotification -> 事件永久丢失 ->
//    车机一直停在占位模板，日志里也看不到 `[CarPlay] push N sheets`。
//
//  现在 +postEvent: 在 sharedInstance 尚无监听时把事件压入进程级 pending 队列，
//  Bridge init / startObserving 就绪后统一 flush 给 JS。
//  队列带上限与去重，避免 scene 反复 activate 时无限堆积。
//
#import "CarPlayBridge.h"
#import <React/RCTLog.h>
#import "MFCarPlayLog.h"

static NSString *const kMFCarPlayEventNotification = @"MFCarPlayEventNotification";
static NSString *const kMFCarPlayDataDidUpdate = @"MFCarPlayDataDidUpdate";

/*
 * 11142655：JS -> 原生 的三条新通道。
 *
 * 为什么需要它们：
 *   进度条走动、播放/暂停图标切换、联网搜索都需要 JS 把状态回传给原生。
 *
 *   事件名（原生广播用）：
 *     MFCarPlaySearchResults     JS 回传搜索结果
 *     MFCarPlayNowPlayingState   JS 回传播放状态
 *     MFCarPlayJSReady           JS 通知运行时已就绪
 */
static NSString *const kMFCarPlaySearchResults = @"MFCarPlaySearchResults";
static NSString *const kMFCarPlayNowPlayingState = @"MFCarPlayNowPlayingState";
static NSString *const kMFCarPlayJSReady = @"MFCarPlayJSReady";
/* 11142657：歌词推送（JS -> 原生） */
static NSString *const kMFCarPlayLyric = @"MFCarPlayLyric";
/* 11142662：榜单 */
static NSString *const kMFCarPlayTopLists = @"MFCarPlayTopLists";
static NSString *const kMFCarPlayTopListTracks = @"MFCarPlayTopListTracks";

/* JS 就绪标记（进程级，供原生判断要不要等 JS） */
static BOOL sJSReady = NO;

/* 进程级静态：RN 就绪前的车机事件不能丢 */
static NSMutableArray<NSDictionary *> *sPendingEvents = nil;
static NSUInteger const kMFCarPlayMaxPendingEvents = 50;

@interface MFCarPlayBridge ()
@property (nonatomic, strong) NSArray *sheetsData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *tracksData;
@property (nonatomic, strong) NSDictionary *nowPlayingData;
@property (atomic, assign) BOOL hasListeners;
/* 11142655：最近一次搜索结果与播放状态（供车机随时读取） */
@property (nonatomic, strong) NSArray *searchResultsData;
@property (nonatomic, strong) NSDictionary *nowPlayingStateData;
@property (nonatomic, copy) NSString *lastSearchQuery;
/* 11142657：当前歌词（@[{time, lrc, translation}]） */
@property (nonatomic, strong) NSArray *lyricLines;
/* 11142662：榜单列表 + 某个榜单的曲目 */
@property (nonatomic, strong) NSArray *topListsData;
@property (nonatomic, strong) NSArray *topListTracksData;
@property (nonatomic, copy) NSString *topListTracksId;
- (void)postDataUpdate:(NSDictionary *)userInfo;
- (void)sendCarPlayEvent:(NSString *)name body:(NSDictionary *)body;
- (void)flushPendingEvents;
@end

static MFCarPlayBridge *sharedInstance = nil;

@implementation MFCarPlayBridge

+ (void)initialize {
    if (self == [MFCarPlayBridge class]) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            sPendingEvents = [NSMutableArray array];
        });
    }
}

+ (instancetype)shared {
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _sheetsData = @[];
        _tracksData = [NSMutableDictionary dictionary];
        _nowPlayingData = @{};
        _searchResultsData = @[];
        _nowPlayingStateData = @{};
        _lastSearchQuery = @"";
        _lyricLines = @[];
        _topListsData = @[];
        _topListTracksData = @[];
        _topListTracksId = @"";
        sharedInstance = self;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleCarPlayEvent:)
                                                     name:kMFCarPlayEventNotification
                                                   object:nil];
        MFCarPlayLogBoth(@"BRIDGE init, pending=%lu",
              (unsigned long)sPendingEvents.count);
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (sharedInstance == self) {
        sharedInstance = nil;
    }
}

RCT_EXPORT_MODULE(CarPlayBridge);

+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"CarPlayPlayTrack", @"CarPlayRequestTracks", @"CarPlayControl",
             @"CarPlaySearch", @"CarPlayTopListDetail"];
}

- (void)startObserving {
    self.hasListeners = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        MFCarPlayLogBoth(@"BRIDGE startObserving, flush pending=%lu",
              (unsigned long)sPendingEvents.count);
        [self flushPendingEvents];
    });
}

- (void)stopObserving {
    self.hasListeners = NO;
}

/** JS 侧 setupCarPlay 完成监听注册后显式调用，覆盖 EventEmitter 时序抖动 */
RCT_EXPORT_METHOD(carPlayJSReady)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hasListeners = YES;
        sJSReady = YES;
        [self flushPendingEvents];
        [self postDataUpdate:@{@"kind": @"sheets"}];

        /* 11142655：广播 JS 就绪，原生搜索页可据此决定是否请求联网 */
        [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlayJSReady
                                                            object:nil
                                                          userInfo:nil];
        MFCarPlayLogBoth(@"BRIDGE JS READY (sJSReady=1) -- JS runtime is up");
    });
}

#pragma mark - JS -> 车机（数据）

RCT_EXPORT_METHOD(setSheets:(NSArray *)sheets)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    self.sheetsData = [sheets isKindOfClass:[NSArray class]] ? sheets : @[];
    [self postDataUpdate:@{@"kind": @"sheets"}];

    });
}

RCT_EXPORT_METHOD(setTracks:(NSArray *)tracks forSheetId:(NSString *)sheetId)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    if (![sheetId isKindOfClass:[NSString class]]) {
        return;
    }
    self.tracksData[sheetId] = [tracks isKindOfClass:[NSArray class]] ? tracks : @[];
    [self postDataUpdate:@{@"kind": @"tracks", @"sheetId": sheetId}];

    });
}

RCT_EXPORT_METHOD(setNowPlaying:(NSString *)title artist:(NSString *)artist)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    self.nowPlayingData = @{
        @"title": title ?: @"",
        @"artist": artist ?: @"",
    };
    [self postDataUpdate:@{@"kind": @"nowPlaying"}];

    });
}

#pragma mark - 11142655：JS -> 原生 新通道

/*
 * JS 回传搜索结果。
 *
 * query 用于校验：原生可能已经换了搜索词，旧结果要丢弃。
 * 结果同时写进 NSNotification，RootVC 收到后刷新表格。
 */
RCT_EXPORT_METHOD(setSearchResults:(NSArray *)results query:(NSString *)query)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    /*
     * 11142667：切主线程（JS 线程改 UI 会闪退）。
     * 参数在闭包外先归一化，避免闭包内重赋值需要 __block。
     */
    NSString *safeQuery = [query isKindOfClass:[NSString class]] ? query : @"";
    NSArray *safeResults = [results isKindOfClass:[NSArray class]] ? results : @[];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.searchResultsData = safeResults;
        self.lastSearchQuery = safeQuery;

        MFCarPlayLogBoth(@"BRIDGE got %lu search results for '%@'",
              (unsigned long)safeResults.count, safeQuery);

        [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlaySearchResults
                                                            object:nil
                                                          userInfo:@{
            @"query": safeQuery,
            @"results": safeResults,
        }];
    });
}

/*
 * JS 回传播放状态（实时更新用）。
 *
 * 字段（都可缺省）：
 *   title, artist, album, artwork,
 *   progress   NSNumber 秒
 *   duration   NSNumber 秒
 *   isPlaying  NSNumber BOOL
 *   repeatMode NSString
 *   quality    NSString
 *   rate       NSNumber
 *   isFavorite NSNumber BOOL
 */
RCT_EXPORT_METHOD(setNowPlayingState:(NSDictionary *)state)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    if (![state isKindOfClass:[NSDictionary class]]) {
        return;
    }
    self.nowPlayingStateData = state;

    /* 播放状态变化频繁（每秒一次），日志降噪：只在关键字段变化时打 */
    static NSString *sLastSignature = nil;
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@",
                           state[@"title"] ?: @"",
                           state[@"isPlaying"] ?: @"",
                           state[@"progress"] ?: @""];
    if (![signature isEqualToString:sLastSignature ?: @""]) {
        sLastSignature = [signature copy];
        NSLog(@"[MusicFree][CarPlay] BRIDGE nowPlayingState: %@ - %@ playing=%@ progress=%@",
              state[@"title"] ?: @"?",
              state[@"artist"] ?: @"?",
              state[@"isPlaying"] ?: @"?",
              state[@"progress"] ?: @"?");
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlayNowPlayingState
                                                        object:nil
                                                      userInfo:state];

    });
}

/*
 * ============ 11142657：歌词推送 ============
 *
 * JS 侧取到歌词后调用：
 *   NativeBridge.setLyric([
 *     { time: 12.34, lrc: "歌词文本", translation: "翻译（可选）" },
 *     ...
 *   ])
 *
 * 时间为秒（浮点）。原生按此排序后供播放页滚动显示。
 */
RCT_EXPORT_METHOD(setLyric:(NSArray *)lines)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    NSArray *arr = [lines isKindOfClass:[NSArray class]] ? lines : @[];

    /*
     * 防御排序：按 time 升序。
     * 插件返回的歌词通常已排序，但不保证，这里统一处理。
     */
    NSArray *sorted = [arr sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        double ta = [a isKindOfClass:[NSDictionary class]] ? [a[@"time"] doubleValue] : 0;
        double tb = [b isKindOfClass:[NSDictionary class]] ? [b[@"time"] doubleValue] : 0;
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    self.lyricLines = sorted;

    MFCarPlayLogBoth(@"BRIDGE got %lu lyric lines", (unsigned long)sorted.count);

    [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlayLyric
                                                        object:nil
                                                      userInfo:@{@"lines": sorted}];

    });
}

/* 查询当前歌词 */
- (NSArray *)lyric {
    return self.lyricLines ?: @[];
}

#pragma mark - 11142662：榜单

/*
 * JS 回传榜单列表（已平铺所有插件的榜单）。
 *
 * 每项：{ pluginHash, pluginName, id, title, coverImg, description }
 */
RCT_EXPORT_METHOD(setTopLists:(NSArray *)lists)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    self.topListsData = [lists isKindOfClass:[NSArray class]] ? lists : @[];
    MFCarPlayLogBoth(@"BRIDGE got %lu top lists",
          (unsigned long)self.topListsData.count);

    [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlayTopLists
                                                        object:nil
                                                      userInfo:@{@"lists": self.topListsData}];

    });
}

/*
 * JS 回传某个榜单的曲目。
 *
 * listId 用于校验：用户可能已经点了别的榜单，旧结果要丢弃。
 */
RCT_EXPORT_METHOD(setTopListTracks:(NSArray *)tracks listId:(NSString *)listId)
{
    /*
     * 11142667：切主线程。
     *
     * RCT_EXPORT_METHOD 默认在 JS 线程队列执行，
     * 但方法内部会 post NSNotification，监听方要改 UI。
     * 从后台线程改 UI 必然闪退 —— 这是搜索/榜单闪退的根因。
     */
    dispatch_async(dispatch_get_main_queue(), ^{

    self.topListTracksData = [tracks isKindOfClass:[NSArray class]] ? tracks : @[];
    self.topListTracksId = [listId isKindOfClass:[NSString class]] ? listId : @"";

    MFCarPlayLogBoth(@"BRIDGE got %lu tracks for top list '%@'",
          (unsigned long)self.topListTracksData.count, self.topListTracksId);

    [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlayTopListTracks
                                                        object:nil
                                                      userInfo:@{
        @"listId": self.topListTracksId,
        @"tracks": self.topListTracksData,
    }];

    });
}

/* 查询接口 */
- (NSArray *)topLists {
    return self.topListsData ?: @[];
}

- (NSArray *)topListTracks {
    return self.topListTracksData ?: @[];
}

- (NSString *)topListTracksListId {
    return self.topListTracksId ?: @"";
}

/*
 * 原生 -> JS：请求拉取某个榜单的曲目。
 */
+ (void)emitTopListDetail:(NSString *)pluginHash listId:(NSString *)listId title:(NSString *)title {
    [self postEvent:@"CarPlayTopListDetail" body:@{
        @"pluginHash": pluginHash ?: @"",
        @"listId": listId ?: @"",
        @"title": title ?: @"",
    }];
    NSLog(@"[MusicFree][CarPlay] emitted CarPlayTopListDetail '%@'", title);
}

/*
 * 查询接口：原生搜索页可随时读取最近一次结果。
 */
- (NSArray *)searchResults {
    return self.searchResultsData ?: @[];
}

- (NSString *)lastSearchQuery {
    return _lastSearchQuery ?: @"";
}

- (NSDictionary *)nowPlayingState {
    return self.nowPlayingStateData ?: @{};
}

/*
 * 供原生判断 JS 是否就绪（决定搜索走本地还是请求联网）。
 */
+ (BOOL)isJSReady {
    return sJSReady;
}

/*
 * 原生 -> JS：请求联网搜索。
 */
+ (void)emitSearch:(NSString *)query {
    if (![query isKindOfClass:[NSString class]] || query.length == 0) {
        return;
    }
    [self postEvent:@"CarPlaySearch" body:@{@"query": query}];
    NSLog(@"[MusicFree][CarPlay] emitted CarPlaySearch '%@'", query);
}

- (void)postDataUpdate:(NSDictionary *)userInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kMFCarPlayDataDidUpdate
                                                            object:nil
                                                          userInfo:userInfo];
    });
}

#pragma mark - 车机侧读取（RN 未就绪时全部返回空，首屏不依赖这里）

- (NSArray *)sheets {
    return self.sheetsData ?: @[];
}

- (NSArray *)tracksForSheetId:(NSString *)sheetId {
    return self.tracksData[sheetId] ?: @[];
}

- (NSDictionary *)nowPlaying {
    return self.nowPlayingData ?: @{};
}

#pragma mark - 车机 -> JS（事件，带 pending 重放）

+ (void)postEvent:(NSString *)name body:(NSDictionary *)body {
    if (!name.length) {
        return;
    }
    NSDictionary *payload = @{@"name": name, @"body": body ?: @{}};
    dispatch_async(dispatch_get_main_queue(), ^{
        MFCarPlayBridge *bridge = sharedInstance;
        if (bridge && bridge.hasListeners) {
            [bridge sendCarPlayEvent:name body:payload[@"body"]];
            return;
        }
        /* RN 未就绪：去重后入队，startObserving 时重放 */
        for (NSDictionary *queued in sPendingEvents) {
            if ([queued[@"name"] isEqualToString:name] &&
                [queued[@"body"] isEqualToDictionary:(body ?: @{})]) {
                RCTLogInfo(@"[MusicFree][CarPlay] event %@ queued(dedup), pending=%lu",
                           name, (unsigned long)sPendingEvents.count);
                return;
            }
        }
        if (sPendingEvents.count >= kMFCarPlayMaxPendingEvents) {
            [sPendingEvents removeObjectAtIndex:0];
        }
        [sPendingEvents addObject:payload];
        RCTLogInfo(@"[MusicFree][CarPlay] event %@ queued (RN not ready), pending=%lu",
                   name, (unsigned long)sPendingEvents.count);
    });
}

- (void)sendCarPlayEvent:(NSString *)name body:(NSDictionary *)body {
    if (!self.hasListeners) {
        return;
    }
    if ([NSThread isMainThread]) {
        [self sendEventWithName:name body:body ?: @{}];
    } else {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf sendEventWithName:name body:body ?: @{}];
        });
    }
}

- (void)flushPendingEvents {
    if (!self.hasListeners || sPendingEvents.count == 0) {
        return;
    }
    NSArray *events = [sPendingEvents copy];
    [sPendingEvents removeAllObjects];
    for (NSDictionary *payload in events) {
        NSString *name = payload[@"name"];
        if (![self.supportedEvents containsObject:name]) {
            continue;
        }
        [self sendEventWithName:name body:payload[@"body"] ?: @{}];
        NSLog(@"[MusicFree][CarPlay] flushed event %@", name);
    }
}

+ (void)emitPlayTrack:(NSString *)trackId sheetId:(NSString *)sheetId {
    [self postEvent:@"CarPlayPlayTrack"
               body:@{@"trackId": trackId ?: @"", @"sheetId": sheetId ?: @""}];
}

+ (void)emitRequestTracks:(NSString *)sheetId {
    [self postEvent:@"CarPlayRequestTracks" body:@{@"sheetId": sheetId ?: @""}];
}

+ (void)emitControl:(NSString *)action {
    [self postEvent:@"CarPlayControl" body:@{@"action": action ?: @""}];
}

/* 兼容旧通知链：若还有别的模块直接 post kMFCarPlayEventNotification，照样转发 */
- (void)handleCarPlayEvent:(NSNotification *)note {
    NSString *name = note.userInfo[@"name"];
    NSDictionary *body = note.userInfo[@"body"];
    if (!name.length) {
        return;
    }
    if (self.hasListeners) {
        [self sendCarPlayEvent:name body:body];
    } else {
        [MFCarPlayBridge postEvent:name body:body];
    }
}

@end
