/*
 * CarPlaySceneDelegate.m — Phase 1 one-shot root（同步 XPC 隔离版）
 *
 * ============================ 三代真机日志演进 ============================
 *
 * [11142415] 死因：同一秒内对同一个 CPInterfaceController 连发 3~9 次
 *   setRootTemplate:。CarPlay 框架判定协议违规，直接 invalidate 整条连接。
 *   修复：一个 controller 生命周期内 setRootTemplate 只发一次。
 *
 * [11142515] one-shot 生效（`native placeholder root installed` 只 1 次，
 *   生命周期全是 `keep root, no reinstall`），但：
 *     - `setRootTemplate success=` 一次都没出现
 *     - watchdog 打印 `applied=0 inFlight=1` => completion 闭包从未被调用
 *     - 且 updateSections: 被 `_rootApplied` 把住，而它只由 completion 置位
 *       => completion 不回 = 永远不推内容（自锁）
 *   修复：改用 `topTemplate` 作为框架权威信号，解除 `_rootApplied` 闸门。
 *
 * [11142615] 真机日志（2026-11-15 01:55:42, iOS 16.1.1, pid 4543）抓到真凶：
 *
 *   MusicFree(CarPlay)  <Notice>: App supports CPTemplateApplicationScene
 *                                 method without window
 *   MusicFree[4543]     <Notice>: [MusicFree][CarPlay] connected (phase1)
 *                                 controller=0x2818352c0 installedFor=0x0 applied=0
 *   MusicFree[4543]     <Notice>: [MusicFree][CarPlay] data observer registered
 *   MusicFree(CarPlay)  <Error> : Connection interrupted
 *   MusicFree(CarPlay)  <Error> : Error accessing synchronous template provider
 *   MusicFree[4543]     <Notice>: [MusicFree][CarPlay] one-shot root install armed
 *   MusicFree(CarPlay)  <Notice>: Application declares audio entitlement.
 *   MusicFree(CarPlay)  <Notice>: Setting root template <private> animated 0
 *   MusicFree[4543]     <Notice>: [MusicFree][CarPlay] native placeholder root
 *                                 installed (animated=NO)
 *   MusicFree(CarPlay)  <Error> : Connection interrupted        <- 第二次
 *   MusicFree(CarPlay)  <Error> : Connection invalidated
 *   MusicFree[4543]     <Notice>: lifecycle: keep root, no reinstall
 *                                 (willEnterForeground) applied=0 confirmed=0
 *   MusicFree[4543]     <Notice>: watchdog round=1..8: applied=0 inFlight=1
 *
 *   **`Connection interrupted` 出现在 `one-shot root install armed` 之前。**
 *   即：didConnect 回调进入后，`installRootIfNeeded` 第一件事就是
 *   `if (ic.topTemplate != nil)` —— 而 `CPInterfaceController.topTemplate`
 *   是一次**同步 XPC 往返**（要向 CarPlay 服务端取当前栈顶模板）。
 *   此刻 didConnect 的握手事务尚未结算，同一线程上再发起同步 XPC：
 *     -> 框架报 `Error accessing synchronous template provider`
 *     -> 握手事务超时 -> `Connection interrupted` -> `Connection invalidated`
 *   连接一死，`topTemplate` 永远是 nil、completion 永远不回调、
 *   `updateSections:` 推给一个已死的控制器 -> 永久黑屏。
 *
 *   => 真正元凶不是重装风暴，也不是 entitlement，是**在 didConnect 内
 *      同步读取 interfaceController 的同步属性**。
 *
 * ============================ 本文件的不变量 ============================
 *   1) 一个 CPInterfaceController 生命周期内，setRootTemplate: 只发一次。
 *   2) scene 生命周期（didBecomeActive / willEnterForeground /
 *      didEnterBackground）绝不重装 root，只做诊断与内容刷新。
 *   3) watchdog 只诊断，不重装。
 *   4) **`_templateReady == NO` 期间，任何代码路径都不许读
 *      `interfaceController.topTemplate`。** 该标志由 watchdog 第一轮
 *      （didConnect 之后 1.5s）置 YES —— 那时握手已结算，同步读安全。
 *      这是 11142615 黑屏的直接修复。
 *   5) `didConnectInterfaceController:` 内只做「记录 controller + 注册
 *      observer」，root 安装与数据请求全部 dispatch_async 到下一轮
 *      runloop，让握手事务先干净结算。
 *   6) `didConnectInterfaceController:` 内**绝不读写 interfaceController 的
 *      任何同步属性**（topTemplate 就是同步 XPC 往返）。root 安装与数据请求
 *      全部 dispatch_async 到下一轮 runloop，让握手事务先干净结算。
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
- (void)attachInterfaceController:(CPInterfaceController *)interfaceController
                            scene:(CPTemplateApplicationScene *)scene;
- (void)registerDataObserverIfNeeded;
- (void)unregisterDataObserver;
- (NSArray<NSDictionary *> *)sheets;
- (NSArray<NSDictionary *> *)tracksForSheet:(NSString *)sheetId;
- (NSArray<CPListSection *> *)placeholderSections;
- (NSArray<CPListSection *> *)currentRootSections;
- (void)installRootIfNeeded;
- (BOOL)syncAppliedStateFromFramework;
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic;
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic round:(NSUInteger)round;
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
    /* 握手已结算、允许做同步 XPC 读（topTemplate）。见不变量 4。 */
    BOOL _templateReady;
    BOOL _observerOwnedByMe;
    /* 已经对哪个 controller 调用过 setRootTemplate（一个 controller 只准一次） */
    __weak CPInterfaceController *_rootInstalledFor;
    __weak CPTemplateApplicationScene *_templateScene;
}

#pragma mark - CPTemplateApplicationSceneDelegate

/*
 * 只保留不带 window 的签名 —— 11142615 日志已证明这条路径能进来
 * （`[MusicFree][CarPlay] connected (phase1)` 打印了）。
 * 框架那句 `App supports CPTemplateApplicationScene method without window`
 * 是 Notice 级的信息提示（说明走模板渲染），不是错误，不必改签名。
 * 本次唯一的实质修复是：**本回调内不再做任何同步 XPC 读**。
 */
- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didConnectInterfaceController:(CPInterfaceController *)interfaceController
{
    [self attachInterfaceController:interfaceController scene:templateApplicationScene];
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
    _templateReady = NO;
}

/*
 * didConnect 的共享实现。铁律：
 *   **函数体内绝不读写 interfaceController 的任何同步属性。**
 *   topTemplate 是同步 XPC 往返，在握手未结算时读它 = 直接打断连接。
 *   root 安装 / 数据请求全部推到下一轮 runloop。
 */
- (void)attachInterfaceController:(CPInterfaceController *)interfaceController
                            scene:(CPTemplateApplicationScene *)scene
{
    _templateScene = scene;
    self.interfaceController = interfaceController;
    sActiveDelegate = self;

    /* 新连接（controller 身份变化）：旧的一次性标记作废，允许新 controller 装一次 root */
    if (_rootInstalledFor != interfaceController) {
        _rootInstalledFor = nil;
        _rootInstallInFlight = NO;
        _rootApplied = NO;
        _templateReady = NO;
    }
    NSLog(@"[MusicFree][CarPlay] connected (phase1) controller=%p installedFor=%p applied=%d ready=%d",
          (__bridge void *)interfaceController,
          (__bridge void *)_rootInstalledFor,
          _rootApplied,
          _templateReady);

    [self registerDataObserverIfNeeded];

    /*
     * 关键修复：让 didConnect 立刻返回，握手事务干净结算。
     * 下一轮 runloop 才碰 controller（此时仍不读 topTemplate，
     * 只调异步的 setRootTemplate:）。
     */
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self || self.interfaceController != interfaceController) {
            return;
        }
        [self installRootIfNeeded];
        [self requestSheetsNow];
        [self scheduleRequestSheetsRetries];
    });
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
 * syncAppliedStateFromFramework 内部有 _templateReady 门，握手未完成时不会
 * 触碰 topTemplate。
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
        _templateReady = NO;
        [self registerDataObserverIfNeeded];
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) self = weakSelf;
            if (!self || self.interfaceController != sceneIC) {
                return;
            }
            [self installRootIfNeeded];
            [self requestSheetsNow];
        });
        return;
    }

    /* 同一 controller：绝不重装 root，但每次生命周期都向框架核对一次是否已被接受 */
    BOOL confirmed = [self syncAppliedStateFromFramework];
    NSLog(@"[MusicFree][CarPlay] lifecycle: keep root, no reinstall (%@) applied=%d confirmed=%d ready=%d",
          reason, _rootApplied, confirmed, _templateReady);
    if (confirmed) {
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

#pragma mark - Root Template（一连接只装一次 / animated:NO / 零同步读）

- (void)installRootIfNeeded {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }

    /*
     * 不变量 1：同一个 controller 只装一次。
     * 无论上次成功还是失败，都绝不再发 setRootTemplate —— 重发会打死 XPC 连接。
     * syncAppliedStateFromFramework 已含 _templateReady 门，未就绪时零同步读。
     */
    if (_rootInstalledFor == ic) {
        if ([self syncAppliedStateFromFramework]) {
            NSLog(@"[MusicFree][CarPlay] root already installed, updateSections only");
            [self refreshRootSections];
        } else {
            NSLog(@"[MusicFree][CarPlay] root already set on this controller, no retry (waiting framework)");
        }
        return;
    }

    /* 不变量 2：同一轮并发调用直接挡掉 */
    if (_rootInstallInFlight) {
        NSLog(@"[MusicFree][CarPlay] root install in flight, skip duplicate");
        return;
    }

    /*
     * 注意：这里**故意不读 ic.topTemplate**。
     * 11142615 日志证明在 didConnect 后立刻同步读 topTemplate 会让框架报
     * `Error accessing synchronous template provider` 并 `Connection interrupted`。
     * 若要接管系统已有 root，交给 watchdog（1.5s 后 _templateReady=YES）处理。
     */
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
                 if (!success) {
                     /* completion 说失败，但框架真相仍以 topTemplate 为准（需 ready） */
                     [self syncAppliedStateFromFramework];
                     return;
                 }
                 self->_rootApplied = YES;
                 if (self->_templateReady) {
                     [self refreshRootSections];
                 }
             }];
    NSLog(@"[MusicFree][CarPlay] native placeholder root installed (animated=NO)");

    [self scheduleRootWatchdogForController:ic];
}

/*
 * 框架真相核对：唯一权威信号是 interfaceController.topTemplate 是否已经
 * 是我们自己创建的 CPListTemplate 实例。
 *
 * **topTemplate 是同步 XPC 读**。11142615 真机日志证明在 didConnect 握手
 * 未结算时读它，框架会报 `Error accessing synchronous template provider`
 * 并立刻 `Connection interrupted` -> `Connection invalidated`，整条 template
 * 连接报废。因此这里加 _templateReady 硬门：未就绪一律不读、直接返回 NO。
 */
- (BOOL)syncAppliedStateFromFramework {
    if (!_templateReady) {
        return NO;
    }
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return NO;
    }
    CPTemplate *top = ic.topTemplate;
    if (_rootList && top == _rootList) {
        if (!_rootApplied) {
            NSLog(@"[MusicFree][CarPlay] framework confirms root is top (completion lost), applied=1");
        }
        _rootApplied = YES;
        _rootInstallInFlight = NO;
        return YES;
    }
    return NO;
}

/*
 * completion 可能永远不回调。watchdog 绝不重装 root（重装会打死 XPC 连接），
 * 只做两件事：
 *   a) 第一轮把 _templateReady 置 YES（didConnect 之后 1.5s，握手已结算），
 *      解锁同步读
 *   b) 之后向框架核对 topTemplate，若已是我们自己的 list -> 认定成功并推内容；
 *      未确认则按 1.5s 间隔继续核对，最多 10 次（约 15s），全程零 setRootTemplate
 * 如果 controller 身份变了（系统给了新连接），交给 didConnect / rebind 处理。
 */
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic {
    [self scheduleRootWatchdogForController:ic round:1];
}

- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic round:(NSUInteger)round {
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
        if (!self->_templateReady) {
            self->_templateReady = YES;
            NSLog(@"[MusicFree][CarPlay] watchdog round=%lu: sync probe unlocked (handshake settled)",
                  (unsigned long)round);
        }
        if ([self syncAppliedStateFromFramework]) {
            NSLog(@"[MusicFree][CarPlay] watchdog round=%lu: framework confirms root, push sections",
                  (unsigned long)round);
            [self refreshRootSections];
            return;
        }
        NSLog(@"[MusicFree][CarPlay] watchdog round=%lu: applied=0 inFlight=%d, keep polling (no reinstall)",
              (unsigned long)round, self->_rootInstallInFlight);
        if (round >= 10) {
            self->_rootInstallInFlight = NO;
            return;
        }
        [self scheduleRootWatchdogForController:ic round:(round + 1)];
    });
}

- (void)refreshRootSections {
    if (!_rootList || !_templateReady) {
        /* 握手未结算：绝不做同步读，等 watchdog 解锁后自己会再调一次 */
        return;
    }
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }
    /*
     * 判据是「框架真相」而非 completion，且必须先通过 _templateReady 门。
     * syncAppliedStateFromFramework 已包含 topTemplate == _rootList 判断。
     */
    if (![self syncAppliedStateFromFramework]) {
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
    /* 握手未结算时不碰同步属性；root 都没确认时也不 push，避免脏栈 */
    if (!_templateReady) {
        NSLog(@"[MusicFree][CarPlay] push ignored, template handshake not settled yet (sheet=%@)", sheetId);
        return;
    }
    [self syncAppliedStateFromFramework];

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
    if (!_currentSheetId || !self.interfaceController || !_templateReady) {
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
        /* refreshRootSections 自带 _templateReady 门：握手未结算就静默返回，
           watchdog 解锁后会再推一次，不会丢数据 */
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
