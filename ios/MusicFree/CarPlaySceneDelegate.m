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
 *   3) watchdog 是**受限恢复**：首发 1 次 + 最多 2 次 rearm = 全生命周期
 *      最多 3 次 setRootTemplate。绝不回到 11142415 的 9 次风暴。
 *   4) **`_templateReady == NO` 期间，任何代码路径都不许读
 *      `interfaceController.topTemplate`。** 该标志由 watchdog 第一轮
 *      （didConnect 之后 1.5s）置 YES —— 那时握手已结算，同步读安全。
 *      这是 11142615 黑屏的直接修复。
 *   5) `didConnectInterfaceController:` 内**绝不读写 interfaceController 的
 *      任何同步属性**。root 安装与数据请求全部 dispatch_async 到下一轮
 *      runloop，让握手事务先干净结算。
 *   6) `@try` 只挡「向 stale controller 调用瞬间同步抛异常」导致闪退，
 *      **保护不了 completion 永远不回** —— 后者由 watchdog 的 3s
 *      静默失败判定负责。两者职责不同，不可互替。
 *   7) 每次 setRootTemplate 带 generation token；晚到的旧 completion
 *      整包丢弃，不许覆盖当前状态（防"rearm 成功后被首发迟到回调打回"）。
 *   8) rearm 用**全新 CPListTemplate**，成功后必须重新推一次 sections，
 *      否则车机上是空列表（不黑屏但没内容）。
 *
 * 只用 iOS 14+ 稳定 API（CPListItem.handler / updateSections:），规避
 * initWithText:detailText:image:accessoryType: 的 SDK 签名差异。
 */
#import "CarPlaySceneDelegate.h"
#import "CarPlayBridge.h"
#import "MFCarPlayLog.h"
#import "MFCarPlayNativeData.h"

static NSString *const kMFCarPlayDataDidUpdate = @"MFCarPlayDataDidUpdate";

/*
 * 受限 rearm 的硬边界（见文件头不变量 7）：
 *   kMFMaxRearm            一个连接生命周期内最多 rearm 2 次
 *   kMFInstallSettleWindow setRootTemplate 之后给它 3s 回传窗口
 *   kMFWatchdogTick        watchdog 步进
 *   kMFWatchdogRounds      总轮数上限
 *
 * ⚠ 实际最早 rearm 时刻是 **4.5s**，不是 3s：
 *   tick 是 1.5s，round 1（t=1.5s）时距首发仅 1.5s -> timedOut=NO -> initialSettling；
 *   round 2（t=3.0s）边界值仍可能判 NO；
 *   round 3（t=4.5s）才必然 timedOut=YES 并发出 rearm #1。
 *   所以看日志时不要拿 3s 去对时间，也**不要为了"凑 3s"去调小 tick** ——
 *   tick 越小，同步读 topTemplate 越早，越容易重踩 11142615 的握手打断。
 */
static const NSUInteger kMFMaxRearm = 2;
static const NSTimeInterval kMFInstallSettleWindow = 3.0;
static const NSTimeInterval kMFWatchdogTick = 1.5;
static const NSUInteger kMFWatchdogRounds = 12;

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
- (void)installRootIfNeededAllowRearm:(BOOL)allowRearm;
- (BOOL)dispatchRootTemplate:(CPListTemplate *)list;
- (void)recordRootInstallTimestamp;
- (BOOL)rootInstallTimedOut;
- (BOOL)syncAppliedStateFromFramework;
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic;
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic round:(NSUInteger)round;
- (CPInterfaceController *)interfaceControllerFromScene:(UIScene *)scene;
- (void)recoverTemplateScene:(UIScene *)scene reason:(NSString *)reason;
- (void)refreshRootSections;
- (void)applySectionsToRootTemplate:(NSArray<CPListSection *> *)sections;
- (NSString *)sectionsFingerprint:(NSArray<CPListSection *> *)sections;
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
    /*
     * 受限 rearm 状态（见 watchdog 规格）：
     *   _rearmCount   已发出的 rearm 次数，上限 kMFMaxRearm
     *   _rearmPending 当前有一次 rearm 正在等结果（用于 3s 静默失败判定）
     *   _lastInstallAt 上一次 setRootTemplate 的调用时刻（timeIntervalSinceReferenceDate）
     */
    NSUInteger _rearmCount;
    BOOL _rearmPending;
    NSTimeInterval _lastInstallAt;
    BOOL _rootExhausted;
    /*
     * 每次 setRootTemplate 递增；completion 闭包捕获当时值，
     * 回来时 != 当前值 -> 丢弃（防晚到回调打乱状态）。
     */
    NSUInteger _rootGeneration;
    /*
     * didDisconnect 后置 YES：此时向 controller 发任何 XPC 都注定无效，
     * rearm 直接 exhausted，不浪费次数。
     */
    BOOL _controllerInvalidated;
    BOOL _observerOwnedByMe;
    /* 是否已记录过"数据来自原生"（避免刷屏） */
    BOOL _nativeSheetsUsed;
    /* 数据准备日志只打一次详情，之后精简 */
    BOOL _nativeDataLogged;
    /* 缓存最近一次准备好的 sections，供 root 被接受后补推 */
    NSArray<CPListSection *> *_lastSections;
    /* 上一次真正推送给 updateSections: 的内容指纹，用于去重防闪烁 */
    NSString *_lastPushedFingerprint;
    /* 已经对哪个 controller 调用过 setRootTemplate（一个 controller 只准一次） */
    __weak CPInterfaceController *_rootInstalledFor;
    /* 已经给哪个 controller 注册过 delegate（一个 controller 只注册一次） */
    __weak CPInterfaceController *_delegateRegisteredFor;
    __weak CPTemplateApplicationScene *_templateScene;
}

#pragma mark - CPTemplateApplicationSceneDelegate

/*
 * 音频 App 只实现这一个（模板路径）。
 *
 * 为什么不实现 didConnectInterfaceController:toWindow:：
 *   那个方法属于**导航类 App**。本项目 entitlement 只有 carplay-audio，
 *   系统按模板路径分配场景，永远不会给 CPWindow。
 *
 *   之前实现它、持有它、还想挂 rootViewController —— 全是死代码，
 *   而且引入过两个真实错误：
 *     - 把 CPTemplateApplicationScene 强转成 UIWindowScene（未定义行为）
 *     - 想给 window.rootViewController 赋 CPInterfaceController（类型不兼容，
 *       CPInterfaceController 是 NSObject 不是 UIViewController）
 *   现在彻底移除，少一类状态就少一类黑屏原因。
 *
 * 真机日志里的
 *     "App supports CPTemplateApplicationScene method without window"
 * 是框架陈述**正常状态**，不是缺 window。
 */
- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didConnectInterfaceController:(CPInterfaceController *)interfaceController
{
    MFCarPlayLogBoth(@"didConnect ctrl=%p (template-only audio path)",
          (__bridge void *)interfaceController);
    [self attachInterfaceController:interfaceController scene:templateApplicationScene];
}

#pragma mark - CPInterfaceControllerDelegate（模板真的上屏的唯一权威信号）

/*
 * 本轮最关键的新增。
 *
 * 之前判断"root 是否被接受"只有两条不稳的路：
 *   A) setRootTemplate 的 completion —— 实测从不回调
 *   B) 轮询 topTemplate           —— 依赖 1.5s 后的同步读，且会抖动
 *
 * templateDidAppear:animated: 是框架在模板**真的显示出来**时主动调的。
 * 它一旦触发，就说明：
 *   - 模板提交被框架接受
 *   - 模板类型（CPListTemplate）符合音频 App 要求
 *   - entitlement 配置正确
 * 所以它是最强的成功判据，收到即置 _rootApplied 并立刻推内容。
 */
- (void)templateDidAppear:(CPTemplate *)template animated:(BOOL)animated
{
    /*
     * 用 isKindOfClass 而不是指针相等。
     *
     * 原因：rearm 时 installRootIfNeededAllowRearm: 会**新建** CPListTemplate
     * 并赋给 _rootList（L678）。如果首发模板的 didAppear 在 rearm 之后才到，
     * template == _rootList 就不成立了，会漏掉这个权威信号。
     *
     * 判据放宽为"任何 CPListTemplate 上屏"——对音频 App 来说，出现在这个
     * delegate 回调里的 CPListTemplate 只可能是我们自己提交的根模板
     * （子页由 pushTemplate 推入，上屏时也是 CPListTemplate，但此时
     * _rootApplied 早已为 1，重复置位无害）。
     */
    BOOL isList = [template isKindOfClass:[CPListTemplate class]];
    BOOL isSameObject = (template == (CPTemplate *)_rootList);
    MFCarPlayLogBoth(@"templateDidAppear template=%p isList=%d sameAsRoot=%d animated=%d applied=%d",
          (__bridge void *)template, isList, isSameObject, animated, _rootApplied);

    if (isList) {
        BOOL wasApplied = _rootApplied;
        _rootApplied = YES;
        _rootInstallInFlight = NO;
        _rearmPending = NO;
        _templateReady = YES;
        if (!wasApplied) {
            MFCarPlayLogBoth(@"ROOT TEMPLATE VISIBLE -> applied=1, push content now");
            [self refreshRootSections];
        } else {
            MFCarPlayLogBoth(@"template appeared again, already applied (no re-push)");
        }
    }
}

- (void)templateWillDisappear:(CPTemplate *)template animated:(BOOL)animated
{
    if ([template isKindOfClass:[CPListTemplate class]] && template == (CPTemplate *)_rootList) {
        MFCarPlayLogBoth(@"templateWillDisappear: root");
    }
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didDisconnectInterfaceController:(CPInterfaceController *)interfaceController
{
    MFCarPlayLogBoth(@"disconnected controller=%p", (__bridge void *)interfaceController);
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
    /* 解注册 delegate，避免框架持有已失效的回调目标 */
    if (_delegateRegisteredFor == interfaceController) {
        @try {
            if (interfaceController.delegate == self) {
                interfaceController.delegate = nil;
            }
        } @catch (NSException *e) {
            MFCarPlayLogBoth(@"clear delegate threw: %@", e.reason);
        }
        _delegateRegisteredFor = nil;
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
    _rearmCount = 0;
    _rearmPending = NO;
    _rootExhausted = NO;
    _lastInstallAt = 0;
    _rootGeneration += 1;      /* 作废所有在途 completion */
    _controllerInvalidated = YES;
}

/*
 * didConnect 的共享实现。铁律：
 *   **函数体内绝不读写 interfaceController 的任何同步属性。**
 *   topTemplate 是同步 XPC 往返，在握手未结算时读它 = 直接打断连接。
 *   root 安装 / 数据请求全部推到下一轮 runloop。
 *
 * 注意：成员变量一律用**参数传入的 interfaceController** 覆盖，
 * 绝不沿用上一次连接的旧 controller（旧的可能已被 invalidate）。
 */
- (void)attachInterfaceController:(CPInterfaceController *)interfaceController
                            scene:(CPTemplateApplicationScene *)scene
{
    _templateScene = scene;
    CPInterfaceController *previous = self.interfaceController;
    self.interfaceController = interfaceController;
    sActiveDelegate = self;

    /*
     * 显式打印新旧地址，用于确认「每次 didConnect 都换成传入的新 controller」。
     * 11142615 日志里两次都打印同一个地址 0x2818352c0，需要能在新日志中直接判定
     * 是系统复用同一对象（same=1），还是没覆盖（此时新旧应不同却没换）。
     */
    MFCarPlayLogBoth(@"didConnect ctrl new=%p old=%p same=%d",
          (__bridge void *)interfaceController,
          (__bridge void *)previous,
          (previous == interfaceController));

    /*
     * didConnect 是「连接有效」的最高权威信号：**无条件**把 controller 视为有效。
     *
     * 这一行绝不能放进下面的 if (_rootInstalledFor != controller) 里。
     * 因为系统重连时可能复用同一个 CPInterfaceController 对象（日志里出现过
     * 两次 connected 打印同一地址 0x2818352c0）；那种情况下 if 进不去，
     * _controllerInvalidated 会残留 YES，watchdog 3a 分支随即判死，
     * 连一次 setRootTemplate 都不发 —— 比黑屏更难排查。
     * 所以：didDisconnect 置 YES，didConnect 无条件置 NO，两者严格配对。
     */
    _controllerInvalidated = NO;

    /*
     * 注册 CPInterfaceControllerDelegate。
     * templateDidAppear:animated: 是"模板真的上屏"的唯一权威信号，
     * 用来替代不可靠的 completion 回调和 topTemplate 轮询。
     * 每个 controller 只注册一次；身份变了要重新注册。
     */
    if (_delegateRegisteredFor != interfaceController) {
        _delegateRegisteredFor = interfaceController;
        interfaceController.delegate = self;
        MFCarPlayLogBoth(@"CPInterfaceControllerDelegate registered on ctrl=%p",
              (__bridge void *)interfaceController);
    }

    /* 新连接（controller 身份变化）：旧的一次性标记全部作废 */
    if (_rootInstalledFor != interfaceController) {
        _rootInstalledFor = nil;
        _rootInstallInFlight = NO;
        _rootApplied = NO;
        _templateReady = NO;
        _rearmCount = 0;
        _rearmPending = NO;
        _rootExhausted = NO;
        _lastInstallAt = 0;
        _rootGeneration += 1;          /* 作废旧 controller 的在途 completion */
    }
    MFCarPlayLogBoth(@"connected (phase1) controller=%p installedFor=%p applied=%d ready=%d",
          (__bridge void *)interfaceController,
          (__bridge void *)_rootInstalledFor,
          _rootApplied,
          _templateReady);

    [self registerDataObserverIfNeeded];

    /*
     * ==================== 关键修复（11142619 之后） ====================
     *
     * 之前的错误：这里用 dispatch_async 把 installRootIfNeeded 推到下一轮
     * runloop，理由是"让握手先结算"。这个判断是错的，日志给出了反证：
     *
     *   [MusicFree][CarPlay] data observer registered        <- didConnect 最后一句
     *   <Error> Connection interrupted                       <- 框架放弃
     *   <Error> Error accessing synchronous template provider <- 框架取不到模板
     *   [MusicFree][CarPlay] one-shot root install armed     <- 我的 async 才刚跑
     *
     * 即：框架在 didConnect 返回后**立刻同步来要 root template**。
     * 我把它推迟到下一轮 runloop，框架等不到，于是判超时并 invalidate 连接。
     * `Error accessing synchronous template provider` 就是"同步取模板失败"。
     *
     * 正确做法（也是 CarPlay 官方行为）：
     *   **必须在 didConnect 返回前、同步调用 setRootTemplate:。**
     *   该调用本身是异步的（带 completion），不会阻塞握手；
     *   但"发起"这个动作必须发生在 didConnect 内。
     *
     * 同时保持原有的两条铁律：
     *   1) 不读任何同步属性（topTemplate / rootTemplate）——那才是 11142615 的真凶
     *   2) 一个 controller 只发一次 setRootTemplate
     * ==================================================================
     */
    [self installRootIfNeeded];

    /*
     * 独立触发一次"数据准备"，不等 completion。
     *
     * 这么做有两个目的（对应评审意见）：
     *   1) 让 [native-data] 日志立刻出现 —— 数据层可独立验证，
     *      不被 setRootTemplate 的状态挡住。
     *   2) 把 sections 缓存进 _lastSections，等 root 真被接受时能直接补推。
     */
    [self refreshRootSections];

    [self requestSheetsNow];
    [self scheduleRequestSheetsRetries];
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
        MFCarPlayLogBoth(@"rebind controller (%@) old=%p new=%p",
              reason, (__bridge void *)current, (__bridge void *)sceneIC);
        self.interfaceController = sceneIC;
        sRootedController = nil;
        _rootInstalledFor = nil;
        _rootList = nil;
        _rootInstallInFlight = NO;
        _rootApplied = NO;
        _templateReady = NO;
        _rearmCount = 0;
        _rearmPending = NO;
        _rootExhausted = NO;
        _lastInstallAt = 0;
        _rootGeneration += 1;          /* 作废旧 controller 的在途 completion */
        _controllerInvalidated = NO;   /* 新 controller 视为有效 */
        [self registerDataObserverIfNeeded];
        /* 同 didConnect：必须同步发起，不能推迟到下一轮 runloop（见 attach 内说明） */
        [self installRootIfNeeded];
        [self requestSheetsNow];
        return;
    }

    /* 同一 controller：绝不重装 root，但每次生命周期都向框架核对一次是否已被接受 */
    BOOL confirmed = [self syncAppliedStateFromFramework];
    MFCarPlayLogBoth(@"lifecycle: keep root, no reinstall (%@) applied=%d confirmed=%d ready=%d",
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
    MFCarPlayLogBoth(@"scene entered background, keep root applied=%d", _rootApplied);
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
    MFCarPlayLogBoth(@"data observer registered");
}

- (void)unregisterDataObserver {
    if (!sDataObserverToken) {
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:sDataObserverToken];
    sDataObserverToken = nil;
    _observerOwnedByMe = NO;
    MFCarPlayLogBoth(@"data observer removed");
}

#pragma mark - 数据读取（原生优先，桥接兜底）

/*
 * 11142620 真机日志结论：
 *   CarPlay 以 intent background 冷启动时 RN 运行时没起来，
 *   bridge init / carPlayJSReady / updateSections 全部零出现。
 *   所以数据必须走原生直读 MMKV，不能再等 JS 推。
 *
 * 策略：
 *   1) 先读原生（MFCarPlayNativeData），能拿到就直接用 —— 车机首屏不等 RN。
 *   2) 原生为空时才回落到桥接（手机端 App 已运行时桥接有数据）。
 *   3) 两者都空 -> 返回空数组，UI 会显示"暂无歌单"。
 */
- (NSArray<NSDictionary *> *)sheets {
    NSArray<NSDictionary *> *native = MFCarPlayNativeSheets();
    if (native.count > 0) {
        if (!_nativeSheetsUsed) {
            _nativeSheetsUsed = YES;
            MFCarPlayLogBoth(@"sheets from NATIVE, count=%lu", (unsigned long)native.count);
        }
        return native;
    }
    MFCarPlayBridge *bridge = [MFCarPlayBridge shared];
    NSArray *s = [bridge sheets];
    return [s isKindOfClass:[NSArray class]] ? s : @[];
}

- (NSArray<NSDictionary *> *)tracksForSheet:(NSString *)sheetId {
    if (!sheetId.length) {
        return @[];
    }
    NSArray<NSDictionary *> *native = MFCarPlayNativeTracks(sheetId);
    if (native.count > 0) {
        MFCarPlayLogBoth(@"tracks from NATIVE, sheet=%@ count=%lu",
                         sheetId, (unsigned long)native.count);
        return native;
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

#pragma mark - Root Template（一连接首发一次 / 受限 rearm / animated:NO / 零同步读）

- (void)installRootIfNeeded {
    [self installRootIfNeededAllowRearm:NO];
}

/*
 * allowRearm == NO：正常路径（didConnect / rebind / 生命周期）
 *   - 同一 controller 已装过 -> 只 updateSections，绝不重发
 *   - inFlight -> 挡住重复
 * allowRearm == YES：只有 watchdog 在"最后一次合法尝试"时走这里
 *   - 跳过 _rootInstalledFor / inFlight 两个闸门，但由 watchdog 保证次数上限
 *   - 每次都新建 CPListTemplate（旧的可能已绑定失效连接）
 */
- (void)installRootIfNeededAllowRearm:(BOOL)allowRearm {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }
    if (_rootExhausted) {
        MFCarPlayLogBoth(@"install skipped, rearm exhausted");
        return;
    }

    if (!allowRearm) {
        /*
         * 不变量 1：同一个 controller 只装一次。
         * 无论上次成功还是失败，都绝不再发 setRootTemplate —— 重发会打死 XPC 连接。
         * syncAppliedStateFromFramework 已含 _templateReady 门，未就绪时零同步读。
         */
        if (_rootInstalledFor == ic) {
            if ([self syncAppliedStateFromFramework]) {
                MFCarPlayLogBoth(@"root already installed, updateSections only");
                [self refreshRootSections];
            } else {
                MFCarPlayLogBoth(@"root already set on this controller, no retry (waiting framework)");
            }
            return;
        }

        /* 不变量 2：同一轮并发调用直接挡掉 */
        if (_rootInstallInFlight) {
            MFCarPlayLogBoth(@"root install in flight, skip duplicate");
            return;
        }
    }

    /*
     * 注意：这里**故意不读 ic.topTemplate**。
     * 11142615 日志证明在 didConnect 后立刻同步读 topTemplate 会让框架报
     * `Error accessing synchronous template provider` 并 `Connection interrupted`。
     */
    _rootInstalledFor = ic;
    sRootedController = ic;
    _rootInstallInFlight = YES;
    _rearmPending = NO;

    /*
     * ============ 关键修复：首屏就用真实数据构建模板 ============
     *
     * 11142621 日志的死锁链：
     *   setRootTemplate 发出 -> completion 从不回调 -> _rootApplied 永远 0
     *   -> refreshRootSections 的闸门挡住 -> currentRootSections 从不执行
     *   -> MFCarPlayNativeSheets() 一次都没被调用
     *   -> 车机永远是"正在加载歌单…"占位，看起来像黑屏
     *
     * 修法：**创建模板时就把原生歌单塞进 sections**，不等 completion。
     * 原生数据源 (MMKV) 是同步读的，在 didConnect 里调用完全安全
     * （不碰 CarPlay 的任何同步属性，只读本地文件）。
     */
    NSArray<CPListSection *> *bootSections = [self currentRootSections];
    CPListTemplate *list = [[CPListTemplate alloc] initWithTitle:@"音乐"
                                                        sections:bootSections];
    _rootList = list;

    /*
     * 关键一行：把"首屏模板已带的数据"记进指纹。
     *
     * 为什么必须有：
     *   attachInterfaceController 里紧接着就调 refreshRootSections。
     *   如果这里不记指纹，_lastPushedFingerprint 还是 nil，去重闸门放行，
     *   refreshRootSections 会拿同样内容**新建一批 CPListItem 对象**再推一次。
     *   CarPlay 收到全新对象会当作内容变化重渲染 —— 首屏闪一下、滚动位置重置。
     *
     *   记上指纹后，紧随的 refreshRootSections 会打
     *     "refresh: content unchanged, skip updateSections"
     *   首屏不闪；后续 templateDidAppear 里的 refresh 同样被挡住；
     *   只有歌单真的增删改（指纹变化）才重推。
     */
    _lastPushedFingerprint = [self sectionsFingerprint:bootSections];

    if (allowRearm) {
        MFCarPlayLogBoth(@"rearm #%lu controller=%p (fresh template=%p, sections=%lu)",
              (unsigned long)_rearmCount, (__bridge void *)ic, (__bridge void *)list,
              (unsigned long)bootSections.count);
    } else {
        MFCarPlayLogBoth(@"one-shot root install armed controller=%p (sections=%lu)",
              (__bridge void *)ic, (unsigned long)bootSections.count);
    }

    [self dispatchRootTemplate:list];
    MFCarPlayLogBoth(@"native placeholder root installed (animated=NO)");

    [self scheduleRootWatchdogForController:ic];
}

/*
 * 真正调用 setRootTemplate。
 *
 * @try 的定位（**不要说反因果**）：
 *   @try 只挡「向 stale controller 调用瞬间同步抛异常」这一种情况，
 *   防止 process 被 NSInvalidArgumentException 带走（黑屏变闪退）。
 *   它**保护不了 completion 永远不回** —— 那件事由 watchdog 里
 *   rootInstallTimedOut() 的 3s 静默失败判定负责。
 *   两者职责不同，缺一不可，且不可互相替代。
 *
 * generation token（防晚到 completion 竞态）：
 *   每次发起（首发或 rearm）都 _rootGeneration += 1，闭包捕获当时的值。
 *   completion 回来时若 token != _rootGeneration 说明这是**旧一次**调用的
 *   迟到回调，直接丢弃，绝不允许它覆盖当前状态。
 *   典型场景：首发 completion 因车机 XPC 慢在 3s 后才回，此时 rearm 已发出；
 *   若没有 token，rearm 先成功置 applied=1 后又被首发迟到回调打回 applied=0。
 */
- (BOOL)dispatchRootTemplate:(CPListTemplate *)list {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        _rootInstallInFlight = NO;
        return NO;
    }
    [self recordRootInstallTimestamp];

    _rootGeneration += 1;
    NSUInteger token = _rootGeneration;
    NSUInteger generationAtDispatch = _rearmCount;

    __weak __typeof(self) weakSelf = self;
    @try {
        [ic setRootTemplate:list
                   animated:NO
                 completion:^(BOOL success, NSError * _Nullable error) {
                     __strong __typeof(weakSelf) self = weakSelf;
                     if (!self) {
                         return;
                     }
                     /*
                      * 晚到回调：不是当前这一代，整包丢弃（不改任何状态）。
                      * 只留一条日志便于车机上识别竞态是否真的发生。
                      */
                     if (token != self->_rootGeneration) {
                         MFCarPlayLogBoth(@"stale completion dropped (gen %lu != %lu) success=%d",
                               (unsigned long)token, (unsigned long)self->_rootGeneration, success);
                         return;
                     }
                     /*
                      * 完整打印失败诊断信息。
                      *
                      * 只打 localizedDescription 是不够的：它经常是空串或
                      * 泛化文本，真正的线索在 domain / code / userInfo 里。
                      * 例如：
                      *   domain = CPInterfaceControllerErrorDomain + code = 1
                      *   -> 模板类型不被该 App 类别接受（音频 App 根模板须为
                      *      CPListTemplate / CPGridTemplate）
                      *   domain = NSCocoaErrorDomain / kCFErrorDomainCFNetwork
                      *   -> 提交阶段 XPC 层就失败了
                      * 这一条日志是"第 5 步不出现"时唯一的直接证据。
                      */
                     if (!success) {
                         MFCarPlayLogBoth(@"setRootTemplate FAILED localized=%@ domain=%@ code=%ld userInfo=%@ (gen=%lu rearm=%lu)",
                               error.localizedDescription ?: @"(nil)",
                               error.domain ?: @"(nil)",
                               (long)error.code,
                               error.userInfo ?: @{},
                               (unsigned long)token,
                               (unsigned long)generationAtDispatch);
                     } else {
                         MFCarPlayLogBoth(@"setRootTemplate success=1 error=(null) (gen=%lu rearm=%lu)",
                               (unsigned long)token, (unsigned long)generationAtDispatch);
                     }
                     self->_rootInstallInFlight = NO;
                     self->_rearmPending = NO;
                     if (!success) {
                         /*
                          * completion 明确失败：清掉 applied 以允许 watchdog 计数 rearm，
                          * 但仍向框架核对一次真相（需 _templateReady）。
                          */
                         BOOL confirmed = [self syncAppliedStateFromFramework];
                         if (!confirmed && self->_templateReady) {
                             self->_rootApplied = NO;
                         }
                         return;
                     }
                     BOOL wasRearm = generationAtDispatch > 0;
                     self->_rootApplied = YES;
                     /* 成功即清 rearm 计数，exhausted / invalidated 状态一并解除 */
                     self->_rearmCount = 0;
                     self->_rootExhausted = NO;
                     self->_controllerInvalidated = NO;
                     /*
                      * 握手必然早就结算（rearm 最早发生在 watchdog round 3 = 4.5s），
                      * 但这里显式置位，不依赖调用顺序 —— refreshRootSections 的
                      * 数据源是 MFCarPlayBridge 进程级单例，与旧 template 无关，
                      * 只要 applied=1 且 _templateReady=1 就一定能推成功。
                      */
                     self->_templateReady = YES;
                     if (wasRearm) {
                         /*
                          * rearm 用的是**全新 CPListTemplate**，之前 updateSections
                          * 推给旧模板的数据已经随旧对象丢弃，必须显式再推一次，
                          * 否则车机上是"原生占位空列表"——不黑屏但没内容。
                          */
                         MFCarPlayLogBoth(@"rearm succeeded, repush sections to fresh template");
                     } else {
                         MFCarPlayLogBoth(@"initial root succeeded, push sections");
                     }
                     [self refreshRootSections];
                 }];
    } @catch (NSException *ex) {
        MFCarPlayLogBoth(@"setRootTemplate threw on stale controller: %@", ex.reason);
        _rootInstallInFlight = NO;
        _rearmPending = NO;
        /*
         * 同步异常计入 rearm 次数（否则次数上限对同步异常不生效）。
         * 但若是「controller 已失效」这一类，重试注定无效 —— 直接 exhausted，
         * 不浪费剩余次数（见 didDisconnect 置的 _controllerInvalidated）。
         */
        if (_controllerInvalidated) {
            _rootExhausted = YES;
            MFCarPlayLogBoth(@"rearm exhausted: controller already invalidated, no more attempts");
        } else {
            _rearmCount += 1;
            MFCarPlayLogBoth(@"rearm #%lu threw: %@", (unsigned long)_rearmCount, ex.reason);
        }
        return NO;
    }
    return YES;
}

- (void)recordRootInstallTimestamp {
    _lastInstallAt = [NSDate timeIntervalSinceReferenceDate];
}

/* 距上次 setRootTemplate 是否已超过回传窗口（3s） */
- (BOOL)rootInstallTimedOut {
    if (_lastInstallAt <= 0) {
        return YES;
    }
    return ([NSDate timeIntervalSinceReferenceDate] - _lastInstallAt) >= kMFInstallSettleWindow;
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
            MFCarPlayLogBoth(@"framework confirms root is top (completion lost), applied=1");
        }
        _rootApplied = YES;
        _rootInstallInFlight = NO;
        return YES;
    }
    return NO;
}

/*
 * completion 可能永远不回调（11142515 / 11142615 均实测 inFlight 长期为 1）。
 *
 * watchdog = **受限恢复**，不是重试风暴。规格：
 *
 *   每 tick（1.5s）做一次判定，顺序如下：
 *   1) round 1：握手已结算 -> 置 _templateReady，解锁 topTemplate 同步读
 *   2) syncAppliedStateFromFramework() 成立 -> applied=1，推 sections，结束
 *   3) 静默失败判定（关键，避免第二个死循环）：
 *      若 _rearmPending 且 rootInstallTimedOut()（rearm 发出已超 3s）
 *      且 applied == 0 -> 这次 rearm 视为失败：_rearmPending=NO; _rearmCount 不变
 *      （计数在**发出**时自增，这里只是确认它失败，不再额外 +1，避免双计）
 *   4) rearm 判定：
 *      applied == 0 && !_rearmPending && _templateReady && rootInstallTimedOut()
 *      && _rearmCount < kMFMaxRearm
 *      -> _rearmCount++ ; _rearmPending=YES ; _rootInstallInFlight=NO ;
 *         [self installRootIfNeededAllowRearm:YES]（全新 template 对象）
 *   5) exhausted：
 *      applied == 0 && _rearmCount >= kMFMaxRearm && rootInstallTimedOut()
 *      -> _rootExhausted=YES ; 打一条 `rearm exhausted` ; **停止 polling**
 *   6) round 达到 kMFWatchdogRounds 仍未 applied -> 也走 exhausted 语义并停止
 *
 * exhausted 之后：不再有任何 setRootTemplate，也不再空转。
 * 若框架之后重新 didConnect（切歌 / 车机重连），attachInterfaceController:
 * 会重置全部状态并正常设模板，覆盖 exhausted。
 *
 * 次数上限保证：一个连接生命周期内 setRootTemplate 最多 1 + kMFMaxRearm = 3 次，
 * 远低于 11142415 的 9 次风暴。
 */
- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic {
    [self scheduleRootWatchdogForController:ic round:1];
}

- (void)scheduleRootWatchdogForController:(CPInterfaceController *)ic round:(NSUInteger)round {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMFWatchdogTick * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        if (self.interfaceController != ic) {
            return;
        }
        if (self->_rootExhausted) {
            /* 已经放弃过，不再空转（正常情况下不会到这里，双保险） */
            return;
        }
        if (!self->_templateReady) {
            self->_templateReady = YES;
            MFCarPlayLogBoth(@"watchdog round=%lu: sync probe unlocked (handshake settled)",
                  (unsigned long)round);
        }

        /* 2) 已确认成功 -> 推内容并结束 */
        if ([self syncAppliedStateFromFramework]) {
            MFCarPlayLogBoth(@"watchdog round=%lu: framework confirms root, push sections",
                  (unsigned long)round);
            [self refreshRootSections];
            return;
        }

        BOOL timedOut = [self rootInstallTimedOut];
        MFCarPlayLogBoth(@"watchdog round=%lu: applied=0 inFlight=%d rearm=%lu pending=%d timedOut=%d invalid=%d",
              (unsigned long)round,
              self->_rootInstallInFlight,
              (unsigned long)self->_rearmCount,
              self->_rearmPending,
              timedOut,
              self->_controllerInvalidated);

        /*
         * 3a) controller 已失效（didDisconnect 置位）：重试注定无效，
         * 直接 exhausted，不消耗 rearm 次数。
         * 加 !_rearmPending 条件：刚发出的一次 rearm 还在自己的 3s 窗口内时
         * 不要抢先判死，让它在第 3) 步按静默失败正常结算。
         */
        if (self->_controllerInvalidated && !self->_rootApplied && !self->_rearmPending) {
            self->_rootExhausted = YES;
            self->_rootInstallInFlight = NO;
            MFCarPlayLogBoth(@"rearm exhausted: controller invalidated, stop polling (wait for reconnect)");
            return;
        }

        /* 3) 静默失败判定：rearm 发出超 3s 仍 applied=0 -> 这次 rearm 失败 */
        if (self->_rearmPending && timedOut && !self->_rootApplied) {
            self->_rearmPending = NO;
            self->_rootInstallInFlight = NO;
            MFCarPlayLogBoth(@"rearm #%lu silently failed (no completion in %.0fs)",
                  (unsigned long)self->_rearmCount, kMFInstallSettleWindow);
        }

        /*
         * 3b) 首发也在等自己的 3s 窗口：若 completion 还没回来且未超窗，
         * 只继续 polling，绝不提前 rearm（避免正常慢回传被误判成失败）。
         */
        BOOL initialSettling = (!self->_rootApplied
                                && self->_rearmCount == 0
                                && self->_rootInstallInFlight
                                && !timedOut);
        if (initialSettling) {
            MFCarPlayLogBoth(@"watchdog round=%lu: initial install still settling, wait",
                  (unsigned long)round);
            [self scheduleRootWatchdogForController:ic round:(round + 1)];
            return;
        }

        /* 5) exhausted：次数用尽且最后一次也超时 */
        if (!self->_rootApplied && self->_rearmCount >= kMFMaxRearm && !self->_rearmPending && timedOut) {
            self->_rootExhausted = YES;
            self->_rootInstallInFlight = NO;
            MFCarPlayLogBoth(@"rearm exhausted after %lu attempts, stop polling (wait for system reconnect)",
                  (unsigned long)self->_rearmCount);
            return;
        }

        /* 4) rearm：给 completion 合理的 3s 回传窗口，且次数与并发都要满足 */
        if (!self->_rootApplied && !self->_rearmPending && timedOut
            && self->_rearmCount < kMFMaxRearm) {
            self->_rearmCount += 1;
            self->_rearmPending = YES;
            self->_rootInstallInFlight = NO; /* 先清 inFlight，否则新调用会被挡 */
            MFCarPlayLogBoth(@"watchdog round=%lu: root not accepted, rearm #%lu/%lu",
                  (unsigned long)round,
                  (unsigned long)self->_rearmCount,
                  (unsigned long)kMFMaxRearm);
            [self installRootIfNeededAllowRearm:YES];
            return;
        }

        /* 6) 总轮数兜底 */
        if (round >= kMFWatchdogRounds) {
            self->_rootExhausted = YES;
            self->_rootInstallInFlight = NO;
            MFCarPlayLogBoth(@"rearm exhausted at round cap (%lu), stop polling",
                  (unsigned long)round);
            return;
        }
        [self scheduleRootWatchdogForController:ic round:(round + 1)];
    });
}

- (void)refreshRootSections {
    /*
     * ============ 架构：数据准备 与 UI 提交 彻底拆开 ============
     *
     * 11142621 的教训：_rootApplied 由 completion 置位，completion 不回调，
     * 于是数据准备这一步被 UI 前置条件挡住，原生数据一次都没读，
     * 日志里一条 [native-data] 都没有 —— 这是可观测性 bug。
     *
     * 现在：
     *   第一步 数据准备：**无条件执行**，只读本地（MMKV），不碰任何 CarPlay 状态。
     *                    执行完立刻打日志，这样数据层可以独立验证。
     *   第二步 UI 提交：才检查 _rootApplied / interfaceController。
     *                    条件不满足就只缓存，等 root 被接受后补推。
     */

    /* ---------- 第一步：数据准备（不依赖任何 CarPlay 状态） ---------- */
    NSArray<CPListSection *> *sections = [self currentRootSections];
    _lastSections = sections;

    if (!_nativeDataLogged) {
        _nativeDataLogged = YES;
        MFCarPlayLogBoth(@"refresh: data ready sections=%lu (first time)",
              (unsigned long)sections.count);
    } else {
        MFCarPlayLogBoth(@"refresh: data ready sections=%lu", (unsigned long)sections.count);
    }

    /* ---------- 第二步：UI 提交 ---------- */
    if (!_rootList) {
        MFCarPlayLogBoth(@"refresh: no rootList yet, cached %lu sections",
              (unsigned long)sections.count);
        return;
    }
    if (!_rootApplied) {
        /*
         * 不依赖 completion：这里再试一次框架真相核对（双通道置位的 B 通道）。
         * 若 topTemplate 就是我们的 list，说明框架已接受但 completion 丢了。
         * 该核对内部有 _templateReady 门，握手未结算时不会碰同步属性。
         */
        if (_templateReady && [self syncAppliedStateFromFramework]) {
            MFCarPlayLogBoth(@"refresh: applied via framework check (completion was lost)");
        } else {
            MFCarPlayLogBoth(@"refresh: root not applied yet, cache only (%lu sections)",
                  (unsigned long)sections.count);
            return;
        }
    }
    if (!self.interfaceController) {
        MFCarPlayLogBoth(@"refresh: no interfaceController, skip push");
        return;
    }

    /*
     * 去重：CarPlay 收到**全新的 CPListItem 对象**会当作列表内容变化重新渲染，
     * 表现为闪烁、滚动位置丢失。refreshRootSections 有三个调用点
     * （didConnect / templateDidAppear / completion 成功），必须挡住重复推送。
     *
     * 判据用"内容指纹"而不是对象指针 —— 每次 currentRootSections 都会新建
     * CPListItem，指针必然不同，但内容相同就不该重推。
     */
    NSString *fingerprint = [self sectionsFingerprint:sections];
    if (_lastPushedFingerprint && [_lastPushedFingerprint isEqualToString:fingerprint]) {
        MFCarPlayLogBoth(@"refresh: content unchanged, skip updateSections (%lu sections)",
              (unsigned long)sections.count);
        return;
    }
    _lastPushedFingerprint = fingerprint;

    [_rootList updateSections:sections];
    MFCarPlayLogBoth(@"updateSections root sections=%lu sheetsReceived=%d applied=%d",
          (unsigned long)sections.count, _sheetsReceived, _rootApplied);
}

/*
 * sections 内容指纹：只取"用户可见的文字"，不取对象地址。
 * 覆盖标题 + 副标题 + 每个 section 的 item 数。
 * 歌单增删改、数量变化都会改变指纹，从而允许重推。
 */
- (NSString *)sectionsFingerprint:(NSArray<CPListSection *> *)sections {
    NSMutableString *buf = [NSMutableString string];
    for (CPListSection *sec in sections) {
        NSArray *items = nil;
        @try {
            /* CPListSection 没有公开的 items 读取接口，借 KVC 拿；
               拿不到就退化为按 section 计数，仍能挡住大部分重复。 */
            items = [sec valueForKey:@"items"];
        } @catch (NSException *e) {
            (void)e;
            items = nil;
        }
        [buf appendFormat:@"[%lu]", (unsigned long)([items isKindOfClass:[NSArray class]] ? items.count : 0)];
        if ([items isKindOfClass:[NSArray class]]) {
            for (id it in (NSArray *)items) {
                NSString *t = nil;
                NSString *d = nil;
                @try {
                    t = [it valueForKey:@"text"];
                    d = [it valueForKey:@"detailText"];
                } @catch (NSException *e) {
                    (void)e;
                }
                [buf appendFormat:@"(%@|%@)", t ?: @"", d ?: @""];
            }
        }
    }
    return buf;
}

/* 把 sections 应用到当前 root 模板（供 completion 成功后补推复用） */
- (void)applySectionsToRootTemplate:(NSArray<CPListSection *> *)sections {
    if (!_rootList) {
        MFCarPlayLogBoth(@"applySections: no rootList");
        return;
    }
    if (!sections) {
        sections = _lastSections ?: [self currentRootSections];
    }
    [_rootList updateSections:sections];
    MFCarPlayLogBoth(@"applySections: applied %lu sections to root",
          (unsigned long)sections.count);
}

#pragma mark - 歌单子页

- (void)pushTracksForSheet:(NSString *)sheetId title:(NSString *)title {
    CPInterfaceController *ic = self.interfaceController;
    if (!ic) {
        return;
    }
    /* 握手未结算时不碰同步属性；root 都没确认时也不 push，避免脏栈 */
    if (!_templateReady) {
        MFCarPlayLogBoth(@"push ignored, template handshake not settled yet (sheet=%@)", sheetId);
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
                MFCarPlayLogBoth(@"play track %@ in sheet %@", tid, sheetId);
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
    MFCarPlayLogBoth(@"updateSections tracks=%lu sheet=%@",
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
        MFCarPlayLogBoth(@"nowPlaying updated");
    }
}

#pragma mark - 冷启动 requestSheets 重发

- (void)requestSheetsNow {
    MFCarPlayLogBoth(@"requestSheets");
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
            MFCarPlayLogBoth(@"requestSheets retry %lu", (unsigned long)i);
            [MFCarPlayBridge emitControl:@"requestSheets"];
        });
    }
}

@end
