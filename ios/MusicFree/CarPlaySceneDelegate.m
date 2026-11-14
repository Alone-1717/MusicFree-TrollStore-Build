/*
 * CarPlaySceneDelegate.m — Phase 1 one-shot root
 *
 * 真机日志（2026-11-15 01:01:15, iOS 16.1.1, 构建 11142415）结论：
 *
 *   [MusicFree][CarPlay] connected (phase1) controller=0x2829d5080 attempts=0 applied=0
 *   [MusicFree][CarPlay] native placeholder root installed (animated=NO) attempt=1   <- 第 1 次
 *   [MusicFree][CarPlay] root not applied yet (willEnterForeground), retry install
 *   [MusicFree][CarPlay] native placeholder root installed (animated=NO) attempt=1   <- 第 2 次
 *   [MusicFree][CarPlay] root not applied yet (didBecomeActive), retry install
 *   [MusicFree][CarPlay] native placeholder root installed (animated=NO) attempt=1   <- 第 3 次
 *   MusicFree(CarPlay) <Error>: Connection interrupted
 *   MusicFree(CarPlay) <Error>: Error accessing synchronous template provider
 *   MusicFree(CarPlay) <Error>: Connection invalidated
 *   [MusicFree][CarPlay] root watchdog fired attempt=1..6 applied=0, recover
 *   [MusicFree][CarPlay] setRootTemplate attempts exhausted, keep placeholder
 *
 * 死因：**同一秒内对同一个 CPInterfaceController 调了三~九次 setRootTemplate:**。
 *   - setRootTemplate 是异步 XPC 事务；握手还没完成就连发多个 root 变更请求，
 *     CarPlay 框架判定协议违规 -> 直接 invalidate 掉整条 template 连接。
 *   - completion 一次都没回来（日志里 `setRootTemplate success=` 完全缺失），
 *     旧代码于是认为"没生效"，在 sceneWillEnterForeground / sceneDidBecomeActive
 *     里把计数清零再装一次，watchdog 又装六次 -> 把死连接彻底打死 -> 永久黑屏。
 *   - `Error accessing synchronous template provider` 正是连接已断后框架取不到
 *     root template provider 的报错，说明画面从来没拿到过一份稳定的 root。
 *
 * 修复原则（本文件的核心不变量）：
 *   1) **一个 CPInterfaceController 生命周期内，setRootTemplate: 只允许调用一次。**
 *      以 `_rootInstalledFor` 记住已经装过 root 的 controller 身份；
 *      同一 controller 的后续任何调用一律只打日志、绝不重发。
 *   2) **scene 生命周期（didBecomeActive / willEnterForeground / didEnterBackground）
 *      绝不重装 root。** 只有 controller 对象身份真的换了（= 系统给了新连接）才装。
 *   3) watchdog 只做诊断（`watchdog diagnose`），**不再重装**。
 *      连接断了就等系统重新 didConnect，那时 controller 身份会变，才是合法重装时机。
 *   4) updateSections: 只在 `_rootApplied == YES` 之后才允许调用，
 *      绝不在握手未完成时往 root 上推内容。
 *   5) RN 数据到达后只 updateSections:，绝不重新 setRootTemplate。
 *   6) observer 进程级只注册一次；didDisconnect 配对移除并清空状态。
 *   7) 冷启动有限次重发 requestSheets，RN 就绪后自动回填。
 *
 * 只用 iOS 14+ 稳定 API（CPListItem.handler / updateSections:），规避
 * initWithText:detailText:image:accessoryType: 的 SDK 签名差异。
 */
#import "CarPlaySceneDelegate.h"
#import "CarPlayBridge.h"

static NSString *const kMFCarPlayDataDidUpdate = @"MFCarPlayDataDidUpdate";

/* 进程级幂等状态：scene 反复 activate 时不会重复注册 / 重复设 root */
static __weak CPInterfaceController *sRootedController = nil;
static __weak MFCarPlaySceneDelegate *sActiveDelegate = nil;
static id<NSObject> sDataObserverToken = nil;

@interface MFCarPlaySceneDelegate ()
- (void)registerDataObserverIfNeeded;
- (void)unregisterDataObserver;
- (NSArray<NSDictionary *> *)sheets;
- (NSArray<NSDictionary *> *)tracksForSheet:(NSString *)sheetId;
- (NSArray<CPListSection *> *)placeholderSections;
- (NSArray<CPListSection *> *)currentRootSections;
- (void)installRootIfNeeded;
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic;
- (CPInterfaceController *)interfaceControllerFromScene:(UIScene *)scene;
- (void)recoverTemplateScene:(UIScene *)scene reason:(NSString *)reason;
- (void)refreshRootSections;
- (void)pushTracksForSheet:(NSString *)sheetId title:(NSString *)title;
- (NSArray<CPListItem *> *)buildTrackItems:(NSArray<NSDictionary *> *)tracks
                                    sheetId:(NSString *)sheetId;
- (void)refreshVisibleTracks;
- (void)handleDataUpdate:(NSNotification *)note;
- (void)requestSheetsNow;
- (void)scheduleRequestSheetsRetries;
@end

@implementation MFCarPlaySceneDelegate {
    CPListTemplate *_rootList;
    NSString *_currentSheetId;
    NSString *_currentSheetTitle;
    BOOL _sheetsReceived;
    BOOL _rootInstallInFlight;
    BOOL _rootApplied;
    BOOL _observerOwnedByMe;
    /* 已经对哪个 controller 调用过 setRootTemplate（一个 controller 只准一次） */
    __weak CPInterfaceController *_rootInstalledFor;
    __weak CPTemplateApplicationScene *_templateScene;
}

#pragma mark - CPTemplateApplicationSceneDelegate

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didConnectInterfaceController:(CPInterfaceController *)interfaceController
{
    _templateScene = templateApplicationScene;
    self.interfaceController = interfaceController;
    sActiveDelegate = self;

    /* 新连接（controller 身份变化）：旧的一次性标记作废，允许新 controller 装一次 root */
    if (_rootInstalledFor != interfaceController) {
        _rootInstalledFor = nil;
        _rootInstallInFlight = NO;
        _rootApplied = NO;
    }
    NSLog(@"[MusicFree][CarPlay] connected (phase1) controller=%p installedFor=%p applied=%d",
          (__bridge void *)interfaceController,
          (__bridge void *)_rootInstalledFor,
          _rootApplied);

    [self registerDataObserverIfNeeded];

    /* 同步装原生占位 root，完全不碰 RN —— 本次连接只会走到真正 setRootTemplate 一次 */
    [self installRootIfNeeded];

    /* 冷启动 RN 未就绪：立即请求一次 + 有限次重发，就绪方自动回填 */
    [self requestSheetsNow];
    [self scheduleRequestSheetsRetries];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didDisconnectInterfaceController:(CPInterfaceController *)interfaceController
{
    NSLog(@"[MusicFree][CarPlay] disconnected controller=%p", (__bridge void *)interfaceController);
    [self unregisterDataObserver];
    if (sActiveDelegate == self) {
        sActiveDelegate = nil;
    }
    if (sRootedController == interfaceController) {
        sRootedController = nil;
    }
    if (_rootInstalledFor == interfaceController) {
        _rootInstalledFor = nil;
    }
    _templateScene = nil;
    self.interfaceController = nil;
    _rootList = nil;
    _currentSheetId = nil;
    _currentSheetTitle = nil;
    _sheetsReceived = NO;
    _rootInstallInFlight = NO;
    _rootApplied = NO;
}

#pragma mark - UIScene 生命周期（只重绑，不重装）

- (CPInterfaceController *)interfaceControllerFromScene:(UIScene *)scene {
    if (![scene isKindOfClass:[CPTemplateApplicationScene class]]) {
        return nil;
    }
    id ic = nil;
    @try {
        ic = [(CPTemplateApplicationScene *)scene valueForKey:@"interfaceController"];
    } @catch (NSException *e) {
        (void)e;
        ic = nil;
    }
    return [ic isKindOfClass:[CPInterfaceController class]] ? (CPInterfaceController *)ic : nil;
}

/*
 * 关键收敛点：scene 生命周期回调只做两件事
 *   a) controller 对象身份换了 -> 视为全新连接，重置一次性标记并装 root（合法）
 *   b) controller 身份没换 -> 什么都不装，只刷新已应用的内容
 * 绝不再因为 "_rootApplied == NO" 就重装 —— 那正是 11142415 打死连接的元凶。
 */
- (void)recoverTemplateScene:(UIScene *)scene reason:(NSString *)reason {
    if (![scene isKindOfClass:[CPTemplateApplicationScene class]]) {
        return;
    }
    _templateScene = (CPTemplateApplicationScene *)scene;

    CPInterfaceController *sceneIC = [self interfaceControllerFromScene:scene];
    CPInterfaceController *current = self.interfaceController;

    if (sceneIC && sceneIC != current) {
        NSLog(@"[MusicFree][CarPlay] rebind controller (%@) old=%p new=%p",
              reason, (__bridge void *)current, (__bridge void *)sceneIC);
        self.interfaceController = sceneIC;
        sRootedController = nil;
        _rootInstalledFor = nil;
        _rootList = nil;
        _rootInstallInFlight = NO;
        _rootApplied = NO;
        [self registerDataObserverIfNeeded];
        [self installRootIfNeeded];
        [self requestSheetsNow];
        return;
    }

    /* 同一 controller：绝不重装 root */
    NSLog(@"[MusicFree][CarPlay] lifecycle: keep root, no reinstall (%@) applied=%d",
          reason, _rootApplied);
    if (_rootApplied) {
        [self refreshRootSections];
    }
}

- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    [self recoverTemplateScene:scene reason:@"didBecomeActive"];
}

- (void)sceneWillEnterForeground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    [self recoverTemplateScene:scene reason:@"willEnterForeground"];
}

- (void)sceneDidEnterBackground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    /* 进入后台不拆 root，只记录；连接若被系统 invalidate，回前台会重新绑定 */
    NSLog(@"[MusicFree][CarPlay] scene entered background, keep root applied=%d", _rootApplied);
}

/*
 * 外观（日/夜）变化由 CPInterfaceController 内部处理模板渲染。
 * 这里刻意不实现 contentStyleDidChange 一类回调，也不做任何
 * setRootTemplate —— 日志里 light -> dark 只是渲染样式变化，不是 scene 重建。
 */

#pragma mark - Observer（进程级唯一 + disconnect 配对移除）

- (void)registerDataObserverIfNeeded {
    if (sDataObserverToken) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    sDataObserverToken = [[NSNotificationCenter defaultCenter]
        addObserverForName:kMFCarPlayDataDidUpdate
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
                    MFCarPlaySceneDelegate *delegate = sActiveDelegate ?: weakSelf;
                    [delegate handleDataUpdate:note];
                }];
    _observerOwnedByMe = YES;
    NSLog(@"[MusicFree][CarPlay] data observer registered");
}

- (void)unregisterDataObserver {
    if (!sDataObserverToken) {
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:sDataObserverToken];
    sDataObserverToken = nil;
    _observerOwnedByMe = NO;
    NSLog(@"[MusicFree][CarPlay] data observer removed");
}

#pragma mark - 数据读取（RN 可为空，绝不阻塞首屏）

- (NSArray<NSDictionary *> *)sheets {
    MFCarPlayBridge *bridge = [MFCarPlayBridge shared];
    NSArray *s = [bridge sheets];
    return [s isKindOfClass:[NSArray class]] ? s : @[];
}

- (NSArray<NSDictionary *> *)tracksForSheet:(NSString *)sheetId {
    if (!sheetId.length) {
        return @[];
    }
    MFCarPlayBridge *bridge = [MFCarPlayBridge shared];
    NSArray *t = [bridge tracksForSheetId:sheetId];
    return [t isKindOfClass:[NSArray class]] ? t : @[];
}

#pragma mark - 首屏占位 / 真实 sections

- (NSArray<CPListSection *> *)placeholderSections {
    CPListItem *item = [[CPListItem alloc] initWithText:@"正在加载歌单…"
                                              detailText:@"请稍候，或在手机上打开一次 MusicFree"];
    __weak __typeof(self) weakSelf = self;
    item.handler = ^(CPListItem * _Nonnull selectedItem, dispatch_block_t completion) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (self) {
            [self requestSheetsNow];
        }
        completion();
    };
    return @[[[CPListSection alloc] initWithItems:@[item]]];
}

- (NSArray<CPListSection *> *)currentRootSections {
    NSArray *sheetItems = [self sheets];
    if (sheetItems.count == 0) {
        /* RN 已经回过数据但仍为空 -> 显示真实空态；否则保持加载占位 */
        return _sheetsReceived ? @[[[CPListSection alloc] initWithItems:@[
            [[CPListItem alloc] initWithText:@"暂无歌单"
                                  detailText:@"请在手机 App 中导入或创建歌单"]
        ]]] : [self placeholderSections];
    }

    NSMutableArray<CPListItem *> *items = [NSMutableArray array];
    __weak __typeof(self) weakSelf = self;
    for (NSDictionary *s in sheetItems) {
        NSString *sid = [s[@"id"] isKindOfClass:[NSString class]] ? s[@"id"] : @"";
        NSString *title = [s[@"title"] isKindOfClass:[NSString class]] ? s[@"title"] : @"未命名歌单";
        id count = s[@"count"];
        NSString *detail = [count isKindOfClass:[NSNumber class]]
            ? [NSString stringWithFormat:@"%@ 首", count]
            : @"";
        CPListItem *item = [[CPListItem alloc] initWithText:title detailText:detail];
        item.accessoryType = CPListItemAccessoryTypeDisclosureIndicator;
        item.handler = ^(CPListItem * _Nonnull selectedItem, dispatch_block_t completion) {
            __strong __typeof(weakSelf) self = weakSelf;
            if (self) {
                [self pushTracksForSheet:sid title:title];
            }
            completion();
        };
        [items addObject:item];
    }
    return @[[[CPListSection alloc] initWithItems:items]];
}

#pragma mark - Root Template（一连接只装一次 / completion / animated:NO）

- (void)installRootIfNeeded {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }

    /*
     * 不变量 1：同一个 controller 只装一次。
     * 无论上次成功还是失败，都绝不再发 setRootTemplate —— 重发会直接打死 XPC 连接。
     */
    if (_rootInstalledFor == ic) {
        if (_rootApplied) {
            NSLog(@"[MusicFree][CarPlay] root already installed, updateSections only");
            [self refreshRootSections];
        } else {
            NSLog(@"[MusicFree][CarPlay] root already set on this controller, no retry (waiting framework)");
        }
        return;
    }

    /* 不变量 2：同一轮并发调用直接挡掉，不做时间窗"retry anyway" */
    if (_rootInstallInFlight) {
        NSLog(@"[MusicFree][CarPlay] root install in flight, skip duplicate");
        return;
    }

    /* 框架侧已经有 root（例如系统恢复）：直接接管它，绝不再 setRootTemplate */
    if (ic.topTemplate != nil) {
        NSLog(@"[MusicFree][CarPlay] framework already has topTemplate=%p, adopt without setRootTemplate",
              (__bridge void *)ic.topTemplate);
        _rootInstalledFor = ic;
        sRootedController = ic;
        _rootInstallInFlight = NO;
        _rootApplied = YES;
        /* 接管成 _rootList，这样后面能靠 updateSections: 填内容，不用重建导航 */
        if ([ic.topTemplate isKindOfClass:[CPListTemplate class]]) {
            _rootList = (CPListTemplate *)ic.topTemplate;
            [self refreshRootSections];
        }
        return;
    }

    _rootInstalledFor = ic;
    sRootedController = ic;
    _rootInstallInFlight = YES;
    NSLog(@"[MusicFree][CarPlay] one-shot root install armed controller=%p",
          (__bridge void *)ic);

    CPListTemplate *list = [[CPListTemplate alloc] initWithTitle:@"音乐"
                                                        sections:[self placeholderSections]];
    _rootList = list;

    __weak __typeof(self) weakSelf = self;
    [ic setRootTemplate:list
               animated:NO
             completion:^(BOOL success, NSError * _Nullable error) {
                 __strong __typeof(weakSelf) self = weakSelf;
                 if (!self) {
                     return;
                 }
                 NSLog(@"[MusicFree][CarPlay] setRootTemplate success=%d error=%@",
                       success, error.localizedDescription);
                 self->_rootInstallInFlight = NO;
                 self->_rootApplied = success;
                 if (!success) {
                     /* 失败也不再重发：等系统重新 didConnect（controller 身份会变） */
                     NSLog(@"[MusicFree][CarPlay] root rejected, will wait for a fresh connection");
                     return;
                 }
                 [self refreshRootSections];
             }];
    NSLog(@"[MusicFree][CarPlay] native placeholder root installed (animated=NO)");

    [self scheduleRootWatchdogForController:ic];
}

/*
 * completion 在连接被打断时可能永远不回调。
 * watchdog 现在**只做诊断**，绝不重装 root —— 重装正是打死连接的原因。
 * 如果 controller 身份已经变了（系统给了新连接），交给 didConnect / rebind 处理。
 */
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        if (self.interfaceController != ic) {
            return;
        }
        NSLog(@"[MusicFree][CarPlay] watchdog diagnose: applied=%d inFlight=%d (no reinstall)",
              self->_rootApplied, self->_rootInstallInFlight);
        if (self->_rootApplied) {
            return;
        }
        /* 连接确实断了：只清 in-flight，让下次 didConnect（新 controller）走合法路径 */
        self->_rootInstallInFlight = NO;
    });
}

- (void)refreshRootSections {
    if (!_rootList) {
        return;
    }
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }
    /* 握手未完成时绝不 updateSections：那会在连接上再压一个事务 */
    if (!_rootApplied) {
        return;
    }
    /* 用户已经进入歌单子页：不要改动 root，避免打断导航 */
    if (ic.topTemplate && ic.topTemplate != _rootList) {
        return;
    }
    NSArray<CPListSection *> *sections = [self currentRootSections];
    [_rootList updateSections:sections];
    NSLog(@"[MusicFree][CarPlay] updateSections root sections=%lu sheetsReceived=%d",
          (unsigned long)sections.count, _sheetsReceived);
}

#pragma mark - 歌单子页

- (void)pushTracksForSheet:(NSString *)sheetId title:(NSString *)title {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic || !_rootApplied) {
        return;
    }
    /* 同一个歌单已在栈顶：只请求刷新，不重复 push */
    if ([_currentSheetId isEqualToString:sheetId] && ic.topTemplate &&
        ic.topTemplate != _rootList) {
        [MFCarPlayBridge emitRequestTracks:sheetId];
        return;
    }

    _currentSheetId = sheetId;
    _currentSheetTitle = title;
    NSArray *tracks = [self tracksForSheet:sheetId];
    NSArray<CPListItem *> *items;
    if (tracks.count == 0) {
        items = @[[[CPListItem alloc] initWithText:@"加载中…" detailText:@""]];
    } else {
        items = [self buildTrackItems:tracks sheetId:sheetId];
    }
    CPListTemplate *tl = [[CPListTemplate alloc] initWithTitle:title ?: @"歌单"
                                                      sections:@[[[CPListSection alloc] initWithItems:items]]];
    [ic pushTemplate:tl animated:YES completion:nil];
    [MFCarPlayBridge emitRequestTracks:sheetId];

    /* JS 慢就绪兜底：3 秒后再要一次，不重建模板 */
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self || ![self->_currentSheetId isEqualToString:sheetId]) {
            return;
        }
        [MFCarPlayBridge emitRequestTracks:sheetId];
    });
}

- (NSArray<CPListItem *> *)buildTrackItems:(NSArray<NSDictionary *> *)tracks
                                    sheetId:(NSString *)sheetId
{
    NSMutableArray<CPListItem *> *items = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        NSString *tid = [t[@"id"] isKindOfClass:[NSString class]] ? t[@"id"] : @"";
        NSString *tname = [t[@"title"] isKindOfClass:[NSString class]] ? t[@"title"] : @"未知歌曲";
        NSString *artist = [t[@"artist"] isKindOfClass:[NSString class]] ? t[@"artist"] : @"";
        CPListItem *item = [[CPListItem alloc] initWithText:tname detailText:artist];
        __weak __typeof(self) weakSelf = self;
        item.handler = ^(CPListItem * _Nonnull selectedItem, dispatch_block_t completion) {
            __strong __typeof(weakSelf) self = weakSelf;
            if (self) {
                NSLog(@"[MusicFree][CarPlay] play track %@ in sheet %@", tid, sheetId);
                [MFCarPlayBridge emitPlayTrack:tid sheetId:sheetId];
            }
            completion();
        };
        [items addObject:item];
    }
    return items;
}

- (void)refreshVisibleTracks {
    if (!_currentSheetId || !self.interfaceController || !_rootApplied) {
        return;
    }
    CPTemplate *top = self.interfaceController.topTemplate;
    if (![top isKindOfClass:[CPListTemplate class]] || top == _rootList) {
        return;
    }
    NSArray *tracks = [self tracksForSheet:_currentSheetId];
    NSArray<CPListItem *> *items = [self buildTrackItems:tracks sheetId:_currentSheetId];
    if (items.count == 0) {
        items = @[[[CPListItem alloc] initWithText:@"暂无歌曲" detailText:@""]];
    }
    [(CPListTemplate *)top updateSections:@[[[CPListSection alloc] initWithItems:items]]];
    NSLog(@"[MusicFree][CarPlay] updateSections tracks=%lu sheet=%@",
          (unsigned long)items.count, _currentSheetId);
}

#pragma mark - 数据更新通知（只更新内容，不重建 root）

- (void)handleDataUpdate:(NSNotification *)note {
    NSString *kind = note.userInfo[@"kind"];
    NSString *sheetId = note.userInfo[@"sheetId"];
    if ([kind isEqualToString:@"sheets"]) {
        _sheetsReceived = YES;
        [self refreshRootSections];
    } else if ([kind isEqualToString:@"tracks"]) {
        if (!sheetId || [sheetId isEqualToString:_currentSheetId]) {
            [self refreshVisibleTracks];
        }
    } else if ([kind isEqualToString:@"nowPlaying"]) {
        /* Phase 1 不重建任何模板，仅留日志，NowPlaying 由系统 MediaRemote 提供 */
        NSLog(@"[MusicFree][CarPlay] nowPlaying updated");
    }
}

#pragma mark - 冷启动 requestSheets 重发

- (void)requestSheetsNow {
    NSLog(@"[MusicFree][CarPlay] requestSheets");
    [MFCarPlayBridge emitControl:@"requestSheets"];
}

- (void)scheduleRequestSheetsRetries {
    __weak __typeof(self) weakSelf = self;
    for (NSUInteger i = 1; i <= 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) self = weakSelf;
            if (!self || self->_sheetsReceived || !self.interfaceController) {
                return;
            }
            NSLog(@"[MusicFree][CarPlay] requestSheets retry %lu", (unsigned long)i);
            [MFCarPlayBridge emitControl:@"requestSheets"];
        });
    }
}

@end
