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

static NSString *const kMFCarPlayEventNotification = @"MFCarPlayEventNotification";
static NSString *const kMFCarPlayDataDidUpdate = @"MFCarPlayDataDidUpdate";

/* 进程级静态：RN 就绪前的车机事件不能丢 */
static NSMutableArray<NSDictionary *> *sPendingEvents = nil;
static NSUInteger const kMFCarPlayMaxPendingEvents = 50;

@interface MFCarPlayBridge ()
@property (nonatomic, strong) NSArray *sheetsData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *tracksData;
@property (nonatomic, strong) NSDictionary *nowPlayingData;
@property (atomic, assign) BOOL hasListeners;
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
        sharedInstance = self;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleCarPlayEvent:)
                                                     name:kMFCarPlayEventNotification
                                                   object:nil];
        NSLog(@"[MusicFree][CarPlay] bridge init, pending=%lu",
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
    return @[@"CarPlayPlayTrack", @"CarPlayRequestTracks", @"CarPlayControl"];
}

- (void)startObserving {
    self.hasListeners = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        NSLog(@"[MusicFree][CarPlay] bridge startObserving, flush pending=%lu",
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
        [self flushPendingEvents];
        [self postDataUpdate:@{@"kind": @"sheets"}];
    });
}

#pragma mark - JS -> 车机（数据）

RCT_EXPORT_METHOD(setSheets:(NSArray *)sheets)
{
    self.sheetsData = [sheets isKindOfClass:[NSArray class]] ? sheets : @[];
    [self postDataUpdate:@{@"kind": @"sheets"}];
}

RCT_EXPORT_METHOD(setTracks:(NSArray *)tracks forSheetId:(NSString *)sheetId)
{
    if (![sheetId isKindOfClass:[NSString class]]) {
        return;
    }
    self.tracksData[sheetId] = [tracks isKindOfClass:[NSArray class]] ? tracks : @[];
    [self postDataUpdate:@{@"kind": @"tracks", @"sheetId": sheetId}];
}

RCT_EXPORT_METHOD(setNowPlaying:(NSString *)title artist:(NSString *)artist)
{
    self.nowPlayingData = @{
        @"title": title ?: @"",
        @"artist": artist ?: @"",
    };
    [self postDataUpdate:@{@"kind": @"nowPlaying"}];
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
