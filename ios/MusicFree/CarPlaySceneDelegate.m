/*
 * CarPlaySceneDelegate.m — Phase 1 stable
 *
 * 真机日志（2026-11-14 22:26~22:28, iOS 16.1.1）结论：
 *   - 车机图标能出、[MusicFree][CarPlay] connected (phase1) 能打印
 *   - 但同一进程内 `Template scene content style updated to light/dark`
 *     伴随 scene 反复 Logical Activate / Deactivate，didConnect 被多次调用
 *   - 全程没有 `[MusicFree][CarPlay] disconnected`
 *     => didDisconnectInterfaceController: 在震荡中并不可靠
 *   - 每次 didConnect 都 addObserver + setRootTemplate(animated:YES)
 *     => observer 累积、root template 被并发重建
 *   - 紧接着 MusicFree(CarPlay) <Error>: Connection interrupted / invalidated
 *     => 车机拿不到稳定模板 = 黑屏
 *   - 车机以 `intent background` 冷启动 App，RN bundle 未就绪，
 *     旧实现首屏直接读 [MFCarPlayBridge shared] -> nil -> 空数据模板
 *
 * 修复原则：
 *   1) 首屏 100% 原生占位模板，同步构建，不查任何 RN 单例
 *   2) setRootTemplate 按 CPInterfaceController 身份做进程级幂等
 *      （弱引用，controller 释放/换新时自动允许重设一次）
 *   3) 首次 animated:NO + 带 completion 闭包（无 completion 时 presentation
 *      失败会抛异常，本身就会打断 XPC 连接）
 *   4) RN 数据到达后只 updateSections:，绝不重新 setRootTemplate
 *   5) observer 进程级只注册一次；didDisconnect 配对移除并清空状态
 *   6) 外观日/夜切换由 CPInterfaceController 自己渲染，不重建任何模板
 *   7) 冷启动有限次重发 requestSheets，RN 就绪后自动回填
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
    NSUInteger _setRootAttempts;
    BOOL _rootInstallInFlight;
    BOOL _rootApplied;
    BOOL _observerOwnedByMe;
    CFTimeInterval _lastRootInstallAt;
    __weak CPTemplateApplicationScene *_templateScene;
}

#pragma mark - CPTemplateApplicationSceneDelegate

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didConnectInterfaceController:(CPInterfaceController *)interfaceController
{
    _templateScene = templateApplicationScene;
    self.interfaceController = interfaceController;
    sActiveDelegate = self;

    /* 新 controller 到来：旧的成功标记作废，允许重新安装 root */
    if (sRootedController != interfaceController) {
        _rootApplied = NO;
        _rootInstallInFlight = NO;
        _setRootAttempts = 0;
    }
    NSLog(@"[MusicFree][CarPlay] connected (phase1) controller=%p attempts=%lu applied=%d",
          (__bridge void *)interfaceController, (unsigned long)_setRootAttempts, _rootApplied);

    [self registerDataObserverIfNeeded];

    /* 同步装原生占位 root，完全不碰 RN */
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
    _templateScene = nil;
    self.interfaceController = nil;
    _rootList = nil;
    _currentSheetId = nil;
    _currentSheetTitle = nil;
    _sheetsReceived = NO;
    _setRootAttempts = 0;
    _rootInstallInFlight = NO;
    _rootApplied = NO;
}

#pragma mark - UIScene 生命周期自愈
/*
 * 真机日志（11142315）证明：
 *   setRootTemplate(animated:NO) 调用后立刻
 *   `CarPlay <Error>: Connection interrupted` / `Connection invalidated`
 *   而 `setRootTemplate success=...` 的 completion 从未回来。
 * 原实现把 _rootInstallInFlight 永远置 YES，后续 didConnect 全被
 * "in flight, skip" 挡掉 => 车机永久黑屏。
 *
 * 这里做两层兜底：
 *   1) installRoot 时挂 watchdog，1.2s 内没拿到 success 就判失败并允许重装
 *   2) scene 每次 becomeActive / willEnterForeground，从 CPTemplateApplicationScene
 *      重新取 interfaceController（连接被 invalidate 后系统会给新的），
 *      controller 身份变了就重置状态并重装 root
 */
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
        _rootList = nil;
        _rootInstallInFlight = NO;
        _rootApplied = NO;
        _setRootAttempts = 0;
        [self registerDataObserverIfNeeded];
        [self installRootIfNeeded];
        [self requestSheetsNow];
        return;
    }

    if (!_rootApplied) {
        NSLog(@"[MusicFree][CarPlay] root not applied yet (%@), retry install", reason);
        _rootInstallInFlight = NO;
        sRootedController = nil;
        /* scene 重新激活说明用户/车机又回到这个界面：重置预算，允许继续自愈 */
        _setRootAttempts = 0;
        [self installRootIfNeeded];
    } else {
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

#pragma mark - Root Template（幂等 / completion / animated:NO）

- (void)installRootIfNeeded {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }

    /* 同一个 controller 已经成功装过 root：只刷新内容，绝不重设导航层级 */
    if (sRootedController == ic && _rootApplied && _rootList && ic.topTemplate) {
        NSLog(@"[MusicFree][CarPlay] root already installed, updateSections only");
        [self refreshRootSections];
        return;
    }

    /*
     * 关键修复：in-flight 只挡「同一轮」的并发调用，绝不永久锁死。
     * 11142315 真机日志里 completion 因为 Connection interrupted 根本没回来，
     * 旧代码在这里 return 之后再无任何重试机会 => 永久黑屏。
     * 现在 in-flight 时直接放行重装（setRootTemplate 本身幂等，
     * 重复设置同一个 template 不会崩）。
     */
    if (_rootInstallInFlight) {
        /* 同一轮 0.6s 内的重复调用才真正跳过，避免 setRootTemplate 风暴；
           超过 0.6s 说明 completion 大概率丢了，必须放行重装。 */
        CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - _lastRootInstallAt;
        if (elapsed < 0.6) {
            NSLog(@"[MusicFree][CarPlay] root install in flight %.2fs, skip", elapsed);
            return;
        }
        NSLog(@"[MusicFree][CarPlay] root install in flight %.2fs, retry anyway", elapsed);
    }

    if (_setRootAttempts >= 6) {
        NSLog(@"[MusicFree][CarPlay] setRootTemplate attempts exhausted, keep placeholder");
        return;
    }
    _setRootAttempts += 1;
    _rootInstallInFlight = YES;
    _lastRootInstallAt = CFAbsoluteTimeGetCurrent();

    CPListTemplate *list = [[CPListTemplate alloc] initWithTitle:@"音乐"
                                                        sections:[self placeholderSections]];
    _rootList = list;
    sRootedController = ic;

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
                 if (!success) {
                     self->_rootApplied = NO;
                     sRootedController = nil;
                     return;
                 }
                 self->_rootApplied = YES;
                 [self refreshRootSections];
             }];
    NSLog(@"[MusicFree][CarPlay] native placeholder root installed (animated=NO) attempt=%lu",
          (unsigned long)_setRootAttempts);

    [self scheduleRootWatchdogForController:ic];
}

/* completion 在连接被打断时可能永远不回调：1.2s 后自检，失败就允许重装 */
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic {
    __weak __typeof(self) weakSelf = self;
    NSUInteger attempt = _setRootAttempts;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        if (self->_rootApplied) {
            return;
        }
        if (self.interfaceController != ic) {
            return;
        }
        NSLog(@"[MusicFree][CarPlay] root watchdog fired attempt=%lu applied=0, recover",
              (unsigned long)attempt);
        self->_rootInstallInFlight = NO;
        sRootedController = nil;

        /* 优先从 template scene 取新 controller（连接被 invalidate 后系统会换） */
        UIScene *scene = self->_templateScene;
        CPInterfaceController *fresh = scene ? [self interfaceControllerFromScene:scene] : nil;
        if (fresh && fresh != ic) {
            self.interfaceController = fresh;
            self->_setRootAttempts = 0;
            NSLog(@"[MusicFree][CarPlay] watchdog rebound to fresh controller=%p",
                  (__bridge void *)fresh);
        }
        [self installRootIfNeeded];
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
    if (!ic) {
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
    if (!_currentSheetId || !self.interfaceController) {
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
