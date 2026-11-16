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
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>   /* objc_msgSend：BOOl/无参类方法的防御式调用 */   /* CarPlay 会话建立期声明音频类别 */

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
/*
 * _rootExhausted 自动恢复的节流参数（11142630）。
 *
 * willEnterForeground / didBecomeActive 常同秒连续触发，若无节制 reset
 * 会形成"reset -> install -> timedOut -> exhausted"快速循环，
 * 日志难读且无意义。两道闸：
 *   1) 距上次 reset 至少 3s
 *   2) 同一 controller 内最多 2 次
 * 换 controller（真重连）时两者都清零，仍享完整机会。
 */
static const NSTimeInterval kMFResetMinInterval = 3.0;
static const NSUInteger kMFMaxResets = 2;

/* 进程级幂等状态：scene 反复 activate 时不会重复注册 / 重复设 root */
static __weak CPInterfaceController *sRootedController = nil;
static __weak MFCarPlaySceneDelegate *sActiveDelegate = nil;
static id<NSObject> sDataObserverToken = nil;

@class MFCarPlayWindowRootVC;

@interface MFCarPlaySceneDelegate () <UISceneDelegate>
/* 11142648：window 路径的根控制器与数据观察者 */
@property (nonatomic, strong, nullable) MFCarPlayWindowRootVC *windowRootVC;
@property (nonatomic, strong, nullable) id windowDataObserver;
- (void)registerWindowDataObserver;
- (NSArray<NSDictionary *> *)historyForCarPlay;
- (NSArray<NSDictionary *> *)searchForCarPlay:(NSString *)query;
- (NSDictionary *)nowPlayingForCarPlay;
- (NSArray<NSDictionary *> *)playQueueForCarPlay;
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

#pragma mark - 车机窗口 UI（11142648：可交互列表）

/*
 * 11142651：无边框返回按钮。
 *
 * 导航栏被全局隐藏后，子页面需要一个返回入口：
 *   - 车机触摸屏的边缘滑动返回在部分车型上不触发
 *   - 所以每个子页面左上角放一个轻量「←」，不占导航栏高度
 *
 * 只加在子页面（歌单/曲目/搜索/播放），主界面不需要。
 */
/*
 * 11142653：统一主题色（对齐用户截图里的浅蓝 #4A9EFF）。
 * 系统 [UIColor blueColor] 偏深，车机屏上不好看。
 */
/*
 * 11142653：通用封面异步加载。
 *
 * 所有列表（歌单/曲目/最近播放）都要显示封面缩略图，
 * 抽成全局函数避免每个类重复实现。
 *
 *   urlStr   封面地址
 *   cell     目标 UITableVeiwCell（用它的 imageView）
 *
 * 失败静默（网络差就不显示图，不影响文字）。
 */
static void MFLoadCoverIntoCell(NSString *urlStr, UITableViewCell *cell) {
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0 || !cell) {
        return;
    }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        return;
    }
    __weak UITableViewCell *weakCell = cell;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:url];
        UIImage *img = data ? [UIImage imageWithData:data] : nil;
        if (!img) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            /*
             * 11142667：防闪退。
             * reloadData 后 cell 可能已不在视图层级里，
             * 直接设图会崩。必须检查 window 是否还存在。
             */
            @try {
                __strong UITableViewCell *c = weakCell;
                if (!c || !c.window) {
                    return;
                }
                c.imageView.image = img;
            } @catch (NSException *e) {
                MFCarPlayLogBoth(@"MFLoadCoverIntoCell threw: %@", e.reason);
            }
        });
    });
}

/*
 * 11142656：统一背景色（对齐用户图二的深灰，不是纯黑）。
 *
 * 纯黑 #000000 在车机屏上对比太硬、边缘看不出层次。
 * 用 #1C1C1E —— iOS 深色模式下系统级的次级背景色。
 */
/*
 * 11142658：由曲目 dict 直接构造播放页数据（不读 MMKV）。
 *
 * 解决「点的歌和播放页显示不一致」：
 *   点歌后 JS 处理有延迟，MMKV 还没更新，读它会拿到上一首。
 *   点歌这一刻我们手里有这首歌的完整数据，直接用它。
 */
/*
 * ============ 11142664：reloadData 安全包装 ============
 *
 * 日志证据：切到榜单 tab 后立刻闪退，且之后无任何日志。
 * 说明崩在 UITableView 内部（数据源与视图状态不一致）。
 *
 * 这里给所有 reloadData 包一层异常捕获，
 * 任何异常都记录到日志而不是直接崩掉整个 App。
 *
 * 这样做的好处：
 *   1) 即使某个分支有 bug，也只是这个页面显示异常，App 不闪退
 *   2) 日志里能看到具体异常原因，方便定位
 */
static void MFSafeReload(UITableView *tv, NSString *tag) {
    if (!tv) {
        return;
    }
    @try {
        [tv reloadData];
    } @catch (NSException *e) {
        MFCarPlayLogBoth(@"RELOAD(%@) threw: %@ -- %@", tag ?: @"?",
              e.name, e.reason);
    }
}

/*
 * ============ 11142666：自适应缩放 ============
 *
 * 问题：之前所有尺寸都是硬编码（220 封面、76 行高、19 号字…），
 * 在你 1066x480 的车机上刚好，换个 800x480 或 1280x720 的屏幕就错位。
 *
 * 方案：以 1066x480（横向）为基准，按屏幕实际尺寸算缩放系数。
 *
 *   scaleW = 实际宽 / 1066
 *   scaleH = 实际高 / 480
 *   scale  = min(scaleW, scaleH)     取小的，保证不溢出
 *
 * 然后把 scale 夹到 [0.75, 1.6] 之间：
 *   - 太小（< 0.75）字会看不清
 *   - 太大（> 1.6）布局会撑破
 *
 * 用函数而不是宏，方便调试时打日志。
 */

/* 基准尺寸（我们一开始按这个调的） */
static const CGFloat kMFBaseWidth = 1066.0;
static const CGFloat kMFBaseHeight = 480.0;

/* 当前界面的缩放系数（每个 VC 在 viewDidLayoutSubviews 里刷新） */
static CGFloat sMFScale = 1.0;
static CGSize sMFScreenSize = {1066.0, 480.0};

/* 根据屏幕尺寸计算并缓存缩放系数 */
static CGFloat MFScaleForSize(CGSize size) {
    if (size.width <= 0 || size.height <= 0) {
        return 1.0;
    }
    sMFScreenSize = size;
    CGFloat sw = size.width / kMFBaseWidth;
    CGFloat sh = size.height / kMFBaseHeight;
    CGFloat s = sw < sh ? sw : sh;

    /* 夹逼，避免极端值 */
    if (s < 0.75) {
        s = 0.75;
    }
    if (s > 1.6) {
        s = 1.6;
    }
    sMFScale = s;
    return s;
}

/* 读当前缩放系数（未初始化则 1.0） */
static CGFloat MFScale(void) {
    return sMFScale;
}

/* 按比例缩放一个数值 */
static CGFloat MFS(CGFloat v) {
    return v * sMFScale;
}

/* 按比例缩放字体（字号跟着变，但保留最小可读值） */
static UIFont *MFFont(CGFloat size) {
    CGFloat scaled = size * sMFScale;
    /* 车机上最小 13pt，再小看不清 */
    if (scaled < 13.0) {
        scaled = 13.0;
    }
    return [UIFont systemFontOfSize:scaled];
}

static NSDictionary *MFNowPlayingFromTrack(NSDictionary *track) {
    if (![track isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return @{
        @"id": track[@"id"] ?: @"",
        @"title": track[@"title"] ?: @"",
        @"artist": track[@"artist"] ?: @"",
        @"album": track[@"album"] ?: @"",
        @"artwork": track[@"artwork"] ?: @"",
        @"platform": track[@"platform"] ?: @"",
        @"duration": @(0),
        @"progress": @(0),
        @"queueCount": @(0),
    };
}

static UIColor *MFCarPlayBackgroundColor(void) {
    return [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];   /* #1C1C1E */
}

/* 卡片/列表行稍亮一档，形成层次 */
static UIColor *MFCarPlayCardColor(void) {
    return [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0];   /* #2C2C2E */
}

static UIColor *MFCarPlayAccentColor(void) {
    return [UIColor colorWithRed:0.29 green:0.62 blue:1.00 alpha:1.0];
}

/*
 * 11142654：返回按钮重做。
 *
 * 上一版问题（用户反馈图二）：
 *   按钮加在 vc.view 上，但 UITableView 铺满整个 view 且后添加，
 *   把按钮盖住了 —— 所以「左上角依旧没有返回按钮」。
 *
 * 修法：
 *   1) 加完后 bringSubviewToFront: 强制置顶
 *   2) 改成浅蓝 + 「← 返回」文字（对齐用户图五）
 *   3) 尺寸放大到 100x44，车机触摸友好
 */
static void MFAddBackButton(UIViewController *vc) {
    UIButton *b = [UIButton buttonWithType:0];
    [b setTitle:@"\u2190 \u8fd4\u56de" forState:0];   /* ← 返回 */
    [b setTitleColor:MFCarPlayAccentColor() forState:0];
    b.titleLabel.font = MFFont(19.0);
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:vc action:@selector(onBack) forControlEvents:64];
    [vc.view addSubview:b];
    /*
     * 11142656：位置修正。
     *
     * 用户反馈「返回按钮位置不对」——原来 top=6 会顶到车机状态栏
     * （时间/信号那一行），视觉上像被切掉一半。
     *
     * 下移到 34，正好在状态栏下方、内容区上方。
     */
    /*
     * 11142658：按用户反馈调整。
     *   - 整体上移：top 34 -> 14（原来离状态栏太远，中间空一条）
     *   - 返回键右移：leading 16 -> 34（原来贴左边太紧）
     */
    [NSLayoutConstraint activateConstraints:@[
        [b.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:14],
        [b.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:34],
        [b.widthAnchor constraintEqualToConstant:MFS(120)],
        [b.heightAnchor constraintEqualToConstant:MFS(44)],
    ]];

    /* 关键：表格是后加的，必须把按钮提上来 */
    [vc.view bringSubviewToFront:b];
}

/*
 * 11142654：顶部居中标题（对齐图五「经典老歌 | 90后必听的怀旧金曲」）。
 */
static void MFAddTopTitle(UIViewController *vc, NSString *title) {
    if (title.length == 0) {
        return;
    }
    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = MFFont(19.0);
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:14],
        [l.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [l.leadingAnchor constraintGreaterThanOrEqualToAnchor:vc.view.leadingAnchor constant:160],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:vc.view.trailingAnchor constant:-20],
        [l.heightAnchor constraintEqualToConstant:MFS(44)],
    ]];
    [vc.view bringSubviewToFront:l];
}


/*
 * 为什么用 UITableView 而不是 UILabel 堆叠：
 *   11142647 的手摆 UILabel 无法点击、也不会刷新。
 *   UITableView + delegate 同时解决交互和刷新两件事，
 *   而且滚动、选中高亮、行高都由系统处理。
 *
 * 两个层级：
 *   MFCarPlayWindowRootVC     歌单列表 -> 点击进入曲目列表
 *   MFCarPlayWindowTracksVC   曲目列表 -> 点击播放
 */

/*
 * ============ 11142658：车机内置软键盘 ============
 *
 * 为什么必须自绘：
 *   日志确证 —— CarPlay 场景下我们的 UIWindow 无法成为 key window：
 *     SEARCH kb: win=yes isKey=0
 *     SEARCH kb: forced makeKeyWindow, now isKey=0     <- 强制失败
 *     SEARCH kb: becomeFirstResponder after 0.00s -> 1 (isFirst=1)  <- 控件成功
 *   控件已是第一响应者，但键盘不显示 —— iOS 不允许第三方 App 在
 *   CarPlay 上弹系统键盘。只能自己画。
 *
 * 设计：
 *   QWERTY 三行字母 + 一行功能键（退格 / 空格 / 清除）
 *   车机屏 1066x480，每行 10 键，单键约 92x44，触摸友好。
 *   输入内容直接拼进 UITextField.text，再触发搜索。
 *
 * 拼音：
 *   中文歌名打不出来 —— 用 CFStringTransform 把汉字转拼音，
 *   输入 "th" 也能命中「天后」。
 */
@interface MFCarPlayKeyboardView : UIView
@property (nonatomic, weak) UITextField *targetField;
@property (nonatomic, copy) void (^onChange)(NSString *text);
- (instancetype)initWithTargetField:(UITextField *)field;
@end

@implementation MFCarPlayKeyboardView

- (instancetype)initWithTargetField:(UITextField *)field {
    self = [super initWithFrame:CGRectZero];
    if (!self) {
        return nil;
    }
    self.targetField = field;
    self.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.14 alpha:1.0];
    self.layer.cornerRadius = MFS(10.0);
    self.layer.masksToBounds = YES;

    /*
     * ============ 11142668：键盘布局重做 ============
     *
     * 原问题（用户截图）：按键贴到左边缘、右侧大片空白、行间不对齐。
     *
     * 根因：按键宽度固定 MFS(88)，但每行按键数不同
     *   第1行 10 键 -> 10*88 + 9*8 = 952
     *   第2行  9 键 ->  9*88 + 8*8 = 856
     *   第3行  7 键 ->  7*88 + 6*8 = 664   <- 只占 664，右边空一大片
     *
     * 修法：每行按键等分剩余宽度。
     *   1) 每行容器左右各留 10 边距
     *   2) 按键之间 8 间距
     *   3) 按键宽度 = (行宽 - 间距总和) / 键数   -> 用 equalToAnchor 实现
     *
     * 这样三行都撑满，视觉上居中对齐。
     */
    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"Q", @"W", @"E", @"R", @"T", @"Y", @"U", @"I", @"O", @"P"],
        @[@"A", @"S", @"D", @"F", @"G", @"H", @"J", @"K", @"L"],
        @[@"Z", @"X", @"C", @"V", @"B", @"N", @"M"],
    ];

    UIFont *keyFont = MFFont(22.0);
    UIColor *keyBg = [UIColor colorWithRed:0.25 green:0.25 blue:0.27 alpha:1.0];
    CGFloat gap = MFS(8);
    CGFloat sidePad = MFS(10);

    UIView *prevRow = nil;
    for (NSUInteger r = 0; r < rows.count; r++) {
        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:row];

        UIButton *prevKey = nil;
        UIButton *firstKey = nil;

        for (NSString *ch in rows[r]) {
            UIButton *k = [UIButton buttonWithType:0];
            [k setTitle:ch forState:0];
            [k setTitleColor:[UIColor whiteColor] forState:0];
            k.titleLabel.font = keyFont;
            k.backgroundColor = keyBg;
            k.layer.cornerRadius = MFS(6.0);
            k.translatesAutoresizingMaskIntoConstraints = NO;
            [k addTarget:self action:@selector(onLetter:) forControlEvents:64];
            [row addSubview:k];

            [NSLayoutConstraint activateConstraints:@[
                [k.topAnchor constraintEqualToAnchor:row.topAnchor],
                [k.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
            ]];

            if (prevKey) {
                /* 宽度与第一个键相同（等分），左边接上一个键 */
                [NSLayoutConstraint activateConstraints:@[
                    [k.leadingAnchor constraintEqualToAnchor:prevKey.trailingAnchor constant:gap],
                    [k.widthAnchor constraintEqualToAnchor:firstKey.widthAnchor],
                ]];
            } else {
                [NSLayoutConstraint activateConstraints:@[[k.leadingAnchor constraintEqualToAnchor:row.leadingAnchor]]];
                firstKey = k;
            }
            prevKey = k;
        }
        /* 最后一个键贴右边界 -> 整行自动等分 */
        if (prevKey) {
            [NSLayoutConstraint activateConstraints:@[[prevKey.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]]];
        }

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:sidePad],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-sidePad],
            [row.heightAnchor constraintEqualToConstant:MFS(46)],
        ]];
        if (prevRow) {
            [NSLayoutConstraint activateConstraints:@[[row.topAnchor constraintEqualToAnchor:prevRow.bottomAnchor constant:gap]]];
        } else {
            [NSLayoutConstraint activateConstraints:@[[row.topAnchor constraintEqualToAnchor:self.topAnchor constant:MFS(10)]]];
        }
        prevRow = row;
    }

    /* 第四行：退格 / 空格 / 清除 */
    UIView *funcRow = [[UIView alloc] init];
    funcRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:funcRow];

    UIButton *del = [self makeFuncButton:@"\u232B" action:@selector(onDelete)];
    UIButton *space = [self makeFuncButton:@"\u7a7a\u683c" action:@selector(onSpace)];
    UIButton *clr = [self makeFuncButton:@"\u6e05\u9664" action:@selector(onClear)];
    for (UIButton *b in @[del, space, clr]) {
        [funcRow addSubview:b];
        [NSLayoutConstraint activateConstraints:@[
            [b.topAnchor constraintEqualToAnchor:funcRow.topAnchor],
            [b.bottomAnchor constraintEqualToAnchor:funcRow.bottomAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        /* 退格和清除等宽，空格自动撑满中间 */
        [del.leadingAnchor constraintEqualToAnchor:funcRow.leadingAnchor],
        [del.widthAnchor constraintEqualToConstant:MFS(140)],

        [space.leadingAnchor constraintEqualToAnchor:del.trailingAnchor constant:gap],
        [space.trailingAnchor constraintEqualToAnchor:clr.leadingAnchor constant:-gap],

        [clr.trailingAnchor constraintEqualToAnchor:funcRow.trailingAnchor],
        [clr.widthAnchor constraintEqualToAnchor:del.widthAnchor],

        [funcRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:sidePad],
        [funcRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-sidePad],
        [funcRow.heightAnchor constraintEqualToConstant:MFS(46)],
        [funcRow.topAnchor constraintEqualToAnchor:prevRow.bottomAnchor constant:gap],
        [funcRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-MFS(10)],
    ]];

    return self;
}

- (UIButton *)makeFuncButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:0];
    [b setTitle:title forState:0];
    [b setTitleColor:[UIColor whiteColor] forState:0];
    b.titleLabel.font = MFFont(20.0);
    b.backgroundColor = [UIColor colorWithRed:0.30 green:0.30 blue:0.33 alpha:1.0];
    b.layer.cornerRadius = MFS(6.0);   /* 11142674: 键盘功能键，随屏幕缩放 */
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:action forControlEvents:64];
    return b;
}

- (void)commit:(NSString *)newText {
    if (![newText isKindOfClass:[NSString class]]) {
        return;
    }
    /*
     * 11142671：输入后键盘不能消失。
     *
     * 用户反馈「输入一个字母键盘就消失了」。
     * 根因：doSearch 里 reloadData 触发了布局重排，
     * 把键盘挤掉 / 或者键盘被误隐藏。
     *
     * 修法：commit 后显式把键盘重新提到最前并保持显示。
     */
    self.targetField.text = newText;

    /* 保证键盘仍然可见 */
    self.hidden = NO;
    [self.superview bringSubviewToFront:self];

    if (self.onChange) {
        self.onChange(newText);
    }
}

- (void)onLetter:(UIButton *)sender {
    NSString *cur = self.targetField.text ?: @"";
    NSString *newText = [cur stringByAppendingString:sender.titleLabel.text ?: @""];
    MFCarPlayLogBoth(@"[KEYBOARD] letter '%@' -> '%@'",
          sender.titleLabel.text ?: @"?", newText);
    [self commit:newText];
}

- (void)onDelete {
    NSString *cur = self.targetField.text ?: @"";
    if (cur.length == 0) {
        return;
    }
    [self commit:[cur substringToIndex:cur.length - 1]];
}

- (void)onSpace {
    NSString *cur = self.targetField.text ?: @"";
    [self commit:[cur stringByAppendingString:@" "]];
}

- (void)onClear {
    [self commit:@""];
}

@end

/*
 * ============ 11142654：统一列表 Cell ============
 *
 * 为什么不用系统 cell.imageView：
 *   系统 imageView 的尺寸由 UITableViewCell 内部控制（约 40x40 随行高变），
 *   无法设圆角、无法精确控制边距。用户反馈「封面过大」「没有圆角」
 *   就是这个原因。
 *
 * 本类完全自绘：
 *   ┌────────────────────────────────────┐
 *   │ ┌────┐  主标题                    │  封面 40x40 圆角 5
 *   │ │    │  副标题（歌手 · 专辑）      │  主标题 19px 白
 *   │ └────┘                             │  副标题 15px 灰
 *   └────────────────────────────────────┘
 */
@interface MFCarPlayListCell : UITableViewCell
/* 11142659：卡片容器（圆角背景，实现「每首歌之间有框」） */
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) UILabel *mainLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, copy) NSString *coverToken;   /* 防止复用错图 */
@end

@implementation MFCarPlayListCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) {
        return nil;
    }

    /*
     * ============ 11142659：卡片样式 ============
     *
     * 用户要求「歌曲跟歌曲之间加个框」——参考截图，
     * 每行是一个独立的圆角卡片，卡片之间留间隙。
     *
     * 结构：
     *   cell (透明底)
     *     └ cardView (深灰圆角 10，内缩 6/4)
     *          ├ coverView (40x40 圆角 5)
     *          ├ mainLabel
     *          └ subLabel
     *
     * 关键点：
     *   - cell 本身透明，露出背景色
     *   - cardView 上下各留 4px，左右各留 6px -> 形成间隙
     *   - separatorStyle 设为 None（改用卡片间隙分隔）
     */
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = 0;

    /* 卡片容器 */
    self.cardView = [[UIView alloc] init];
    self.cardView.backgroundColor = MFCarPlayCardColor();
    self.cardView.layer.cornerRadius = MFS(10.0);
    self.cardView.layer.masksToBounds = YES;
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.cardView];

    /* 封面：40x40，圆角 5 */
    self.coverView = [[UIImageView alloc] init];
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.backgroundColor = [UIColor colorWithRed:0.24 green:0.24 blue:0.26 alpha:1.0];
    self.coverView.layer.cornerRadius = MFS(5.0);
    self.coverView.layer.masksToBounds = YES;
    self.coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:self.coverView];

    /* 主标题 */
    self.mainLabel = [[UILabel alloc] init];
    self.mainLabel.font = MFFont(19.0);
    self.mainLabel.textColor = [UIColor whiteColor];
    self.mainLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:self.mainLabel];

    /* 副标题 */
    self.subLabel = [[UILabel alloc] init];
    self.subLabel.font = MFFont(15.0);
    self.subLabel.textColor = [UIColor colorWithRed:0.72 green:0.72 blue:0.74 alpha:1.0];
    self.subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:self.subLabel];

    /* 布局 */
    [NSLayoutConstraint activateConstraints:@[
        /* 卡片：左右 6，上下 4（形成卡片间隙） */
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
        [self.cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        /* 封面：卡片内左 12，垂直居中，40x40 */
        [self.coverView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:12],
        [self.coverView.centerYAnchor constraintEqualToAnchor:self.cardView.centerYAnchor],
        [self.coverView.widthAnchor constraintEqualToConstant:MFS(40)],
        [self.coverView.heightAnchor constraintEqualToConstant:MFS(40)],

        /* 主标题 */
        [self.mainLabel.leadingAnchor constraintEqualToAnchor:self.coverView.trailingAnchor constant:12],
        [self.mainLabel.topAnchor constraintEqualToAnchor:self.coverView.topAnchor constant:-1],
        [self.mainLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        /* 副标题 */
        [self.subLabel.leadingAnchor constraintEqualToAnchor:self.mainLabel.leadingAnchor],
        [self.subLabel.bottomAnchor constraintEqualToAnchor:self.coverView.bottomAnchor constant:1],
        [self.subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardView.trailingAnchor constant:-16],
    ]];

    return self;
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                     cover:(NSString *)coverURL {
    self.mainLabel.text = title ?: @"";
    self.subLabel.text = subtitle ?: @"";
    self.coverToken = coverURL ?: @"";
    self.coverView.image = nil;    /* 先清空，避免复用到上一张图 */

    if (coverURL.length == 0) {
        return;
    }

    /*
     * ============ 11142667：异步封面防闪退 ============
     *
     * 用户反馈「点键盘就闪退」。
     *
     * 根因：每次按键都会 reloadData，reloadData 会销毁并重建所有 cell。
     * 此时之前发起封面下载的回调仍在排队，回来后访问的 cell 可能
     * 已经不在视图层级里（甚至已被释放），给它的 coverView 设图会崩。
     *
     * 修法（三重保护）：
     *   1) weakSelf + 强引用判空（已有）
     *   2) 检查 cell 是否还有 window（在视图层级中才更新）
     *   3) token 一致性（防止复用到别的歌）
     */
    NSString *token = [coverURL copy];
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:token]];
            UIImage *img = data ? [UIImage imageWithData:data] : nil;
            if (!img) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    __strong __typeof(weakSelf) s = weakSelf;
                    /* 1. cell 还活着 */
                    if (!s) {
                        return;
                    }
                    /* 2. cell 还在视图层级里（已被 reload 移除的就跳过） */
                    if (!s.window) {
                        return;
                    }
                    /* 3. token 一致 */
                    if (![s.coverToken isEqualToString:token]) {
                        return;
                    }
                    s.coverView.image = img;
                } @catch (NSException *e) {
                    MFCarPlayLogBoth(@"CELL cover set threw: %@", e.reason);
                }
            });
        }
    });
}

@end

@interface MFCarPlayWindowRootVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, weak) MFCarPlaySceneDelegate *carPlayDelegate;

/* 顶部横向 tab 容器 */
@property (nonatomic, strong) UIView *tabBar;
@property (nonatomic, strong) NSArray<UIButton *> *tabButtons;
@property (nonatomic, assign) NSInteger selectedTab;   /* 0=歌单 1=搜索 2=最近 */

/* 内容区 */
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) NSArray<NSDictionary *> *sheets;
@property (nonatomic, strong) NSArray<NSDictionary *> *results;
/* 11142655：当前搜索词，用于校验 JS 回传结果是否过期 */
@property (nonatomic, copy) NSString *currentQuery;
/* 11142658：自绘软键盘（CarPlay 不让弹系统键盘） */
@property (nonatomic, strong) MFCarPlayKeyboardView *keyboardView;
/* 11142667：搜索防抖（避免每次按键都 reloadData 导致闪退） */
@property (nonatomic, strong) NSTimer *searchDebounceTimer;
/* 11142669：表格顶部两个约束，按 tab 切换 */
@property (nonatomic, strong) NSLayoutConstraint *tableTopNormal;
@property (nonatomic, strong) NSLayoutConstraint *tableTopSearch;
/* 11142662：榜单数据 */
@property (nonatomic, strong) NSArray<NSDictionary *> *topLists;

- (void)reloadSheets;
@end


@interface MFCarPlayWindowTracksVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) MFCarPlaySceneDelegate *carPlayDelegate;
@property (nonatomic, copy) NSString *sheetId;
@property (nonatomic, copy) NSString *sheetTitle;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *tracks;
@end

/* 歌单列表页（三模块之一） */


/* 搜索页（三模块之一）：UITextField + 结果表 */


/* 11142662：榜单曲目页（等 JS 回传） */
@interface MFCarPlayWindowTopListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) MFCarPlaySceneDelegate *carPlayDelegate;
@property (nonatomic, copy) NSString *listId;
@property (nonatomic, copy) NSString *listTitle;
@property (nonatomic, copy) NSString *pluginHash;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *tracks;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

/* 11142650：播放页（静态版）—— 点歌后跳到这里 */
@interface MFCarPlayWindowNowPlayingVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) MFCarPlaySceneDelegate *carPlayDelegate;
@property (nonatomic, strong) NSDictionary *nowPlaying;
/* 11142653：封面背景层（模糊 + 半透明黑遮罩，避免纯黑单调） */
@property (nonatomic, strong) UIImageView *backgroundImageView;
/* 子控件 */
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *timeLabel;
/* 11142655：实时播放状态（JS 回传） */
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIButton *playPauseButton;

/* ============ 11142657：歌词 ============ */
@property (nonatomic, strong) UITableView *lyricTable;      /* 歌词列表 */
@property (nonatomic, strong) NSArray *lyricLines;          /* @[{time, lrc, translation}] */
@property (nonatomic, assign) NSInteger currentLyricIndex;  /* 当前高亮行，-1 表示未初始化 */
@property (nonatomic, assign) BOOL showingLyric;            /* 是否在歌词模式 */
@property (nonatomic, assign) double currentProgress;       /* 当前播放秒数（JS 推送） */
/* 11142669：已渲染的曲名，用于检测切歌 */
@property (nonatomic, copy) NSString *lastRenderedTitle;
/*
 * 11142669：原生轮询定时器。
 *
 * 为什么需要：
 *   日志证实 JS 的 500ms ticker 从未推送过状态
 *   （BRIDGE state: 零次出现）。
 *   所以原生自己按 1 秒轮询 MMKV，至少进度条能动。
 *
 * 这不能替代 JS 推送（拿不到 isPlaying/repeat/quality），
 * 但能保证进度条和时间文字是活的。
 */
@property (nonatomic, strong) NSTimer *progressPollTimer;
/* 11142671：最后一次 JS 推送状态的时间，用于让轮询避让 */
@property (nonatomic, assign) NSTimeInterval lastJSStateTime;

/* ============ 11142661：爱心 / 循环 / 音质 ============ */
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIButton *repeatButton;
/* 11142673：qualityButton 已移除（用户要求，音质切换价值低） */
@end


@implementation MFCarPlayWindowRootVC

/*
 * ============ 11142652：横向 tab 主界面 ============
 *
 * 用户指定设计（对照截图）：
 *
 *   ┌─────────────────────────────────────────┐
 *   │  歌曲列表      搜索      最近播放        │  <- 横向 tab，选中高亮蓝
 *   ├─────────────────────────────────────────┤
 *   │  [封面] 歌单名                      >   │  <- 内容区
 *   │  [封面] 歌单名                      >   │
 *   │  [封面] 歌单名                      >   │
 *   └─────────────────────────────────────────┘
 *
 * 三个 tab 各自的内容：
 *   0 歌曲列表 -> 直接列出所有歌单（封面缩略图 + 标题 + 曲目数 + 箭头）
 *   1 搜索     -> 顶部搜索框（唤起车机键盘）+ 结果列表
 *   2 最近播放 -> 最近播放的曲目（封面 + 歌名 + 歌手）
 */
- (void)viewDidLoad {
    [super viewDidLoad];

    /* 11142666：先算缩放系数（车机屏幕尺寸各异） */
    CGFloat sc = MFScaleForSize(self.view.bounds.size);
    MFCarPlayLogBoth(@"ROOT layout: screen=%.0fx%.0f scale=%.2f",
          self.view.bounds.size.width, self.view.bounds.size.height, sc);

    self.view.backgroundColor = MFCarPlayBackgroundColor();
    self.selectedTab = 0;

    /* ---- 顶部横向 tab ---- */
    self.tabBar = [[UIView alloc] init];
    self.tabBar.backgroundColor = MFCarPlayBackgroundColor();
    self.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tabBar];

    /*
     * 11142662：四个 tab（用户指定顺序）
     *   0 歌曲列表  1 搜索  2 榜单  3 最近播放
     */
    NSArray<NSString *> *titles = @[@"歌曲列表", @"搜索", @"榜单", @"最近播放"];
    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:0];
        [b setTitle:titles[i] forState:0];
        b.titleLabel.font = MFFont(22.0);
        b.tag = (NSInteger)i;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b addTarget:self action:@selector(onTabTap:) forControlEvents:64];
        [self.tabBar addSubview:b];
        [btns addObject:b];
    }
    self.tabButtons = btns;

    /* ---- 内容表 ---- */
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = MFS(76.0);
    /* 表格透明，让卡片间隙透出页面背景 */
    self.table.backgroundColor = [UIColor clearColor];
    /*
     * 11142659：不要分隔线 —— 改用卡片间隙（见 MFCarPlayListCell）。
     * 分隔线 + 卡片圆角会显得脏。
     */
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    /*
     * 11142669：去掉右侧滚动指示器（用户截图里的 ^ v 箭头）。
     * 车机上滚动条没用，反而碍眼。
     */
    self.table.showsVerticalScrollIndicator = NO;
    self.table.showsHorizontalScrollIndicator = NO;
    /* 11142671：indicatorStyle 也设 None，彻底去掉右侧箭头 */
    self.table.indicatorStyle = 0;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];

    /* ---- 搜索框（仅 tab=1 显示）---- */
    /*
     * 11142653：搜索框修复。
     *
     * 原问题（用户反馈图六）：hidden=YES 后 AutoLayout 让控件塌缩，
     * 即使切到搜索 tab 也点不到、看不到、唤不起键盘。
     *
     * 改法：
     *   - 不用 hidden，改用 alpha + userInteractionEnabled 控制
     *   - 始终占位（约束不变），只是视觉上隐藏
     *   - 加白色边框，让用户能看清输入区域
     */
    self.searchField = [[UITextField alloc] init];
    self.searchField.placeholder = @"输入歌名或歌手";
    self.searchField.textColor = [UIColor whiteColor];
    self.searchField.backgroundColor = MFCarPlayCardColor();
    self.searchField.layer.borderColor = [UIColor whiteColor].CGColor;
    self.searchField.layer.borderWidth = 1.0;
    self.searchField.layer.cornerRadius = MFS(8.0);   /* 11142674: 随屏幕缩放 */
    /*
     * 11142668：搜索框内左边距。
     *
     * 用户反馈「输入歌名或歌手」贴框边太紧。
     * 简化方案：把 placeholder 本身加个前缀空格 + 加大左边距约束。
     */
    self.searchField.placeholder = @"   输入歌名或歌手";

    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.alpha = 0.0;
    self.searchField.userInteractionEnabled = NO;
    self.searchField.delegate = self;
    self.searchField.returnKeyType = 0;
    [self.searchField addTarget:self
                         action:@selector(textFieldDidChange:)
               forControlEvents:8192];   /* UIControlEventEditingChanged */
    [self.view addSubview:self.searchField];

    /* ---- 布局 ---- */
    UIView *v = self.view;
    NSMutableArray *cons = [NSMutableArray array];

    /* tabBar 顶部，高度 56 */
    [cons addObject:[self.tabBar.topAnchor constraintEqualToAnchor:v.topAnchor constant:6]];
    [cons addObject:[self.tabBar.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16]];
    [cons addObject:[self.tabBar.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16]];
    [cons addObject:[self.tabBar.heightAnchor constraintEqualToConstant:MFS(56)]];

    /* 三个 tab 按钮等分横向 */
    UIButton *prev = nil;
    for (UIButton *b in btns) {
        [cons addObject:[b.topAnchor constraintEqualToAnchor:self.tabBar.topAnchor]];
        [cons addObject:[b.bottomAnchor constraintEqualToAnchor:self.tabBar.bottomAnchor]];
        if (prev) {
            [cons addObject:[b.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor]];
            [cons addObject:[b.widthAnchor constraintEqualToAnchor:prev.widthAnchor]];
        } else {
            [cons addObject:[b.leadingAnchor constraintEqualToAnchor:self.tabBar.leadingAnchor]];
        }
        prev = b;
    }
    if (prev) {
        [cons addObject:[prev.trailingAnchor constraintEqualToAnchor:self.tabBar.trailingAnchor]];
    }

    /*
     * 11142654：搜索框布局修复。
     *
     * 用户反馈（图三）：搜索框超出屏幕右侧、点不到、唤不起键盘。
     *
     * 根因推测：
     *   之前 searchField 的 trailing 约束挂在 v.trailingAnchor 上，
     *   但 UITextField 自身有默认内边距，加上车机屏幕宽 1066 且字体放大，
     *   实际渲染超出可视区。
     *
     * 修法：
     *   1) 搜索框左边距 60（给返回图标位）、右边距 100（给「取消」位，对齐图一）
     *   2) 高度 48，垂直居中于顶部区域
     *   3) 表格始终从 tabBar 下方开始，搜索框浮在表格之上
     *      （这样切换 tab 不改变表格位置，避免布局抖动）
     */
    [cons addObject:[self.searchField.topAnchor constraintEqualToAnchor:self.tabBar.bottomAnchor constant:6]];
    [cons addObject:[self.searchField.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:60]];
    [cons addObject:[self.searchField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-100]];
    [cons addObject:[self.searchField.heightAnchor constraintEqualToConstant:MFS(48)]];

    /*
     * 11142669：表格位置按 tab 动态调整。
     *
     * 用户反馈「搜索框会挡住歌曲列表」。
     * 现在默认在 tabBar 下方，搜索 tab 时下移到搜索框下方。
     * 用两个约束 + 优先级切换实现。
     */
    self.tableTopNormal =
        [self.table.topAnchor constraintEqualToAnchor:self.tabBar.bottomAnchor constant:8];
    self.tableTopSearch =
        [self.table.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:8];
    self.tableTopNormal.active = YES;
    self.tableTopSearch.active = NO;
    [cons addObject:self.tableTopNormal];
    [cons addObject:[self.table.bottomAnchor constraintEqualToAnchor:v.bottomAnchor]];
    [cons addObject:[self.table.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16]];
    [cons addObject:[self.table.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16]];

    [NSLayoutConstraint activateConstraints:cons];

    [self refreshTabAppearance];
    [self reloadSheets];

    /*
     * 11142669：点空白处收起键盘。
     *
     * 用户要求「点击空白位置键盘应该消失」。
     * 给整个 view 加点击手势，点非控件区域时收键盘。
     * cancelsTouchesInView = NO 保证不干扰按钮和表格点击。
     */
    UITapGestureRecognizer *bgTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBackgroundTap)];
    bgTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:bgTap];

    /* 11142655：监听 JS 回传的搜索结果 */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSearchResults:)
                                                 name:@"MFCarPlaySearchResults"
                                               object:nil];

    /* 11142662：榜单推送监听 */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleTopLists:)
                                                 name:@"MFCarPlayTopLists"
                                               object:nil];

    MFCarPlayLogBoth(@"ROOT ready: 3 tabs + JS bridge listeners, selected=0");
}

/* 刷新 tab 高亮：选中=蓝色，未选=灰色 */
#pragma mark - 搜索

/* 键盘 return 键 -> 执行搜索 */
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self doSearch:textField.text];
    [textField resignFirstResponder];
    return YES;
}

/* 输入变化也实时搜（车机键盘点击方便） */
- (void)textFieldDidChange:(UITextField *)textField {
    /*
     * 只在长度 >= 1 时搜，避免清空时无用遍历。
     * 注意：这个方法需要 addTarget:forControlEvents: 注册，
     * 见 viewDidLoad 里的 UIControlEventEditingChanged。
     */
    [self doSearch:textField.text];
}

- (void)doSearch:(NSString *)query {
    /*
     * ============ 11142667：搜索防抖 ============
     *
     * 用户反馈「点键盘就闪退」。
     *
     * 根因有两层：
     *   1) 每次按键都同步 reloadData，UITableView 在极短时间内
     *      反复销毁重建 cell，内部状态容易不一致 -> 崩溃
     *   2) 销毁的 cell 上还有未完成的异步封面回调 -> 访问已释放对象
     *
     * 修法：250ms 防抖。用户连续打字时只在停顿后搜一次，
     *      reloadData 次数从「每个字符一次」降到「每个词一次」。
     */
    if (![query isKindOfClass:[NSString class]]) {
        return;
    }

    /* 取消上一次待执行的搜索 */
    if (self.searchDebounceTimer) {
        [self.searchDebounceTimer invalidate];
        self.searchDebounceTimer = nil;
    }

    /* 空输入立即清空，不用等 */
    if (query.length == 0) {
        self.results = @[];
        MFSafeReload(self.table, @"ROOT");
        return;
    }

    /* 延迟 250ms 执行真正的搜索 */
    __weak __typeof(self) weakSelf = self;
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                                repeats:NO
                                                                  block:^(NSTimer *timer) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (s) {
            [s performSearch:query];
        }
    }];
}

/* 11142667：真正的搜索逻辑（防抖后调用） */
- (void)performSearch:(NSString *)query {
    if (![query isKindOfClass:[NSString class]] || query.length == 0) {
        return;
    }
    self.currentQuery = query;

    NSArray<NSDictionary *> *local = [self.carPlayDelegate searchForCarPlay:query] ?: @[];
    self.results = local;
    MFSafeReload(self.table, @"ROOT");

    BOOL jsReady = [MFCarPlayBridge isJSReady];
    MFCarPlayLogBoth(@"ROOT search '%@' -> local=%lu jsReady=%d",
          query, (unsigned long)local.count, (int)jsReady);

    if (jsReady) {
        [MFCarPlayBridge emitSearch:query];
    } else {
        MFCarPlayLogBoth(@"ROOT search: JS not ready, local results only");
    }
}


/*
 * 11142655：JS 回传搜索结果。
 * 校验 query 是否还是当前搜索词，避免旧结果覆盖新输入。
 */
- (void)handleSearchResults:(NSNotification *)note {
    NSString *query = note.userInfo[@"query"];
    NSArray *results = note.userInfo[@"results"];

    if (![query isKindOfClass:[NSString class]] ||
        ![results isKindOfClass:[NSArray class]]) {
        return;
    }
    if (self.selectedTab != 1) {
        return;   /* 已经切走，不刷 */
    }
    if (![query isEqualToString:self.currentQuery ?: @""]) {
        MFCarPlayLogBoth(@"ROOT search: stale result for '%@' (current '%@'), ignored",
              query, self.currentQuery ?: @"");
        return;
    }

    self.results = results;
    MFSafeReload(self.table, @"ROOT");
    MFCarPlayLogBoth(@"ROOT search: JS returned %lu results for '%@'",
          (unsigned long)results.count, query);
}

- (void)refreshTabAppearance {
    for (UIButton *b in self.tabButtons) {
        BOOL sel = (b.tag == self.selectedTab);
        UIColor *c = sel ? MFCarPlayAccentColor() : [UIColor whiteColor];
        [b setTitleColor:c forState:0];
        b.titleLabel.font = [UIFont systemFontOfSize:(sel ? 24.0 : 21.0)];
    }
}

- (void)onTabTap:(UIButton *)sender {
    NSInteger tag = sender.tag;

    /*
     * 11142668：边界检查。
     * tag 来自按钮，理论上 0..3，但防御性检查避免越界。
     */
    if (tag < 0 || tag > 3) {
        MFCarPlayLogBoth(@"ROOT tab IGNORED: bad tag=%ld", (long)tag);
        return;
    }

    if (tag == self.selectedTab) {
        return;
    }
    self.selectedTab = tag;
    [self refreshTabAppearance];

    /*
     * 搜索框只在 tab=1 显示（用 alpha 避免布局塌陷）。
     * 11142654：切到搜索 tab 自动唤起键盘（用户选定方案 A）。
     */
    BOOL showSearch = (tag == 1);
    self.searchField.alpha = showSearch ? 1.0 : 0.0;
    self.searchField.userInteractionEnabled = showSearch;

    if (showSearch) {
        [self.view bringSubviewToFront:self.searchField];
        /* 11142669：表格下移到搜索框下方，避免被遮住 */
        self.tableTopNormal.active = NO;
        self.tableTopSearch.active = YES;
        [self activateSearchKeyboard];
    } else {
        [self.searchField resignFirstResponder];
        /* 11142669：表格回到顶部 */
        self.tableTopSearch.active = NO;
        self.tableTopNormal.active = YES;
        /* 切走时隐藏自绘键盘 */
        if (self.keyboardView) {
            self.keyboardView.hidden = YES;
        }
    }

    /*
     * 11142662：四 tab 数据切换
     *   0 歌曲列表 -> self.sheets（歌单）
     *   1 搜索     -> self.results
     *   2 榜单     -> self.topLists（JS 推送）
     *   3 最近播放 -> self.sheets（历史曲目）
     */
    if (tag == 0) {
        self.sheets = [self.carPlayDelegate sheets] ?: @[];
    } else if (tag == 2) {
        /* 榜单：先读缓存，同时请求 JS 刷新 */
        [self reloadTopLists];
        [MFCarPlayBridge emitControl:@"requestTopLists"];
    } else if (tag == 3) {
        self.sheets = [self.carPlayDelegate historyForCarPlay] ?: @[];
    } else {
        self.results = @[];
    }
    MFSafeReload(self.table, @"ROOT");

    MFCarPlayLogBoth(@"ROOT tab -> %ld (0=sheets 1=search 2=toplist 3=history)", (long)tag);
}

/*
 * ============ 11142658：搜索键盘唤起（带诊断）============
 *
 * 用户反馈：点搜索 tab，键盘弹不出来。
 *
 * CarPlay 窗口路径的难点：
 *   键盘（UIKeyboard）挂在 key window 上。CarPlay 场景下
 *   我们的 UIWindow 可能不是 key window（SpringBoard 的窗口才是），
 *   所以 becomeFirstResponder 返回 YES 但键盘不显示。
 *
 * 这里做三件事：
 *   1) 强制我们的窗口成为 key window
 *   2) 三阶段重试唤起（0ms / 150ms / 400ms），应对时序
 *   3) 每步都打日志，便于定位到底卡在哪
 */
/*
 * 11142669：点空白收起键盘。
 * 只隐藏自绘键盘，不改变 tab。
 */
- (void)onBackgroundTap {
    if (self.keyboardView && !self.keyboardView.hidden) {
        self.keyboardView.hidden = YES;
        MFCarPlayLogBoth(@"[KEYBOARD] hidden by bg tap");
    }
}

- (void)activateSearchKeyboard {
    /*
     * ============ 11142658：改用自绘软键盘 ============
     *
     * 日志确证系统键盘走不通：
     *   SEARCH kb: win=yes isKey=0
     *   SEARCH kb: forced makeKeyWindow, now isKey=0    <- 强制失败
     *   SEARCH kb: becomeFirstResponder -> 1 (isFirst=1) <- 控件成功但无键盘
     *
     * 所以不再尝试 becomeFirstResponder，直接在屏幕上画键盘。
     */
    if (!self.keyboardView) {
        MFCarPlayKeyboardView *kb =
            [[MFCarPlayKeyboardView alloc] initWithTargetField:self.searchField];
        kb.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:kb];
        self.keyboardView = kb;

        __weak __typeof(self) weakSelf = self;
        kb.onChange = ^(NSString *text) {
            __strong __typeof(weakSelf) s = weakSelf;
            if (s) {
                [s doSearch:text];
            }
        };

        /* 键盘贴在底部 */
        [NSLayoutConstraint activateConstraints:@[
            [kb.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
            [kb.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
            [kb.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
            [kb.heightAnchor constraintEqualToConstant:MFS(230)],
        ]];
        [self.view bringSubviewToFront:kb];
    }
    self.keyboardView.hidden = NO;
    [self.view bringSubviewToFront:self.keyboardView];

    /* 搜索时键盘占下半屏，表格上移让位 */
    MFCarPlayLogBoth(@"SEARCH kb: using built-in keyboard (system kb blocked by CarPlay)");
}

/* 11142662：刷新榜单列表（读原生桥缓存） */
- (void)reloadTopLists {
    NSArray *lists = [[MFCarPlayBridge shared] topLists];
    self.topLists = [lists isKindOfClass:[NSArray class]] ? lists : @[];
    MFCarPlayLogBoth(@"ROOT topLists loaded: %lu", (unsigned long)self.topLists.count);
}

/* 11142662：JS 推送榜单列表 */
- (void)handleTopLists:(NSNotification *)note {
    NSArray *lists = note.userInfo[@"lists"];
    if (![lists isKindOfClass:[NSArray class]]) {
        return;
    }
    self.topLists = lists;
    if (self.selectedTab == 2) {
        MFSafeReload(self.table, @"ROOT");
    }
    MFCarPlayLogBoth(@"ROOT topLists updated: %lu", (unsigned long)lists.count);
}

- (void)reloadSheets {
    if (self.selectedTab == 0) {
        self.sheets = [self.carPlayDelegate sheets] ?: @[];
    }
    MFSafeReload(self.table, @"ROOT");
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    /*
     * 11142668：四个 tab 显式映射，和 cellForRow 的数据源严格对应。
     *   0 歌曲列表 -> sheets
     *   1 搜索     -> results
     *   2 榜单     -> topLists
     *   3 最近播放 -> sheets
     *
     * 任何 data 为 nil 都返回 0，避免 UITableView 拿到负数。
     */
    NSInteger n = 0;
    if (self.selectedTab == 0 || self.selectedTab == 3) {
        n = (NSInteger)self.sheets.count;
    } else if (self.selectedTab == 1) {
        n = (NSInteger)self.results.count;
    } else if (self.selectedTab == 2) {
        n = (NSInteger)self.topLists.count;
    }
    return n < 0 ? 0 : n;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    /*
     * ============ 11142664：榜单闪退修复 ============
     *
     * 日志证据：切到榜单 tab 后立刻闪退
     *   02:29:35 ROOT topLists loaded: 0
     *   02:29:35 ROOT tab -> 2 (0=sheets 1=search 2=toplist 3=history)
     *   （之后无任何日志）
     *
     * 根因：topLists 为空时，cellForRow 走到「空 cell」分支，
     * 但那个分支返回的是没有 reuseIdentifier 的全新 cell，
     * 表格在 reload 时会因内部状态不一致抛异常。
     *
     * 修法：
     *   1) 空数据用注册过的 reusable id，避免表格内部混乱
     *   2) data 为 nil 也当空处理
     *   3) row < 0 也防护
     */
    NSArray<NSDictionary *> *data;
    if (self.selectedTab == 1) {
        data = self.results;
    } else if (self.selectedTab == 2) {
        data = self.topLists;
    } else {
        data = self.sheets;
    }
    if (![data isKindOfClass:[NSArray class]]) {
        data = @[];
    }

    /* 越界 / 负数 / 空数据 统一返回一个安全空 cell */
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)data.count) {
        static NSString *emptyId = @"mfcell_empty";
        MFCarPlayListCell *empty = (MFCarPlayListCell *)[tableView dequeueReusableCellWithIdentifier:emptyId];
        if (!empty) {
            empty = [[MFCarPlayListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:emptyId];
        }
        [empty configureWithTitle:@"" subtitle:@"" cover:nil];
        return empty;
    }

    NSDictionary *item = data[(NSUInteger)indexPath.row];
    if (![item isKindOfClass:[NSDictionary class]]) {
        item = @{};
    }

    static NSString *cid = @"mfcell";
    MFCarPlayListCell *cell = (MFCarPlayListCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[MFCarPlayListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:cid];
    }

    NSString *title = [item[@"title"] isKindOfClass:[NSString class]] ? item[@"title"] : @"";
    NSString *sub = @"";

    if (self.selectedTab == 0) {
        /* 歌单：副标题 = 曲目数 */
        id cnt = item[@"count"];
        sub = [cnt isKindOfClass:[NSNumber class]]
            ? [NSString stringWithFormat:@"%@ 首", cnt] : @"";
    } else if (self.selectedTab == 2) {
        /* 11142662：榜单：副标题 = 插件名（平铺后需要区分来源） */
        NSString *pn = [item[@"pluginName"] isKindOfClass:[NSString class]]
            ? item[@"pluginName"] : @"";
        NSString *desc = [item[@"description"] isKindOfClass:[NSString class]]
            ? item[@"description"] : @"";
        if (pn.length > 0 && desc.length > 0) {
            sub = [NSString stringWithFormat:@"%@  ·  %@", pn, desc];
        } else {
            sub = pn.length > 0 ? pn : desc;
        }
    } else {
        /* 搜索/最近播放：副标题 = 歌手 · 专辑 */
        NSString *ar = [item[@"artist"] isKindOfClass:[NSString class]] ? item[@"artist"] : @"";
        NSString *al = [item[@"album"] isKindOfClass:[NSString class]] ? item[@"album"] : @"";
        if (ar.length > 0 && al.length > 0) {
            sub = [NSString stringWithFormat:@"%@ · %@", ar, al];
        } else {
            sub = ar.length > 0 ? ar : al;
        }
    }

    /* 封面：歌单用 coverImg，其余用 artwork */
    NSString *cover = nil;
    if (self.selectedTab == 0 || self.selectedTab == 2) {
        /* 歌单 + 榜单都有 coverImg */
        cover = [item[@"coverImg"] isKindOfClass:[NSString class]] ? item[@"coverImg"] : nil;
    }
    if (cover.length == 0) {
        cover = [item[@"artwork"] isKindOfClass:[NSString class]] ? item[@"artwork"] : nil;
    }

    [cell configureWithTitle:title subtitle:sub cover:cover];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.selectedTab == 0) {
        /* 歌单 -> 曲目 */
        if (indexPath.row >= (NSInteger)self.sheets.count) {
            return;
        }
        NSDictionary *s = self.sheets[(NSUInteger)indexPath.row];
        NSString *sid = s[@"id"] ?: @"";
        NSString *title = s[@"title"] ?: @"未命名歌单";
        MFCarPlayLogBoth(@"ROOT sheets tap row=%ld sheet=%@", (long)indexPath.row, sid);

        MFCarPlayWindowTracksVC *vc = [[MFCarPlayWindowTracksVC alloc] init];
        vc.carPlayDelegate = self.carPlayDelegate;
        vc.sheetId = sid;
        vc.sheetTitle = title;
        vc.tracks = [self.carPlayDelegate tracksForSheet:sid] ?: @[];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    /* 11142662：榜单 tab（2）-> 请求 JS 拉详情 */
    if (self.selectedTab == 2) {
        if (indexPath.row >= (NSInteger)self.topLists.count) {
            return;
        }
        NSDictionary *tl = self.topLists[(NSUInteger)indexPath.row];
        NSString *ph = tl[@"pluginHash"] ?: @"";
        NSString *lid = tl[@"id"] ?: @"";
        NSString *ttl = tl[@"title"] ?: @"";

        MFCarPlayLogBoth(@"ROOT toplist tap row=%ld title=%@ plugin=%@",
              (long)indexPath.row, ttl, ph);

        /* 立刻给个反馈：进曲目页（先空列表，JS 回来再填） */
        MFCarPlayWindowTopListVC *vc = [[MFCarPlayWindowTopListVC alloc] init];
        vc.carPlayDelegate = self.carPlayDelegate;
        vc.listId = lid;
        vc.listTitle = ttl;
        vc.pluginHash = ph;
        [self.navigationController pushViewController:vc animated:YES];

        /* 请求 JS 拉曲目 */
        [MFCarPlayBridge emitTopListDetail:ph listId:lid title:ttl];
        return;
    }

    if (self.selectedTab == 3) {
        /* 最近播放 -> 直接播放 + 跳播放页 */
        if (indexPath.row >= (NSInteger)self.sheets.count) {
            return;
        }
        NSDictionary *tr = self.sheets[(NSUInteger)indexPath.row];
        NSString *tid = tr[@"id"] ?: @"";
        MFCarPlayLogBoth(@"ROOT history tap row=%ld track=%@", (long)indexPath.row, tid);
        [MFCarPlayBridge emitPlayTrack:tid sheetId:@""];

        /* 11142658：用点中的那条数据，不读 MMKV（避免竞态显示旧歌） */
        NSDictionary *picked = self.sheets[(NSUInteger)indexPath.row];
        MFCarPlayWindowNowPlayingVC *np = [[MFCarPlayWindowNowPlayingVC alloc] init];
        np.carPlayDelegate = self.carPlayDelegate;
        np.nowPlaying = MFNowPlayingFromTrack(picked);
        [self.navigationController pushViewController:np animated:YES];
        return;
    }

    /* tab=1 搜索结果 -> 播放 + 跳播放页 */
    if (indexPath.row >= (NSInteger)self.results.count) {
        return;
    }
    NSDictionary *tr = self.results[(NSUInteger)indexPath.row];
    NSString *tid = tr[@"id"] ?: @"";
    NSString *sid = tr[@"sheetId"] ?: @"";
    MFCarPlayLogBoth(@"ROOT search tap row=%ld track=%@", (long)indexPath.row, tid);
    [MFCarPlayBridge emitPlayTrack:tid sheetId:sid];

    /* 11142658：同样用点中的数据 */
    NSDictionary *picked = self.results[(NSUInteger)indexPath.row];
    MFCarPlayWindowNowPlayingVC *np = [[MFCarPlayWindowNowPlayingVC alloc] init];
    np.carPlayDelegate = self.carPlayDelegate;
    np.nowPlaying = MFNowPlayingFromTrack(picked);
    [self.navigationController pushViewController:np animated:YES];
}

/*
 * ============ 11142668：移除通知观察者 ============
 *
 * 严重隐患：之前 RootVC 注册了 2 个通知观察者但从未移除。
 * VC 被 pop/释放后，桥再发通知就会发给野指针 -> 闪退。
 *
 * dealloc 里必须 removeObserver，这是 ObjC 通知机制的铁律。
 */
- (void)dealloc {
    /* 取消待执行的搜索定时器，否则回调会访问已释放的 self */
    if (self.searchDebounceTimer) {
        [self.searchDebounceTimer invalidate];
        self.searchDebounceTimer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    MFCarPlayLogBoth(@"ROOT dealloc");
}

@end

@implementation MFCarPlayWindowTracksVC

/*
 * 11142658：由曲目 dict 直接构造播放页数据（不读 MMKV）。
 *
 * 为什么需要：
 *   点歌后 JS 处理有延迟，此时 MMKV 还没更新，
 *   读 MMKV 会拿到上一首 -> 用户看到「点天后，播放页显示恋人」。
 *
 * 曲目 dict 来自 MFCarPlayNativeTracks，字段：
 *   id / title / artist / album / artwork
 * 时长和进度这里拿不到（MMKV 里的旧值不可信），置 0；
 * JS 回传状态后会自动修正。
 */
- (NSDictionary *)optimisticNowPlayingFromTrack:(NSDictionary *)track {
    if (![track isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return @{
        @"id": track[@"id"] ?: @"",
        @"title": track[@"title"] ?: @"",
        @"artist": track[@"artist"] ?: @"",
        @"album": track[@"album"] ?: @"",
        @"artwork": track[@"artwork"] ?: @"",
        @"platform": track[@"platform"] ?: @"",
        @"duration": @(0),
        @"progress": @(0),
        @"queueCount": @(0),
    };
}


- (void)viewDidLoad {
    [super viewDidLoad];

    /* 11142666：算缩放系数 */
    MFScaleForSize(self.view.bounds.size);

    self.title = self.sheetTitle ?: @"曲目";
    self.view.backgroundColor = MFCarPlayBackgroundColor();

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = MFS(76.0);
    /* 表格透明，让卡片间隙透出页面背景 */
    self.table.backgroundColor = [UIColor clearColor];
    /*
     * 11142659：不要分隔线 —— 改用卡片间隙（见 MFCarPlayListCell）。
     * 分隔线 + 卡片圆角会显得脏。
     */
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    /*
     * 11142669：去掉右侧滚动指示器（用户截图里的 ^ v 箭头）。
     * 车机上滚动条没用，反而碍眼。
     */
    self.table.showsVerticalScrollIndicator = NO;
    self.table.showsHorizontalScrollIndicator = NO;
    /* 11142671：indicatorStyle 也设 None，彻底去掉右侧箭头 */
    self.table.indicatorStyle = 0;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];

    [NSLayoutConstraint activateConstraints:@[
        /* 顶部留 56 给返回按钮 + 居中标题 */
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:64],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    MFCarPlayLogBoth(@"TRACKS VC: sheet=%@ title=%@ tracks=%lu",
          self.sheetId, self.sheetTitle, (unsigned long)self.tracks.count);

    /* 11142666：标题和返回按钮放最后加，保证在最上层 */
    MFAddTopTitle(self, self.sheetTitle);
    MFAddBackButton(self);
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"mftrack";
    MFCarPlayListCell *cell = (MFCarPlayListCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[MFCarPlayListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:cid];
    }
    if (indexPath.row < (NSInteger)self.tracks.count) {
        NSDictionary *tr = self.tracks[(NSUInteger)indexPath.row];
        NSString *tt = [tr[@"title"] isKindOfClass:[NSString class]] ? tr[@"title"] : @"";
        NSString *ar = [tr[@"artist"] isKindOfClass:[NSString class]] ? tr[@"artist"] : @"";
        NSString *al = [tr[@"album"] isKindOfClass:[NSString class]] ? tr[@"album"] : @"";
        NSString *sub = @"";
        if (ar.length > 0 && al.length > 0) {
            sub = [NSString stringWithFormat:@"%@ · %@", ar, al];
        } else {
            sub = ar.length > 0 ? ar : al;
        }
        NSString *cover = [tr[@"artwork"] isKindOfClass:[NSString class]] ? tr[@"artwork"] : nil;
        [cell configureWithTitle:tt subtitle:sub cover:cover];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.tracks.count) {
        return;
    }
    NSDictionary *tr = self.tracks[(NSUInteger)indexPath.row];
    NSString *tid = [tr[@"id"] isKindOfClass:[NSString class]] ? tr[@"id"] : @"";
    MFCarPlayLogBoth(@"TRACKS tap row=%ld track=%@ sheet=%@",
          (long)indexPath.row, tid, self.sheetId);

    /*
     * 通知 JS 播放。RN 若未启动（车机冷启动常见），事件会先进队列，
     * 主 App 打开后 carPlayJSReady 再冲刷。
     */
    [MFCarPlayBridge emitPlayTrack:tid sheetId:self.sheetId];
    MFCarPlayLogBoth(@"emitted CarPlayPlayTrack track=%@", tid);

    /*
     * ============ 11142658：修复「选的歌和播放的不一致」============
     *
     * 原 bug（日志可证）：
     *   19:25:21 点了「天后」
     *   19:25:21 nowPlaying: 恋人 / 李荣浩   <- 还是上一首
     *
     * 原因：emitPlayTrack 之后立刻读 MMKV，但 JS 还没处理完事件，
     *      MMKV 里存的是上一首 -> 播放页显示错歌。
     *
     * 修法：点歌这一刻我们手里就有这首歌的完整数据，
     *      直接用它构造播放页，完全不读 MMKV。
     *      JS 回传最新状态后（handleNowPlayingState）会再修正。
     */
    /* 11142668：复用上面已取的 tr，避免重复下标访问 */
    MFCarPlayWindowNowPlayingVC *np = [[MFCarPlayWindowNowPlayingVC alloc] init];
    np.carPlayDelegate = self.carPlayDelegate;
    np.nowPlaying = [self optimisticNowPlayingFromTrack:tr];
    [self.navigationController pushViewController:np animated:YES];
}

- (void)onBack {
    MFCarPlayLogBoth(@"%@ tap BACK", @"MFCarPlayWindowTracksVC");
    [self.navigationController popViewControllerAnimated:YES];
}

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
     * _rootExhausted 自动恢复的节流状态（11142630）。
     *   _resetCount  本 controller 内已 reset 次数，上限 kMFMaxResets
     *   _lastResetAt 上次 reset 时刻，用于 3s 最小间隔
     * 两者在 didConnect / rebind 换 controller 时清零。
     */
    NSUInteger _resetCount;
    NSTimeInterval _lastResetAt;
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
    /* topTemplate 探针只打一次，避免 watchdog 每轮刷屏 */
    BOOL _topProbeLogged;
    /* 缓存最近一次准备好的 sections，供 root 被接受后补推 */
    NSArray<CPListSection *> *_lastSections;
    /*
     * 数据源快照：currentRootSections 每次构建时写入。
     * 指纹计算和上屏探针都从这里取，绝不读 CPListSection.items /
     * CPListItem.text（非公开 API，读了是 unrecognized selector）。
     */
    NSArray *_lastSheetsSnapshot;
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

    /*
     * 上屏内容证据（评审 ②）。
     *
     * 为什么需要：
     *   "one-shot armed (sections=K)" 和 "refresh: data ready sections=K"
     *   只能证明**我自己读到的数据两次一致**，证明不了模板真的把内容送到了车机。
     *
     * ============ 只用确定公开的 API ============
     *   sectionCount  —— CPListTemplate 的公开只读属性（Apple 文档有），可以读。
     *   sections / items / text / detailText —— **不是公开 API**。
     *     之前我在本文件的 clang 桩里顺手声明了它们，于是 clang 放行，
     *     但真机上会是 unrecognized selector 直接 crash —— 比 KVC 抛异常更隐蔽，
     *     因为编译期完全静默。现在桩里已把这些声明删掉，编译器会替我们拦住。
     *
     *   条目不从模板侧反查，改从**数据侧** _lastSections 统计。
     *   语义反而更清楚：
     *     sectionCount = 模板当前持有几组
     *     dataItems    = 数据侧一共几条
     *   两者对照比"模板侧 section 数 vs 模板侧 item 数"更有诊断价值。
     *
     * 判据边界（含 M == 0，别漏最后一行）：
     *   S == 0                     -> 不该发生，currentRootSections 返回了空数组，真 bug
     *   S == 1, I == 1, M > 0      -> 数据没进 items，查 sheetItems 构建/过滤
     *   S == 1, I == M (>0)        -> 内容正确，车机还空就是渲染端/框架问题
     *   S == 1, I == 1, M == 0     -> 空态正常（"暂无歌单"/"正在加载"），不是 bug
     *
     * 条件用 isList 而不是 isSameObject：
     *   rearm 会把 _rootList 换成新对象，若首发模板的 didAppear 在 rearm 之后
     *   才到，isSameObject 为 0 —— 探针整段跳过，而这恰恰是最需要日志的时刻。
     *   sameAsRoot 仍打日志里，能看出是不是 rearm 后的新模板。
     */
    if (isList) {
        CPListTemplate *probe = (CPListTemplate *)template;
        /*
         * sectionCount 也是"我不能百分百确认是公开 API"的属性 ——
         * 和 isActive 一样，曾把我坑过一次（编译期静默、运行时崩）。
         * 这里用 respondsToSelector 探测后再读，读不到就记 -1。
         */
        /*
         * 用 objc_msgSend 读，彻底不依赖头文件里有没有这个属性声明。
         * 属性访问语法 probe.sectionCount 在编译期就需要声明；
         * 而真实 SDK 有没有 sectionCount 我无法百分百确认，
         * 所以走运行时消息发送 + respondsToSelector 双重保护：
         *   - 没有该方法 -> hasSectionCount=0，不调用，不崩
         *   - 有该方法   -> 按 NSUInteger 返回值读取
         */
        SEL scSel = NSSelectorFromString(@"sectionCount");
        BOOL hasSectionCount = [probe respondsToSelector:scSel];
        NSUInteger secCount = 0;
        if (hasSectionCount) {
            secCount = ((NSUInteger (*)(id, SEL))objc_msgSend)(probe, scSel);
        }
        NSUInteger dataSheets = [(NSArray *)(_lastSheetsSnapshot ?: @[]) count];

        /*
         * 把判定结果并进同一条日志，而不是放在 if (secCount == 0) 的独立分支里。
         *
         * 原因：11142629 的出包验证发现，独立的
         *   if (secCount == 0) { MFCarPlayLogBoth(@"WARN: ... sectionCount==0 ..."); }
         * 整段被编译器优化掉了 —— 二进制里连一个字节都搜不到。
         * （sectionCount 是 NSUInteger，优化器在某些优化级别下把该比较判为恒假，
         *  连带把字符串常量一起丢弃。）
         *
         * 后果很实际：车机真出问题时，恰好少了这条最该看的告警。
         * 现在改成把状态编码进一条**必定执行**的日志里，字符串不会再被丢。
         */
        const char *verdict = (!hasSectionCount) ? "NO_SECTIONCOUNT_API"
                            : (secCount == 0) ? "EMPTY_SECTIONS_BUG"
                            : (dataSheets == 0) ? "EMPTY_DATA"
                            : "OK";
        MFCarPlayLogBoth(@"ON-SCREEN CONTENT: sectionCount=%lu hasAPI=%d dataSheets=%lu "
                         @"appliedBefore=%d sameAsRoot=%d verdict=%s",
              (unsigned long)secCount, hasSectionCount, (unsigned long)dataSheets,
              _rootApplied, isSameObject, verdict);
    }

    if (isList) {
        BOOL wasApplied = _rootApplied;
        _rootApplied = YES;
        _rootInstallInFlight = NO;
        _rearmPending = NO;
        _templateReady = YES;
        if (!wasApplied) {
            /*
             * 评审要求的诊断行：路径 B 下能直接看出
             * refreshRootSections 有没有被调用、是否会被指纹闸门挡住。
             *
             *   hasFingerprint=0 -> 闸门放行，一定会推送
             *   hasFingerprint=1 -> 与某次推送内容相同，会被 skip
             *
             * 空模板方案里 _lastPushedFingerprint 已置 nil，
             * 所以这里应当恒为 0。
             */
            MFCarPlayLogBoth(@"ROOT TEMPLATE VISIBLE -> applied=1, about to refresh "
                             @"(wasApplied=%d hasFingerprint=%d rootList=%p)",
                  wasApplied,
                  (_lastPushedFingerprint != nil),
                  (__bridge void *)_rootList);
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
    /* 换 controller / 重置状态：reset 节流额度恢复 */
    _resetCount = 0;
    _lastResetAt = 0;
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
        /* 换 controller / 重置状态：reset 节流额度恢复 */
        _resetCount = 0;
        _lastResetAt = 0;
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
    /*
     * ============ 11142631：在模板提交前声明音频类别 ============
     *
     * 依据：CarPlay 的**模板通道**与**音频通道**是两套独立 XPC，
     * 但 carplayd 在决定是否接受模板提交时，可能参考 App 是否已声明
     * 自己是一个完整的音频 App。
     *
     * 11142630 日志里音频确实能出声（JS 侧 track-player 建了会话），
     * 但那发生在 RN 启动之后 —— 而 CarPlay 冷启动时 RN 根本没起来
     * （bridge init / carPlayJSReady 零出现），所以**在 didConnect 这个
     * 时刻，进程内还没有任何 AVAudioSession 配置**。
     *
     * 这里补一次幂等的类别声明，让 carplayd 在模板提交之前就能看到
     * "这是一个 playback 类音频 App"。失败不影响主流程（有 @try 兜住）。
     */
    /*
     * ============ 11142633：修 OSStatus -50 ============
     *
     * 11142632 真机日志：
     *   AVAudioSession setCategory(Playback) ok=0 err=OSStatus -50
     *
     * -50 是 paramErr。原因是 AVAudioSessionCategoryOptionAllowBluetooth
     * （HFP）**只对 PlayAndRecord / Record 合法**，Playback 类别下传它直接
     * 参数错误。Playback 要走 A2DP，因此正确选项是 AllowBluetoothA2DP。
     *
     * 也就是说：11142632 这一版，整个 CarPlay 会话里音频类别**从未设置成功**。
     *
     * 为什么这条重要：CarPlay 的模板通道与音频通道虽独立，但 App 必须被系统
     * 认定为完整的音频 App。参考实现（missuo/kumone）在 didConnect 第一件事
     * 就是初始化 PlayerService —— 注释原文是
     *   "Force PlayerService to initialize (sets up the audio session and remote commands)"
     * 即它确实配置了会话，只是封装在服务内部。
     *
     * 本次改动：
     *   1) 选项改为 AllowBluetoothA2DP（Playback 合法）
     *   2) 补 setActive:YES —— 只设 category 不激活，会话仍是未就绪状态
     *   3) 回读 category / isActive 打进日志，便于确认真的生效
     */
    /*
     * ============ 11142633：音频会话必须真正配置成功 ============
     *
     * 11142632 真机日志：
     *   AVAudioSession setCategory(Playback) ok=0 err=OSStatus -50
     *
     * -50 = paramErr。原因：AVAudioSessionCategoryOptionAllowBluetooth（HFP）
     * **只对 PlayAndRecord / Record 合法**，在 Playback 类别下传它直接参数错误。
     * 也就是说 11142632 这一版，整个 CarPlay 会话里音频类别从未生效。
     *
     * 为什么这条可能是根因：CarPlay 的模板通道与音频通道虽独立，
     * 但系统要求音频 App 必须处于"可播放"状态。参考实现
     * （missuo/kumone）在 didConnect 第一件事就是
     *     _ = PlayerService.shared
     * 注释原文：Force PlayerService to initialize
     *           (sets up the audio session and remote commands)
     * 即它确实在模板提交前把会话配置好了，只是封装在服务内部。
     *
     * 本实现三级降级，保证"至少有一级成功"，并把每一级结果都打进日志：
     *   1) Playback + AllowBluetoothA2DP  —— 无线 CarPlay 走 A2DP，首选
     *   2) Playback + 无选项               —— 最保守，几乎必定成功
     *   3) 只 setActive:YES                —— 类别已在别处设好时兜底
     * 这样下一版日志无论看到哪一级成功，都能确定音频层状态。
     */
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        BOOL catOK = NO;
        NSString *usedOptions = @"(none)";

        catOK = [session setCategory:AVAudioSessionCategoryPlayback
                         withOptions:AVAudioSessionCategoryOptionAllowBluetoothA2DP
                               error:&err];
        if (catOK) {
            usedOptions = @"AllowBluetoothA2DP";
        } else {
            MFCarPlayLogBoth(@"AVAudioSession step1 (Playback+A2DP) FAILED err=%@ (%ld)",
                  err.localizedDescription ?: @"(nil)", (long)err.code);
            err = nil;
            catOK = [session setCategory:AVAudioSessionCategoryPlayback
                             withOptions:0
                                   error:&err];
            if (catOK) {
                usedOptions = @"none";
            } else {
                MFCarPlayLogBoth(@"AVAudioSession step2 (Playback plain) FAILED err=%@ (%ld)",
                      err.localizedDescription ?: @"(nil)", (long)err.code);
                err = nil;
            }
        }

        NSError *actErr = nil;
        BOOL actOK = [session setActive:YES withOptions:0 error:&actErr];
        if (!actOK) {
            MFCarPlayLogBoth(@"AVAudioSession setActive FAILED err=%@ (%ld)",
                  actErr.localizedDescription ?: @"(nil)", (long)actErr.code);
        }

        /*
         * 回读 category（公开只读属性）。
         *
         * 注意：**不要读 isActive** —— AVAudioSession 没有这个公开属性，
         * 11142633 的构建就是因为它报
         *   error: property 'isActive' not found on object of type 'AVAudioSession *'
         * 是否激活只能看 setActive: 的返回值（即上面的 actOK）。
         * 这是第二次踩"桩里凭猜测加属性"的坑，已在桩里同步删除该声明。
         */
        MFCarPlayLogBoth(@"AVAudioSession final: catOK=%d opts=%@ actOK=%d "
                         @"| readback category=%@ (before root install)",
              catOK, usedOptions, actOK,
              session.category ?: @"(nil)");
    } @catch (NSException *e) {
        MFCarPlayLogBoth(@"AVAudioSession setup threw: %@", e.reason);
    }

    /*
     * ============ 11142633：尝试配置 CPNowPlayingTemplate（防御式） ============
     *
     * 依据（参考实现 missuo/kumone）：它在 didConnect 里、
     * setRootTemplate 之前先取 CPNowPlayingTemplate.shared 并设置开关。
     *
     * ============ 为什么不直接 [CPNowPlayingTemplate sharedTemplate] ============
     *   Swift 里写的是 .shared，但 Swift 的导入规则无法区分 ObjC 侧到底是
     *       + (instancetype)sharedTemplate;
     *   还是
     *       + (instancetype)sharedInstance;
     *   两者在 Swift 都显示为 .shared。kumone 全部用 Swift 写，ObjC 文件里
     *   没有 CarPlay 调用，无法反推；本机又没有 iOS SDK 可查头文件。
     *
     *   名写错 = unrecognized selector = 直接闪退，比现在的静默失败更糟。
     *   所以这里**不硬写任何一个名字**：
     *     1) 用 respondsToSelector 逐个候选择器探测类方法是否存在
     *     2) 命中哪个用哪个，并把命中的名字打进日志
     *     3) 两个都不存在就只记一条日志，绝不调用 —— 保证不崩
     *
     * 这一段的价值：下一版日志会直接告诉我们真实选择器是哪个。
     *   "CPNowPlayingTemplate factory found: sharedTemplate"  -> 就是它
     *   "CPNowPlayingTemplate factory found: sharedInstance"  -> 才知道是它
     *   "both candidates missing"                             -> 两个都不是，另找
     */
    @try {
        Class npClass = NSClassFromString(@"CPNowPlayingTemplate");
        if (!npClass) {
            MFCarPlayLogBoth(@"CPNowPlayingTemplate class not found at runtime");
        } else {
            id np = nil;
            NSString *usedSel = nil;

            /* __unsafe_unretained 防止 ARC 对未知返回值做 retain/release 出错 */
            SEL selTemplate = NSSelectorFromString(@"sharedTemplate");
            SEL selInstance = NSSelectorFromString(@"sharedInstance");
            SEL selShared   = NSSelectorFromString(@"shared");

            if ([npClass respondsToSelector:selTemplate]) {
                usedSel = @"sharedTemplate";
                np = ((id (*)(id, SEL))objc_msgSend)(npClass, selTemplate);
            } else if ([npClass respondsToSelector:selInstance]) {
                usedSel = @"sharedInstance";
                np = ((id (*)(id, SEL))objc_msgSend)(npClass, selInstance);
            } else if ([npClass respondsToSelector:selShared]) {
                usedSel = @"shared";
                np = ((id (*)(id, SEL))objc_msgSend)(npClass, selShared);
            }

            if (usedSel && np) {
                MFCarPlayLogBoth(@"CPNowPlayingTemplate factory found: %@ (instance=%p)",
                      usedSel, np);

                /*
                 * 开关是 BOOL 参数，必须用函数指针调用，
                 * 不能 performSelector:withObject:（那要求对象参数）。
                 */
                SEL upNext = NSSelectorFromString(@"setUpNextButtonEnabled:");
                if ([np respondsToSelector:upNext]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(np, upNext, YES);
                }
                SEL albumArtist = NSSelectorFromString(@"setAlbumArtistButtonEnabled:");
                if ([np respondsToSelector:albumArtist]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(np, albumArtist, YES);
                }
                MFCarPlayLogBoth(@"CPNowPlayingTemplate configured (upNext/albumArtist set on %@)",
                      usedSel);
            } else {
                MFCarPlayLogBoth(@"CPNowPlayingTemplate: both factory candidates missing "
                                 @"(sharedTemplate/sharedInstance/shared) — skipped, no crash");
            }
        }
    } @catch (NSException *e) {
        MFCarPlayLogBoth(@"CPNowPlayingTemplate setup threw: %@", e.reason);
    }

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

/*
 * ============ 11142640：UIWindowSceneSessionRoleCarPlay 路径 ============
 *
 * Info.plist 里新增了 CarMovie 式的 role：
 *     <key>UIWindowSceneSessionRoleCarPlay</key>
 *     <dict><key>UISceneDelegateClassName</key>
 *           <string>MFCarPlaySceneDelegate</string></dict>
 *
 * 该 role 由 **UIWindowScene** 实例化（不是 CPTemplateApplicationScene），
 * 所以走的是 UISceneDelegate 的 scene:willConnectToSession:options:，
 * 而不是 CPTemplateApplicationSceneDelegate 那条。
 *
 * 这条路径下**根本没有 CPInterfaceController** —— CarMovie 就是在这条路上
 * 自建 UIWindow 画自己的界面，完全绕开 Apple 的模板系统。
 *
 * 实现策略：
 *   1) 记录 scene 类型，写进日志（用于判断系统最终选了哪条 role）
 *   2) 如果是 UIWindowScene，自建一个 window 挂到该 scene，画一个最小界面
 *      （UITableView + 歌单列表文本），作为"这条路通了"的实证
 *   3) 如果是 CPTemplateApplicationScene，什么都不做 —— 那条路由
 *      didConnectInterfaceController: 处理
 */
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions API_AVAILABLE(ios(13.0))
{
    NSString *sceneClass = NSStringFromClass([scene class]);
    NSString *role = session.role ?: @"(nil)";
    MFCarPlayLogBoth(@"SCENE willConnect class=%@ role=%@ mainThread=%d",
          sceneClass, role, (int)[NSThread isMainThread]);

    if (![scene isKindOfClass:[UIWindowScene class]]) {
        MFCarPlayLogBoth(@"SCENE willConnect: not a UIWindowScene (%@), "
                         @"leaving it to CPTemplateApplicationSceneDelegate path",
              sceneClass);
        return;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;

    /*
     * ============ 11142648：可交互的 UITableView 界面 ============
     *
     * 11142647 首次在车机跑通 window 路径（帧 1066.67x480），但两个问题：
     *   1) 界面是手摆的 UILabel，**点击无反应**
     *   2) 数据只在 willConnect 时读一次，**新增歌单必须重启主 App 才刷新**
     *
     * 本轮改为 UITableView + dataSource/delegate：
     *   - 点击行 -> 进入下一级（歌单 -> 曲目）
     *   - 监听 kMFCarPlayDataDidUpdate 通知，数据变化时 reloadData
     *   - UINavigationController 承载层级，返回键由系统提供
     *
     * 注意：CarPlay 车机屏幕是横屏 1066x480，行高用 60 保证可点。
     */
    UIWindow *win = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.carPlayWindow = win;

    MFCarPlayWindowRootVC *rootVC = [[MFCarPlayWindowRootVC alloc] init];
    rootVC.carPlayDelegate = self;
    self.windowRootVC = rootVC;

    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:rootVC];
    /*
     * 11142651：全局隐藏导航栏 —— 用户要求无边框。
     * 主界面、歌单、曲目、搜索、播放页都靠 UINavigationController 承载，
     * 但导航栏不显示，界面全屏沉浸。
     *
     * 返回方式：车机触摸屏支持边缘滑动返回（UINavigationController 默认行为），
     * 且各列表页可点条目进入下一级，播放页为终点页，不需要返回按钮。
     */
    nav.navigationBar.hidden = YES;

    win.rootViewController = nav;
    [win makeKeyAndVisible];

    /* 数据变化时刷新 */
    [self registerWindowDataObserver];

    /*
     * ============ 11142655：主动初始化 RN 运行时 ============
     *
     * 解决冷启动问题：
     *   车机以 intent background 拉起 App 时，RN bridge 是懒加载的，
     *   如果用户没打开过主 App，JS 就不会跑，CarPlayBridge 的监听不注册，
     *   联网搜索和播放状态全部失效。
     *
     * 这里主动触发一次，让 JS 侧 setupCarPlay() 执行。
     * 初始化 2-5 秒，期间搜索只显示本地结果（有降级，不会卡）。
     */
    [self ensureReactNativeStarted];

    MFCarPlayLogBoth(@"SCENE willConnect: WINDOW PATH ACTIVE window=%p "
                     @"frame=%@ sceneClass=%@ sheets=%lu (TABLE UI)",
          (__bridge void *)win,
          NSStringFromCGRect(windowScene.coordinateSpace.bounds),
          sceneClass,
          (unsigned long)[[self sheets] count]);
}

- (void)registerWindowDataObserver {
    if (self.windowDataObserver) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    self.windowDataObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:kMFCarPlayDataDidUpdate
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        MFCarPlayLogBoth(@"WINDOW DATA UPDATE -> reload root table");
        [strongSelf.windowRootVC reloadSheets];
    }];
}

/*
 * 11142655：主动触发 RN 初始化。
 * 通过 AppDelegate 的 mfEnsureReactNativeStarted 读取 self.bridge。
 */
- (void)ensureReactNativeStarted {
    static BOOL sTriggered = NO;
    if (sTriggered) {
        return;
    }
    sTriggered = YES;

    id delegate = [UIApplication sharedApplication].delegate;
    if (![delegate respondsToSelector:@selector(mfEnsureReactNativeStarted)]) {
        MFCarPlayLogBoth(@"RN init: AppDelegate has no mfEnsureReactNativeStarted");
        return;
    }

    MFCarPlayLogBoth(@"RN init: triggering from CarPlay scene");
    BOOL ok = (BOOL)[delegate performSelector:@selector(mfEnsureReactNativeStarted)];
    MFCarPlayLogBoth(@"RN init: bridge %@", ok ? @"requested" : @"failed");
}

- (NSArray<NSDictionary *> *)historyForCarPlay {
    /* 11142649：最近播放，原生读 music.MusicHistory，不依赖 RN */
    return MFCarPlayNativeHistory(200);
}

- (NSArray<NSDictionary *> *)searchForCarPlay:(NSString *)query {
    /* 11142649：本地歌单曲目搜索，原生遍历，不依赖 RN */
    return MFCarPlayNativeSearchTracks(query);
}

- (NSDictionary *)nowPlayingForCarPlay {
    /* 11142650：当前播放，原生读 App.PersistStatus */
    return MFCarPlayNativeNowPlaying();
}

- (NSArray<NSDictionary *> *)playQueueForCarPlay {
    return MFCarPlayNativePlayQueue();
}

- (CPInterfaceController *)interfaceControllerFromScene:(UIScene *)scene {
    if (![scene isKindOfClass:[CPTemplateApplicationScene class]]) {
        return nil;
    }
    id ic = nil;
    /*
     * 全文件唯一保留的 KVC。
     *
     * 原因：CPTemplateApplicationScene **没有公开的 interfaceController 属性**
     * （公开面只有 CPTemplateApplicationScene.session / delegate 之类），
     * 而 scene 生命周期回调里需要拿它做"是否换了 controller"的判断。
     * 官方推荐的获取渠道是 didConnectInterfaceController: 参数，那条路已经走了；
     * 这里只是被动重绑时的兜底，取不到就返回 nil（调用方会跳过，不会崩）。
     *
     * 其余所有属性访问都走公开 API（CPListTemplate.sectionCount），
     * 或走自有数据快照（_lastSheetsSnapshot），不再碰框架对象的非公开成员。
     *
     * @catch 必须打日志：这处若真的失败，调用方会静默跳过重绑，
     * 车机上表现为"生命周期回调不生效"，不打日志就完全无从查起。
     */
    @try {
        ic = [(CPTemplateApplicationScene *)scene valueForKey:@"interfaceController"];
    } @catch (NSException *e) {
        MFCarPlayLogBoth(@"scene KVC interfaceController failed: %@ (%@)",
              e.reason, e.name);
        ic = nil;
    }
    if (!ic) {
        MFCarPlayLogBoth(@"scene KVC returned nil/empty for interfaceController - "
                         @"caller will skip rebind (harmless, but note it)");
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
        /* 换 controller / 重置状态：reset 节流额度恢复 */
        _resetCount = 0;
        _lastResetAt = 0;
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

    /*
     * ============ 11142630：修复 _rootExhausted 不可恢复 ============
     *
     * 11142629 真机日志暴露的缺陷：
     *   05:37:23  rearm exhausted after 2 attempts, stop polling
     *   05:37:41  lifecycle: keep root, no reinstall (willEnterForeground) applied=0 ready=1
     *   05:37:41  lifecycle: keep root, no reinstall (didBecomeActive)      applied=0 ready=1
     *
     * 用户在车机上重新点一次 MusicFree 图标，场景重新激活了，
     * 但 installRootIfNeededAllowRearm: 第一行 `if (_rootExhausted) return;`
     * 直接把后续所有尝试挡死 —— App 永久放弃，只能拔线重连。
     *
     * 重置条件刻意收紧到三个同时成立（评审要求精确定义，不要无条件重置）：
     *   1) 同一个 interfaceController       —— 不是重连，只是场景重新激活
     *   2) _rootApplied == NO               —— root 确实还没上屏
     *   3) 本次核对也确认失败（!confirmed） —— 框架确实不认
     * 只有这三条都满足，才认为"上一轮 rearm 窗口已过，值得再给一次机会"。
     *
     * 不满足就完全不碰状态：真正断开重连走的是 sceneIC != current 分支，
     * 那条路本来就会重置一切，不会被这里干扰。
     */
    if (!_rootApplied && !confirmed && _rootExhausted && self.interfaceController) {
        /*
         * ============ 节流：同一个 controller 内只允许有限次 reset ============
         *
         * 为什么要节流：
         *   willEnterForeground 和 didBecomeActive 经常在**同一秒**连续触发
         *   （11142629 日志 05:37:41 两行同秒）。若每次场景激活都无条件 reset
         *   并立即重试，日志会出现：
         *     RESET -> install -> 3s timedOut -> exhausted
         *     RESET -> install -> 3s timedOut -> exhausted
         *   —— 看起来像无限循环，实际只是场景回调密集触发，会让日志难读。
         *
         * 节流规则（两道）：
         *   1) 时间窗口：距上次 reset 不足 kMFResetMinInterval(3s) 直接跳过。
         *   2) 总次数上限：同一 controller 内最多 kMFMaxResets(2) 次。
         *      超过就不再 reset —— 说明这不是"场景抖动"，而是真的修不好，
         *      继续重试只会刷日志，等用户拔线重连（那条路会重置一切）。
         *
         * 计数与时间戳都绑定在 controller 上：didConnect / rebind 换 controller
         * 时会被清零，所以"换个 controller 重连"仍享有完整的两次机会。
         */
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        BOOL withinWindow = (_lastResetAt > 0)
                         && ((now - _lastResetAt) < kMFResetMinInterval);
        BOOL overQuota = (_resetCount >= kMFMaxResets);

        if (withinWindow || overQuota) {
            MFCarPlayLogBoth(@"RESET skipped (%@): withinWindow=%d(%.1fs) "
                             @"resetCount=%lu/%lu overQuota=%d - avoid retry storm",
                  reason,
                  withinWindow,
                  (_lastResetAt > 0) ? (now - _lastResetAt) : -1.0,
                  (unsigned long)_resetCount,
                  (unsigned long)kMFMaxResets,
                  overQuota);
            return;
        }

        _resetCount += 1;
        _lastResetAt = now;
        MFCarPlayLogBoth(@"RESET exhausted on scene reactivation (%@): "
                         @"same controller, applied=0, framework still not confirming - "
                         @"retry %lu/%lu",
              reason, (unsigned long)_resetCount, (unsigned long)kMFMaxResets);
        _rootExhausted = NO;
        _rearmCount = 0;
        _rearmPending = NO;
        _rootInstallInFlight = NO;
        _lastInstallAt = 0;
        _rootGeneration += 1;
        if (!_rootInstalledFor) {
            /* 连首发都没成功过，走正常安装路径 */
            [self installRootIfNeeded];
        } else {
            /* 首发发过但没被接受：清掉一次性标记，允许重新发起 */
            _rootInstalledFor = nil;
            [self installRootIfNeeded];
        }
        [self requestSheetsNow];
        return;
    }

    MFCarPlayLogBoth(@"lifecycle: keep root, no reinstall (%@) applied=%d confirmed=%d ready=%d exhausted=%d",
          reason, _rootApplied, confirmed, _templateReady, _rootExhausted);
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
    CPListItem *item = [[CPListItem alloc] initWithText:@"正在加载歌单..."
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

    /*
     * 每次构建 sections 时，把**数据源快照**存下来。
     *
     * 用途：指纹计算和上屏探针都改从这里取，不再去读 CPListSection.items /
     * CPListItem.text —— 那两个都不是公开 API，读了是 unrecognized selector
     * 崩溃。快照是我自己的数据，绝对安全。
     */
    _lastSheetsSnapshot = [sheetItems isKindOfClass:[NSArray class]] ? sheetItems : @[];

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
    /*
     * ============ 11142635：空模板先上屏，数据靠 updateSections 后填 ============
     *
     * 这是 MusicFree 与参考实现（missuo/kumone，上架 App Store 的 CarPlay
     * 音频 App）**最后一处结构性差异**，也是本轮唯一变量。
     *
     * kumone 的做法（CarPlayConnector.makeRootTemplate，L195-210）：
     *     let recommend = CPListTemplate(title: "推荐", sections: [])   // 空
     *     ...
     *     interfaceController.setRootTemplate(root, animated: true, completion: nil)
     * 数据是随后在 updateLibraryTab() / updateFMTab() 里通过
     *     libraryTab.updateSections(sections)
     * 异步填进去的。也就是说：**空模板先上屏，内容后到**。
     *
     * 我之前的做法是把 MMKV 读到的歌单直接塞进 initWithTitle:sections:，
     * 等于把"模板提交"和"内容校验"绑在一起。如果 carplayd 对首次
     * setRootTemplate 的模板内容做校验（item 数量/字段完整性/…），
     * 空模板可能反而能通过 —— 这能解释为什么 setRootTemplate 一直静默。
     *
     * 降级路径（三种都有明确下一步）：
     *   A) templateDidAppear 出现 + updateSections 生效 -> 车机出列表，收工
     *   B) templateDidAppear 出现但车机空           -> 模板提交通了，
     *                                                  问题转到 updateSections/内容构造
     *   C) templateDidAppear 仍不出现               -> 空模板也不被接受，
     *                                                  回到底层（连接/签名/环境）
     *
     * 注意 emptyViewTitleVariants：这是**有证据的公开 API** ——
     * kumone 里用了 12 次（recommend/curated/fm/library 各 tab 都设）。
     * emptyViewSubtitleVariants 则**刻意不用**：kumone 一次都没用，无证据。
     */
    CPListTemplate *list = [[CPListTemplate alloc] initWithTitle:@"音乐" sections:@[]];
    _rootList = list;

    /* 空模板上屏时的占位文案（等价于 kumone 的 emptyViewTitleVariants） */
    @try {
        SEL evSel = NSSelectorFromString(@"setEmptyViewTitleVariants:");
        if ([list respondsToSelector:evSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(list, evSel,
                                                  @[@"正在加载歌单…"]);
            MFCarPlayLogBoth(@"emptyViewTitleVariants set on root template");
        } else {
            MFCarPlayLogBoth(@"emptyViewTitleVariants NOT available on CPListTemplate "
                             @"(no crash, placeholder text skipped)");
        }
    } @catch (NSException *e) {
        MFCarPlayLogBoth(@"setEmptyViewTitleVariants threw: %@", e.reason);
    }

    /*
     * 指纹必须置空（评审指出的关键坑）。
     *
     * 模板现在是空的，任何一次 refreshRootSections 算出的真实指纹
     * 都与空不同，因此 templateDidAppear 之后一定会推送。
     * 如果这里沿用"首屏已带数据"的指纹，后续 updateSections 会被
     * 去重闸门挡掉 —— 那就是"空模板上屏 + 永远空列表"。
     */
    _lastPushedFingerprint = nil;

    if (allowRearm) {
        MFCarPlayLogBoth(@"rearm #%lu controller=%p (fresh EMPTY template=%p, no sections yet)",
              (unsigned long)_rearmCount, (__bridge void *)ic, (__bridge void *)list);
    } else {
        MFCarPlayLogBoth(@"one-shot root install armed controller=%p (EMPTY template, "
                         @"data will be pushed after templateDidAppear)",
              (__bridge void *)ic);
    }

    [self dispatchRootTemplate:list];
    MFCarPlayLogBoth(@"native placeholder root installed (animated=YES — matches setRootTemplate call)");

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

    /*
     * 主线程校验（11142632）。
     *
     * CarPlay 模板 API 要求在主线程调用。之前十个版本从来没验证过这一点：
     * installRootIfNeeded 可能被 MMKV 读取链、NSNotification 回调、
     * 或 watchdog 的 dispatch_after 在后台队列上触发，
     * 此时 setRootTemplate 可能被静默排队甚至丢弃 ——
     * 与"调用发出、无响应、无错误、无回调"的现象吻合。
     *
     * 这里只诊断、不强行 dispatch_async：
     * 直接跳到后台队列会破坏"必须在 didConnect 内同步发起"的不变量。
     * 先让日志告诉我们真实情况。
     */
    if (![NSThread isMainThread]) {
        MFCarPlayLogBoth(@"WARN: dispatchRootTemplate on NON-MAIN thread (thread=%@) "
                         @"— CarPlay template APIs require main thread",
              [NSThread currentThread]);
    } else {
        MFCarPlayLogBoth(@"dispatchRootTemplate on main thread, ok");
    }

    [self recordRootInstallTimestamp];

    _rootGeneration += 1;
    NSUInteger token = _rootGeneration;
    NSUInteger generationAtDispatch = _rearmCount;

    /*
     * ============ 11142631：completion 传 nil，不再依赖回调 ============
     *
     * 依据：上架 App Store 的真实 CarPlay 音频 App（missuo/kumone）用的是
     *
     *     interfaceController.setRootTemplate(root, animated: true, completion: nil)
     *
     * 而我们一直传 block。11142621 ~ 11142630 连续十版的现象是：
     *   setRootTemplate 调用发出，但 completion **从不回调**，
     *   success 不出现、FAILED 也不出现 —— 无响应、无错误、无异常。
     *
     * 传 nil 有两个作用：
     *   1) 排除"框架因为要回调 block 而在内部走了另一条路径"的可能；
     *   2) 与已知可用的写法对齐，少一个变量。
     *
     * 代价：拿不到 error 诊断。所以状态判定改为完全依赖两条独立通道：
     *   A) CPInterfaceControllerDelegate 的 templateDidAppear:  （权威信号）
     *   B) watchdog 里 syncAppliedStateFromFramework 读 topTemplate
     * 这两条在 11142630 的日志里都有大量布点，足够判断。
     *
     * 保留 token / generationAtDispatch 是为了日志里区分首发与 rearm。
     */
    @try {
        [ic setRootTemplate:list animated:YES completion:nil];
        MFCarPlayLogBoth(@"setRootTemplate dispatched (completion:nil) gen=%lu rearm=%lu template=%p",
              (unsigned long)token, (unsigned long)generationAtDispatch,
              (__bridge void *)list);
    } @catch (NSException *ex) {
        /*
         * @try 只挡「向 stale controller 调用瞬间同步抛异常」这一种情况，
         * 防止 process 被 NSInvalidArgumentException 带走（黑屏变闪退）。
         * 它保护不了"调用被吞"——那件事交给 watchdog。
         */
        MFCarPlayLogBoth(@"setRootTemplate threw on stale controller: %@", ex.reason);
        _rootInstallInFlight = NO;
        if (_controllerInvalidated) {
            _rootExhausted = YES;
            MFCarPlayLogBoth(@"rearm exhausted: controller already invalidated, no more attempts");
        } else {
            _rearmCount += 1;
            MFCarPlayLogBoth(@"rearm #%lu threw: %@", (unsigned long)_rearmCount, ex.reason);
        }
        return NO;
    }

    /*
     * 不设 _rootApplied。它只能由：
     *   - templateDidAppear:（CPInterfaceControllerDelegate）
     *   - syncAppliedStateFromFramework 的 topTemplate 核对
     * 两条通道置位。completion 已经不存在，在这里置位就是瞎猜。
     *
     * _rootInstallInFlight 保持 YES 直到 watchdog 或 didAppear 清掉它，
     * 让 watchdog 的静默失败判定（rootInstallTimedOut）有依据。
     */
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

    /*
     * ============ 11142637：把 topTemplate 的真实内容打出来 ============
     *
     * 十轮排查里最大的诊断盲点：这个方法过去只在 top == _rootList 时
     * 打一条 SYNC CONFIRM，否则**静默返回 NO**。
     * 于是我们从来不知道 topTemplate 到底是什么 ——
     * 是 nil？是系统自带的某个模板？还是读它本身就返回空？
     *
     * 这三种情况对应的根因完全不同：
     *   top == nil            -> controller 尚未提交过任何模板，
     *                            或场景没有真正连上 carplayd
     *   top 是系统模板        -> 框架自己占用了 root，我们被拒绝
     *   top == 我们的旧模板   -> completion 丢了但提交成功（状态机问题）
     *
     * 只打一次（_topProbeLogged），避免 watchdog 每轮刷屏。
     */
    /*
     * ============ 11142637：把 topTemplate 的真实内容打出来 ============
     *
     * 十轮排查里最大的诊断盲点：这个方法过去只在 top == _rootList 时
     * 打一条 SYNC CONFIRM，否则**静默返回 NO**。
     * 于是我们从来不知道 topTemplate 到底是什么 ——
     * 是 nil？是系统自带的某个模板？还是读它本身就返回空？
     *
     * 本探针无条件执行（不受 _rootApplied 闸门影响），只打一次防刷屏。
     *
     * 线程说明：所有调用者都在主线程 ——
     *   watchdog 用 dispatch_after(dispatch_get_main_queue(), ...)，
     *   templateDidAppear / refreshRootSections 也都是主线程回调。
     *   仍在日志里带 isMainThread，万一将来有后台调用能立刻发现。
     *
     * 输出解读：
     *   top=0x0  class=(nil)          -> controller 从没成功提交过任何模板
     *   match=0  templates>0          -> 有模板但不是我们的（框架占了 root）
     *   match=1                       -> 我们的模板是 top，但 didAppear 没来
     *   class=CPNowPlayingTemplate    -> 系统模板占了 root
     */
    if (!_topProbeLogged) {
        _topProbeLogged = YES;

        NSArray *tmpls = ic.templates;
        NSMutableString *desc = [NSMutableString string];
        for (NSUInteger k = 0; k < tmpls.count; k++) {
            id tk = tmpls[k];
            [desc appendFormat:@"%@(%p) ",
                NSStringFromClass([tk class]), (__bridge void *)tk];
        }

        MFCarPlayLogBoth(@"TOP-TEMPLATE PROBE: mainThread=%d top=%p class=%@ ourRoot=%p "
                         @"match=%d templates=%lu [%@]",
              (int)[NSThread isMainThread],
              (__bridge void *)top,
              top ? NSStringFromClass([top class]) : @"(nil)",
              (__bridge void *)_rootList,
              (int)(top && top == _rootList),
              (unsigned long)tmpls.count,
              desc.length ? desc : @"(empty)");
    }

    if (_rootList && top == _rootList) {
        /*
         * 措辞必须准确：这里只能证明「框架当前认定的 top 就是我们的模板」。
         * 不能断言 completion 丢过 —— 那是推断，不是观测。
         *
         * 真正的诊断价值在于它出现的**时机**：
         *   - 出现在 templateDidAppear 之前
         *     -> 框架早已接受模板，只是那次 setRootTemplate 的 completion
         *        还没回来。属于回调机制问题（可能在线程/队列上丢了），
         *        不是模板类型/entitlement 问题。
         *   - 从不出现，且 templateDidAppear 也不来
         *     -> 才去看 setRootTemplate FAILED ... domain=... 那行。
         */
        BOOL firstConfirm = !_rootApplied;
        _rootApplied = YES;
        _rootInstallInFlight = NO;
        if (firstConfirm) {
            /*
             * 措辞按评审意见改为客观描述。
             *
             * 逻辑上 "completion 没回调过" 是成立的：本方法只在 !_rootApplied
             * 时才打这条，而 _rootApplied 唯一由 completion success 置位，
             * 所以进到这里必然意味着 completion 尚未成功回调。
             * 但日志写"观测到什么"比写"推断出什么"更稳，也避免和
             * refreshRootSections 外层重复同一断言。
             */
            MFCarPlayLogBoth(@"SYNC CONFIRM: topTemplate IS our root (via top-template check) applied=1");
        }
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
            /*
             * 内层 syncAppliedStateFromFramework 已打过 SYNC CONFIRM，
             * 这里只标记"本次是 refresh 触发路径"，不再重复断言 completion 丢了。
             */
            MFCarPlayLogBoth(@"refresh: applied via sync-confirm path");
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
    /*
     * 第三个采样点（评审建议）：推完之后再问一次模板自己。
     * 三点对照（建模板后 / templateDidAppear 时 / updateSections 后）可以区分：
     *   - 建的时候有、上屏时没了      -> 框架侧丢弃，查 entitlement / 模板类型
     *   - 上屏时有、推的时候覆盖成空  -> currentRootSections 在这次调用返回空，
     *                                    查数据层（MMKV / 桥接竞争）
     */
    {
        SEL scSel2 = NSSelectorFromString(@"sectionCount");
        BOOL hasSC = [_rootList respondsToSelector:scSel2];
        NSUInteger sc = 0;
        if (hasSC) {
            sc = ((NSUInteger (*)(id, SEL))objc_msgSend)(_rootList, scSel2);
        }
        MFCarPlayLogBoth(@"updateSections done root.sectionCount=%lu (probe=%d) pushed=%lu sheetsReceived=%d applied=%d",
              (unsigned long)sc, hasSC,
              (unsigned long)sections.count,
              _sheetsReceived, _rootApplied);
    }
}

/*
 * sections 内容指纹：反映"当前 UI 该显示什么"，不只是"数据数组长什么样"。
 *
 * ============ 为什么不再遍历 CPListSection / CPListItem ============
 *   CPListSection.items、CPListItem.text / detailText **都不是公开 API**。
 *   之前我在 clang 桩里顺手声明了它们，编译期静默放行，真机上却是
 *   unrecognized selector 直接 crash。现在改为对数据快照计算。
 *
 * ============ 为什么必须把显示状态也算进指纹 ============
 *   currentRootSections 有三种状态，其中两种的快照都是空数组：
 *     桥接未回   _sheetsReceived=NO   snapshot=[]   "正在加载歌单…"
 *     桥接回了空 _sheetsReceived=YES  snapshot=[]   "暂无歌单"
 *     有歌单     _sheetsReceived=YES  snapshot=[M]  M 个 item
 *
 *   如果只对 snapshot 算指纹，前两种指纹完全相同（都是 "n=0"），
 *   于是"正在加载 -> 暂无歌单"这一步会被去重闸门挡掉：
 *     首屏建"正在加载" -> 指纹 "n=0|loading"
 *     桥接回空 -> 指纹 "n=0|loading" -> skip -> 车机永远停在"正在加载"
 *   数据层日志一切正常，排查会绕一大圈。
 *
 *   所以指纹 = 显示状态标记 + 快照内容。状态一变指纹必变，
 *   该推的时候就推，不该推的时候仍然挡住。
 */
- (NSString *)sectionsFingerprint:(NSArray<CPListSection *> *)sections {
    (void)sections;
    NSArray *snapshot = _lastSheetsSnapshot ?: @[];

    /*
     * 状态标记：直接对应 currentRootSections 会返回哪一种 section。
     *   loading  ：快照空 + 未收到数据      -> "正在加载歌单…"
     *   empty    ：快照空 + 已收到数据      -> "暂无歌单"
     *   sheets   ：快照非空                 -> M 个歌单 item
     */
    NSString *state;
    if (snapshot.count > 0) {
        state = @"sheets";
    } else if (_sheetsReceived) {
        state = @"empty";
    } else {
        state = @"loading";
    }

    NSMutableString *buf = [NSMutableString string];
    [buf appendFormat:@"state=%@|n=%lu", state, (unsigned long)snapshot.count];
    for (id s in snapshot) {
        if (![s isKindOfClass:[NSDictionary class]]) {
            [buf appendString:@"(non-dict)"];
            continue;
        }
        NSDictionary *d = (NSDictionary *)s;
        id sid = d[@"id"];
        id title = d[@"title"];
        id count = d[@"count"];
        NSString *sidStr = [sid isKindOfClass:[NSString class]] ? sid
                          : ([sid respondsToSelector:@selector(stringValue)] ? [sid stringValue] : @"");
        NSString *titleStr = [title isKindOfClass:[NSString class]] ? title : @"";
        NSString *countStr = [count isKindOfClass:[NSNumber class]]
                             ? [count stringValue] : @"";
        [buf appendFormat:@"(%@|%@|%@)", sidStr, titleStr, countStr];
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
        items = @[[[CPListItem alloc] initWithText:@"加载中..." detailText:@""]];
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


#pragma mark - 11142649：歌单列表页

/*
 * ============ 11142668：清理资源 ============
 *
 * SceneDelegate 用 block 式观察者（addObserverForName:...usingBlock:），
 * 返回值 token 保存在 windowDataObserver 里。
 *
 * 虽然 block 里用了 weakSelf（不会野指针），
 * 但 token 不释放会一直占着通知中心，属于资源泄漏。
 * dealloc 里移除。
 */
- (void)dealloc {
    if (self.windowDataObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.windowDataObserver];
        self.windowDataObserver = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    MFCarPlayLogBoth(@"SCENE DELEGATE dealloc");
}

@end





#pragma mark - 11142649：搜索页



@implementation MFCarPlayWindowTopListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    MFScaleForSize(self.view.bounds.size);
    self.view.backgroundColor = MFCarPlayBackgroundColor();
    self.tracks = @[];

    /* 表格 */
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = MFS(76.0);
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    /*
     * 11142669：去掉右侧滚动指示器（用户截图里的 ^ v 箭头）。
     * 车机上滚动条没用，反而碍眼。
     */
    self.table.showsVerticalScrollIndicator = NO;
    self.table.showsHorizontalScrollIndicator = NO;
    /* 11142671：indicatorStyle 也设 None，彻底去掉右侧箭头 */
    self.table.indicatorStyle = 0;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];

    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:64],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];

    /* 加载指示器（等 JS 回传时显示） */
    self.spinner = [[UIActivityIndicatorView alloc] init];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    /* 返回按钮 + 标题（最后加，保证在最上层） */
    MFAddTopTitle(self, self.listTitle);
    MFAddBackButton(self);

    /* 监听 JS 回传的曲目 */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleTopListTracks:)
                                                 name:@"MFCarPlayTopListTracks"
                                               object:nil];

    MFCarPlayLogBoth(@"TOPLIST VC: title=%@ listId=%@ plugin=%@",
          self.listTitle, self.listId, self.pluginHash);
}

- (void)handleTopListTracks:(NSNotification *)note {
    NSString *lid = note.userInfo[@"listId"];
    NSArray *tracks = note.userInfo[@"tracks"];

    /* 校验：只接受当前榜单的结果 */
    if (![lid isKindOfClass:[NSString class]] ||
        ![lid isEqualToString:self.listId ?: @""]) {
        return;
    }
    if (![tracks isKindOfClass:[NSArray class]]) {
        return;
    }

    self.tracks = tracks;
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    MFSafeReload(self.table, @"TOPLIST");

    MFCarPlayLogBoth(@"TOPLIST VC: loaded %lu tracks for '%@'",
          (unsigned long)tracks.count, self.listTitle);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"tltrack";
    MFCarPlayListCell *cell = (MFCarPlayListCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[MFCarPlayListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:cid];
    }
    if (indexPath.row < (NSInteger)self.tracks.count) {
        NSDictionary *tr = self.tracks[(NSUInteger)indexPath.row];
        NSString *tt = [tr[@"title"] isKindOfClass:[NSString class]] ? tr[@"title"] : @"";
        NSString *ar = [tr[@"artist"] isKindOfClass:[NSString class]] ? tr[@"artist"] : @"";
        NSString *al = [tr[@"album"] isKindOfClass:[NSString class]] ? tr[@"album"] : @"";
        NSString *sub = @"";
        if (ar.length > 0 && al.length > 0) {
            sub = [NSString stringWithFormat:@"%@  \u00b7  %@", ar, al];
        } else {
            sub = ar.length > 0 ? ar : al;
        }
        NSString *cover = [tr[@"artwork"] isKindOfClass:[NSString class]] ? tr[@"artwork"] : nil;
        [cell configureWithTitle:tt subtitle:sub cover:cover];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.tracks.count) {
        return;
    }
    NSDictionary *tr = self.tracks[(NSUInteger)indexPath.row];
    NSString *tid = [tr[@"id"] isKindOfClass:[NSString class]] ? tr[@"id"] : @"";

    MFCarPlayLogBoth(@"TOPLIST tap row=%ld track=%@", (long)indexPath.row, tid);
    [MFCarPlayBridge emitPlayTrack:tid sheetId:@""];

    /* 用点中的数据直接构造播放页（不读 MMKV，避免竞态） */
    MFCarPlayWindowNowPlayingVC *np = [[MFCarPlayWindowNowPlayingVC alloc] init];
    np.carPlayDelegate = self.carPlayDelegate;
    np.nowPlaying = MFNowPlayingFromTrack(tr);
    [self.navigationController pushViewController:np animated:YES];
}

- (void)onBack {
    MFCarPlayLogBoth(@"%@ tap BACK", @"MFCarPlayWindowTopListVC");
    [self.navigationController popViewControllerAnimated:YES];
}

/* 11142668：移除观察者，防止野指针闪退 */
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    MFCarPlayLogBoth(@"TOPLIST dealloc");
}

@end

@implementation MFCarPlayWindowNowPlayingVC

- (void)viewDidLoad {
    [super viewDidLoad];
    MFScaleForSize(self.view.bounds.size);

    self.title = @"";
    self.view.backgroundColor = MFCarPlayBackgroundColor();

    /*
     * 11142653：封面作背景。
     *
     * 用户反馈纯黑不好看。所以：
     *   1) 铺一张全屏 UIImageView 在底层（内容模式 aspectFill）
     *   2) 上面盖一层半透明黑（alpha 0.55），保证文字可读
     * 封面下载成功后填充，失败则是纯黑 + 遮罩（不影响其他控件）
     */
    self.backgroundImageView = [[UIImageView alloc] init];
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.backgroundImageView];
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    UIView *dim = [[UIView alloc] init];
    dim.backgroundColor = [UIColor blackColor];
    dim.alpha = 0.55;
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:dim];
    [NSLayoutConstraint activateConstraints:@[
        [dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    /*
     * 11142651：无边框播放页 —— 去掉导航栏，全屏沉浸。
     * 用户要求顶部导航条去掉，返回通过系统手势/左上角（若有）处理。
     * 这里不做 rightBarButtonItem（播放列表功能已移除）。
     */
    self.navigationController.navigationBar.hidden = YES;

    NSDictionary *np = self.nowPlaying ?: [self.carPlayDelegate nowPlayingForCarPlay];
    self.nowPlaying = np;

    NSString *title = np[@"title"] ?: @"未知歌曲";
    NSString *artist = np[@"artist"] ?: @"";
    NSString *album = np[@"album"] ?: @"";
    NSString *artwork = np[@"artwork"] ?: @"";

    /* 歌手 + 专辑，例如「周杰伦 / 叶惠美」 */
    NSString *subtitle = nil;
    if (artist.length > 0 && album.length > 0) {
        subtitle = [NSString stringWithFormat:@"%@ / %@", artist, album];
    } else {
        subtitle = artist.length > 0 ? artist : album;
    }

    /* 歌名 */
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = title;
    self.titleLabel.font = MFFont(30.0);
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];

    /* 歌手/专辑 */
    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.text = subtitle;
    self.artistLabel.font = MFFont(20.0);
    self.artistLabel.textColor = [UIColor whiteColor];
    self.artistLabel.textAlignment = NSTextAlignmentCenter;
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.artistLabel];

    /* 封面 */
    self.coverView = [[UIImageView alloc] init];
    self.coverView.backgroundColor = MFCarPlayCardColor();
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.translatesAutoresizingMaskIntoConstraints = NO;
    /*
     * 11142657：封面可点击 —— 点击切换封面 / 歌词（用户选的方案 ③）。
     * 必须开 userInteractionEnabled，UIImageView 默认是关的。
     */
    self.coverView.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCoverTap)];
    tap.numberOfTapsRequired = 1;
    [self.coverView addGestureRecognizer:tap];
    [self.view addSubview:self.coverView];

    /* 异步下载封面（失败就不显示，不影响其他控件） */
    if (artwork.length > 0) {
        NSURL *url = [NSURL URLWithString:artwork];
        if (url) {
            __weak __typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:url];
                UIImage *img = data ? [UIImage imageWithData:data] : nil;
                if (!img) {
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        __strong __typeof(weakSelf) s = weakSelf;
                        /* 11142667：必须检查 window，否则页面已 pop 时会崩 */
                        if (!s || !s.view.window) {
                            return;
                        }
                        s.coverView.image = img;
                        s.backgroundImageView.image = img;
                        MFCarPlayLogBoth(@"NOWPLAYING cover loaded %lu bytes",
                              (unsigned long)data.length);
                    } @catch (NSException *e) {
                        MFCarPlayLogBoth(@"NOWPLAYING cover set threw: %@", e.reason);
                    }
                });
            });
        }
    }

    /* 三个按钮：上一首 / 播放暂停 / 下一首 */
    UIButton *prev = [self makeControlButton:@"◀◀" action:@selector(onPrev)];
    UIButton *play = [self makeControlButton:@"▶"  action:@selector(onPlayPause)];
    /* 11142661：保存引用，供 JS 回传状态时切换图标 */
    self.playPauseButton = play;
    UIButton *next = [self makeControlButton:@"▶▶" action:@selector(onNext)];

    /* 进度文字 */
    double duration = [np[@"duration"] isKindOfClass:[NSNumber class]]
        ? [np[@"duration"] doubleValue] : 0;
    double progress = [np[@"progress"] isKindOfClass:[NSNumber class]]
        ? [np[@"progress"] doubleValue] : 0;

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.text = [NSString stringWithFormat:@"%@   /   %@",
                           [self formatTime:progress], [self formatTime:duration]];
    self.timeLabel.font = MFFont(18.0);
    self.timeLabel.textColor = [UIColor whiteColor];
    self.timeLabel.textAlignment = NSTextAlignmentCenter;
    self.timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.timeLabel];

    /*
     * ============ 11142661：进度条 ============
     *
     * 之前只有文字时间，没有可视化进度。
     * 这里加一条细进度条，由 JS 每 500ms 推送的 progress 驱动。
     *
     * 位置：时间文字上方
     * 颜色：已播放段用主题浅蓝，未播放段用深灰
     */
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:0];
    self.progressView.progressTintColor = MFCarPlayAccentColor();
    self.progressView.trackTintColor =
        [UIColor colorWithRed:0.28 green:0.28 blue:0.30 alpha:1.0];
    self.progressView.progress = 0.0;
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progressView];

    /*
     * ============ 11142661：爱心 / 循环 / 音质 ============
     *
     * 位置：进度条右侧一行，三个小圆按钮。
     * 图标用 unichar 构造，避免源码非 ASCII。
     *   ♥ U+2665 实心 / U+2661 空心
     *   ↻ U+21BB 循环
     *   ♪ U+266A 音质
     */
    /* 11142673：只保留 ♡ 和 ↻（♪ 音质按钮已移除） */
    self.favoriteButton = [self makeSmallButton:0x2661 action:@selector(onFavorite)];
    self.repeatButton = [self makeSmallButton:0x21BB action:@selector(onRepeat)];

    for (UIButton *b in @[self.favoriteButton, self.repeatButton]) {
        [self.view addSubview:b];
    }

    /* 11142672：三按钮布局已移到主布局块（与播放键同一行），此处不再重复 */


        /*
     * ============ 11142672：播放页布局重做（按用户设计）============
     *
     * 目标布局：
     *
     *           歌名
     *        歌手 / 专辑
     *      [封面 168×168]
     *   ◀◀   ▶   ▶▶    ♡ ↻ ♪      <- 三功能按钮与播放键同一行
     *  ━━━━━●─────────
     *    0:12  /  4:06
     *
     * 高度累加（屏幕 480）：
     *   12 + 38 + 4 + 26 + 10 + 168 + 12 + 56 + 8 + 4 + 6 + 20 + 10 = 374
     *   余量 106px，充裕。
     *
     * 关键改动：
     *   1) 三功能按钮从「进度条下方」移到「与播放键同一行、右侧」
     *   2) 整体依赖「自上而下」的约束链，不写死 y 坐标
     *   3) 所有间距用 MFS() 保持屏幕自适应
     */
    UIView *v = self.view;

    [NSLayoutConstraint activateConstraints:@[
        /* --- 歌名：顶部 --- */
        [self.titleLabel.topAnchor constraintEqualToAnchor:v.topAnchor constant:MFS(12)],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:MFS(24)],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-MFS(24)],

        /* --- 歌手/专辑 --- */
        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:MFS(4)],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:MFS(24)],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-MFS(24)],

        /* --- 封面：居中 --- */
        [self.coverView.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:MFS(10)],
        [self.coverView.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [self.coverView.widthAnchor constraintEqualToConstant:MFS(168)],
        [self.coverView.heightAnchor constraintEqualToConstant:MFS(168)],

        /* ============================================================
         * --- 按钮行：三个播放键 + 三个功能键 同一行 ---
         *
         * 排列（从左到右）：
         *   ◀◀   ▶   ▶▶        ♡  ↻  ♪
         *   ↑播放组居中偏左        ↑功能组靠右
         * ============================================================ */

        /* 播放键（中间）：水平居中偏左，让出右侧空间给功能键 */
        [play.topAnchor constraintEqualToAnchor:self.coverView.bottomAnchor constant:MFS(12)],
        [play.centerXAnchor constraintEqualToAnchor:v.centerXAnchor constant:-MFS(110)],
        [play.widthAnchor constraintEqualToConstant:MFS(96)],
        [play.heightAnchor constraintEqualToConstant:MFS(56)],

        /* 上一首：播放键左侧 */
        [prev.trailingAnchor constraintEqualToAnchor:play.leadingAnchor constant:-MFS(16)],
        [prev.centerYAnchor constraintEqualToAnchor:play.centerYAnchor],
        [prev.widthAnchor constraintEqualToConstant:MFS(90)],
        [prev.heightAnchor constraintEqualToConstant:MFS(56)],

        /* 下一首：播放键右侧 */
        [next.leadingAnchor constraintEqualToAnchor:play.trailingAnchor constant:MFS(16)],
        [next.centerYAnchor constraintEqualToAnchor:play.centerYAnchor],
        [next.widthAnchor constraintEqualToConstant:MFS(90)],
        [next.heightAnchor constraintEqualToConstant:MFS(56)],

        /* --- 两个功能键：同一行，靠右（♪ 已移除） --- */

        /* ↻ 循环模式：最右 */
        [self.repeatButton.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-MFS(40)],
        [self.repeatButton.centerYAnchor constraintEqualToAnchor:play.centerYAnchor],
        [self.repeatButton.widthAnchor constraintEqualToConstant:MFS(56)],
        [self.repeatButton.heightAnchor constraintEqualToConstant:MFS(56)],

        /* ♡ 收藏：循环键左侧 */
        [self.favoriteButton.trailingAnchor constraintEqualToAnchor:self.repeatButton.leadingAnchor constant:-MFS(16)],
        [self.favoriteButton.centerYAnchor constraintEqualToAnchor:play.centerYAnchor],
        [self.favoriteButton.widthAnchor constraintEqualToConstant:MFS(56)],
        [self.favoriteButton.heightAnchor constraintEqualToConstant:MFS(56)],

        /* --- 进度条：按钮行下方 --- */
        /* 11142674：进度条下移，和按钮行拉开距离 */
        [self.progressView.topAnchor constraintEqualToAnchor:play.bottomAnchor constant:MFS(24)],
        [self.progressView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:MFS(40)],
        [self.progressView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-MFS(40)],
        /* 11142674：进度条加粗，车机屏上更明显 */
        [self.progressView.heightAnchor constraintEqualToConstant:MFS(6)],

        /* --- 时间文字：进度条下方 --- */
        /* 11142674：时间文字也下移 */
        [self.timeLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:MFS(16)],
        [self.timeLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:MFS(24)],
        [self.timeLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-MFS(24)],
    ]];

    self.lastRenderedTitle = title;
    self.currentLyricIndex = -1;   /* 11142671：-1 表示还没高亮过 */
    MFCarPlayLogBoth(@"NOWPLAYING VC: title=%@ artist=%@ album=%@ duration=%.0f "
                     @"progress=%.0f queue=%@ artwork=%@",
          title, artist, album, duration, progress,
          np[@"queueCount"] ?: @0,
          artwork.length > 0 ? @"yes" : @"no");

    /*
     * ============ 11142658：返回按钮必须最后加 ============
     *
     * 用户反馈「播放页没有返回按钮」。
     *
     * 根因：之前在 viewDidLoad 开头就 MFAddBackButton，
     * 但后面又依次 addSubview 了 backgroundImageView / dim /
     * titleLabel / artistLabel / coverView / timeLabel，
     * 这些后加的视图把按钮盖住了。
     *
     * MFAddBackButton 内部虽然有 bringSubviewToFront，
     * 但那是在按钮刚添加时执行的 —— 后续新加的视图仍然在上面。
     *
     * 修法：放到 viewDidLoad 最末尾，所有视图都加完之后再添加。
     */
    MFAddBackButton(self);

    /* 11142669：启动原生进度轮询（1 秒，JS 不推时的兜底） */
    [self startProgressPoll];

    /*
     * 11142655：监听 JS 回传的播放状态。
     * 这一版只把状态记到日志 + 更新按钮文字，完整实时刷新在构建 B。
     */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleNowPlayingState:)
                                                 name:@"MFCarPlayNowPlayingState"
                                               object:nil];

    /* 11142657：歌词推送监听 */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLyricUpdate:)
                                                 name:@"MFCarPlayLyric"
                                               object:nil];

    /* 11142672：确认观察者注册成功（诊断「收不到通知」问题） */
    MFCarPlayLogBoth(@"NOWPLAYING observers registered: state+lyric, self=%p", self);
}

/* 收到 JS 播放状态 */
- (void)handleNowPlayingState:(NSDictionary *)state {
    /* 11142672：第一行记录，验证通知到达 */
    MFCarPlayLogBoth(@"NOWPLAYING RECV state keys=%lu", (unsigned long)state.count);

    if (![state isKindOfClass:[NSDictionary class]]) {
        return;
    }
    /* 记录 JS 推送时间，让轮询避让（但轮询也会读桥，所以不会冲突） */
    self.lastJSStateTime = [NSDate timeIntervalSinceReferenceDate];

    /* 统一走 applyStateToUI，保证通知路径和轮询路径逻辑一致 */
    [self applyStateToUI:state];
    [self refreshLyricHighlight];
}

/*
 * 11142669：曲目变化时刷新标题/歌手/封面。
 */
- (void)refreshNowPlayingContent:(NSDictionary *)state {
    NSString *title = state[@"title"] ?: @"";
    NSString *artist = state[@"artist"] ?: @"";
    NSString *album = state[@"album"] ?: @"";
    NSString *artwork = state[@"artwork"] ?: @"";

    self.lastRenderedTitle = title;

    self.titleLabel.text = title;

    NSString *sub = nil;
    if (artist.length > 0 && album.length > 0) {
        sub = [NSString stringWithFormat:@"%@ / %@", artist, album];
    } else {
        sub = artist.length > 0 ? artist : album;
    }
    self.artistLabel.text = sub ?: @"";

    /* 封面换了就重新下载 */
    if (artwork.length > 0) {
        NSURL *url = [NSURL URLWithString:artwork];
        if (url) {
            __weak __typeof(self) weakSelf = self;
            NSString *token = [artwork copy];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @autoreleasepool {
                    NSData *d = [NSData dataWithContentsOfURL:url];
                    UIImage *img = d ? [UIImage imageWithData:d] : nil;
                    if (!img) {
                        return;
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            __strong __typeof(weakSelf) s = weakSelf;
                            if (!s || !s.view.window) {
                                return;
                            }
                            s.coverView.image = img;
                            s.backgroundImageView.image = img;
                            MFCarPlayLogBoth(@"[TRACK] cover applied %lu bytes", (unsigned long)d.length);
                            MFCarPlayLogBoth(@"NOWPLAYING content refresh: %@ (cover %lu)",
                                  token.length > 0 ? @"with" : @"no",
                                  (unsigned long)d.length);
                        } @catch (NSException *e) {
                            MFCarPlayLogBoth(@"NOWPLAYING refresh threw: %@", e.reason);
                        }
                    });
                }
            });
        }
    }

    MFCarPlayLogBoth(@"NOWPLAYING content updated: %@ - %@", title, sub ?: @"");
}

- (UIButton *)makeControlButton:(NSString *)text action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:0];
    [b setTitle:text forState:0];
    [b setTitleColor:[UIColor whiteColor] forState:0];
    b.titleLabel.font = MFFont(26.0);
    b.backgroundColor = MFCarPlayCardColor();

    /*
     * ============ 11142674：播放键改圆角框 ============
     *
     * 用户要求 ◀◀ ▶ ▶▶ 也做成圆角框。
     * 原来这个工厂函数没有设 cornerRadius，所以是直角矩形；
     * 而功能键（♡ ↻）用的 makeSmallButton 有 8pt 圆角。
     *
     * 现在统一成 10pt 圆角，和卡片列表、功能键风格一致。
     */
    b.layer.cornerRadius = MFS(10.0);
    b.layer.masksToBounds = YES;

    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:action forControlEvents:64];  /* touchUpInside */
    [self.view addSubview:b];
    return b;
}

- (NSString *)formatTime:(double)sec {
    if (sec < 0 || sec != sec) {   /* NaN 保护 */
        sec = 0;
    }
    int total = (int)sec;
    int m = total / 60;
    int s = total % 60;
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

/* 11142661：小圆按钮工厂 */
- (UIButton *)makeSmallButton:(unichar)code action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:0];
    NSString *sym = [NSString stringWithCharacters:&code length:1];
    [b setTitle:sym forState:0];
    [b setTitleColor:[UIColor colorWithRed:0.75 green:0.75 blue:0.78 alpha:1.0] forState:0];
    b.titleLabel.font = MFFont(24.0);
    b.backgroundColor = MFCarPlayCardColor();
    /* 11142674：和播放键统一 10pt 圆角 */
    b.layer.cornerRadius = MFS(10.0);
    b.layer.masksToBounds = YES;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:action forControlEvents:64];
    return b;
}

- (void)onFavorite {
    MFCarPlayLogBoth(@"[ACTION] favorite tapped (current title=%, fav=%d)");
    [MFCarPlayBridge emitControl:@"favorite"];
    /* 点击后 1 秒打印结果，验证状态是否变化 */
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s.favoriteButton) {
            MFCarPlayLogBoth(@"[ACTION] favorite btn now = '%@'",
                  s.favoriteButton.titleLabel.text ?: @"?");
        }
    });
}

- (void)onRepeat {
    MFCarPlayLogBoth(@"[ACTION] repeat tapped");
    [MFCarPlayBridge emitControl:@"repeat"];
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s.repeatButton) {
            MFCarPlayLogBoth(@"[ACTION] repeat btn now = '%@'",
                  s.repeatButton.titleLabel.text ?: @"?");
        }
    });
}

/* 11142673：onQuality 已移除 */

- (void)onPrev {
    MFCarPlayLogBoth(@"NOWPLAYING tap PREV");
    [MFCarPlayBridge emitControl:@"prev"];
}

- (void)onPlayPause {
    NSString *cur = self.playPauseButton.titleLabel.text ?: @"?";
    MFCarPlayLogBoth(@"[ACTION] play/pause tapped (btn=%@)", cur);
    [MFCarPlayBridge emitControl:@"toggle"];
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) s = weakSelf;
        if (s && s.playPauseButton) {
            MFCarPlayLogBoth(@"[ACTION] play/pause btn now = '%@'",
                  s.playPauseButton.titleLabel.text ?: @"?");
        }
    });
}

- (void)onNext {
    MFCarPlayLogBoth(@"NOWPLAYING tap NEXT");
    [MFCarPlayBridge emitControl:@"next"];
}


- (void)onBack {
    MFCarPlayLogBoth(@"%@ tap BACK", @"MFCarPlayWindowNowPlayingVC");
    [self.navigationController popViewControllerAnimated:YES];
}


#pragma mark - 11142657：歌词（点封面切换 / 滚动高亮）

/*
 * 封面点击切换封面 <-> 歌词。
 *
 * 布局（用户选择方案 ③）：
 *   封面模式：  歌名 / 歌手 · 专辑 / [封面] / 按钮 / 时间
 *   歌词模式：  歌名 / 歌手 · 专辑 / [滚动歌词] / 按钮 / 时间
 *
 * 两者共用同一个封面位置的矩形区域，只是显隐切换。
 */
/* 11142669：启动进度轮询 */
- (void)startProgressPoll {
    if (self.progressPollTimer) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    self.progressPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
        __strong __typeof(weakSelf) s = weakSelf;
        if (!s || !s.view.window) {
            [timer invalidate];
            s.progressPollTimer = nil;
            return;
        }
        [s pollProgressOnce];
    }];
    MFCarPlayLogBoth(@"NOWPLAYING progress poll started");
}

/* 11142669：轮询一次（读 MMKV 的 progress） */
- (void)pollProgressOnce {
    /* 11142675：每 10 秒确认轮询还活着（排查「突然不动」） */
    static int sPollCount = 0;
    sPollCount++;
    if (sPollCount % 10 == 1) {
        MFCarPlayLogBoth(@"[POLL] tick #%d showingLyric=%d lyricLines=%lu",
              sPollCount, (int)self.showingLyric,
              (unsigned long)self.lyricLines.count);
    }
    /*
     * ============ 11142672：不再依赖通知，直接读桥 ============
     *
     * 日志证据：
     *   BRIDGE state: 152 次    <- 桥确实收到 JS 数据
     *   NOWPLAYING state: 0 次   <- 播放页一次都没收到通知
     *
     * 说明 NSNotification 没送达（原因待查），
     * 但桥里的 nowPlayingStateData 是有的。
     *
     * 所以改成：每秒主动向桥拉取最新状态，直接更新 UI。
     * 这比等通知可靠 —— 不依赖通知中心，不依赖线程。
     */
    MFCarPlayBridge *bridge = [MFCarPlayBridge shared];
    if (!bridge) {
        return;
    }
    NSDictionary *st = [bridge nowPlayingState];
    if (![st isKindOfClass:[NSDictionary class]] || st.count == 0) {
        return;
    }

    /* 直接用桥的数据更新 UI（复用同一个处理函数） */
    [self applyStateToUI:st];

    /*
     * ============ 11142674：歌词也走轮询 ============
     *
     * 严重问题：handleLyricUpdate 只靠 NSNotification，
     * 但日志证明通知收不到（NOWPLAYING state: 0 次）。
     * 所以切歌后歌词永远不更新。
     *
     * 修法：轮询时也读桥里的歌词，行数变了就重载表格。
     */
    [self pollLyricFromBridge];

    /* 刷新歌词高亮 */
    [self refreshLyricHighlight];
}

/*
 * 11142674：从桥轮询歌词。
 * 和进度一样，绕开通知机制。
 */
- (void)pollLyricFromBridge {
    MFCarPlayBridge *bridge = [MFCarPlayBridge shared];
    if (!bridge) {
        return;
    }
    NSArray *lines = [bridge lyric];
    if (![lines isKindOfClass:[NSArray class]]) {
        return;
    }

    /* 行数没变就不动（避免每秒 reloadData） */
    if (lines.count == self.lyricLines.count) {
        return;
    }

    MFCarPlayLogBoth(@"[LYRIC] poll: %lu -> %lu lines",
          (unsigned long)self.lyricLines.count, (unsigned long)lines.count);

    self.lyricLines = lines;
    self.currentLyricIndex = -1;

    if (self.lyricTable && self.showingLyric) {
        [self.lyricTable reloadData];
        MFCarPlayLogBoth(@"[LYRIC] table reloaded: %lu lines", (unsigned long)lines.count);
    }
}

/*
 * 11142672：把状态字典应用到 UI。
 * handleNowPlayingState: 和 pollProgressOnce 共用这一套逻辑，
 * 避免两处代码不一致。
 */
- (void)applyStateToUI:(NSDictionary *)state {
    if (![state isKindOfClass:[NSDictionary class]]) {
        return;
    }

    /* 11142675：记录收到的状态（每 5 次一次，避免刷屏） */
    static int sApplyCount = 0;
    if (sApplyCount++ % 5 == 0) {
        MFCarPlayLogBoth(@"[STATE] apply #%d title=%@ pos=%@/%@ playing=%@ fav=%@ rep=%@",
              sApplyCount,
              state[@"title"] ?: @"-",
              state[@"progress"] ?: @"-",
              state[@"duration"] ?: @"-",
              state[@"isPlaying"] ?: @"-",
              state[@"isFavorite"] ?: @"-",
              state[@"repeatMode"] ?: @"-");
    }

    NSNumber *prog = [state[@"progress"] isKindOfClass:[NSNumber class]]
        ? state[@"progress"] : nil;
    NSNumber *dur = [state[@"duration"] isKindOfClass:[NSNumber class]]
        ? state[@"duration"] : nil;
    NSNumber *isPlaying = [state[@"isPlaying"] isKindOfClass:[NSNumber class]]
        ? state[@"isPlaying"] : nil;

    double cur = prog ? prog.doubleValue : 0;
    double total = dur ? dur.doubleValue : 0;

    /* 过滤非法值（日志里出现过 1.69e-52 这种垃圾数据） */
    if (cur < 0) {
        cur = 0;
    }
    if (total < 0) {
        total = 0;
    }

    /* 进度条 */
    if (self.progressView) {
        if (total > 0) {
            double ratio = cur / total;
            if (ratio < 0) ratio = 0;
            if (ratio > 1) ratio = 1;
            [self.progressView setProgress:ratio animated:YES];
        }
    }

    /* 时间文字 */
    if (self.timeLabel && total > 0) {
        self.timeLabel.text = [NSString stringWithFormat:@"%@   /   %@",
                               [self formatTime:cur],
                               [self formatTime:total]];
    }

    /* 播放/暂停图标 */
    if (isPlaying && self.playPauseButton) {
        unichar code = isPlaying.boolValue ? 0x23F8 : 0x25B6;
        NSString *sym = [NSString stringWithCharacters:&code length:1];
        [self.playPauseButton setTitle:sym forState:0];
    }

    /* 爱心 */
    NSNumber *fav = [state[@"isFavorite"] isKindOfClass:[NSNumber class]]
        ? state[@"isFavorite"] : nil;
    if (self.favoriteButton && fav) {
        unichar hc = fav.boolValue ? 0x2665 : 0x2661;
        NSString *hs = [NSString stringWithCharacters:&hc length:1];
        [self.favoriteButton setTitle:hs forState:0];
        [self.favoriteButton setTitleColor:(fav.boolValue
            ? MFCarPlayAccentColor()
            : [UIColor colorWithRed:0.75 green:0.75 blue:0.78 alpha:1.0])
                                  forState:0];
    }

    /* 循环 */
    NSString *repeat = [state[@"repeatMode"] isKindOfClass:[NSString class]]
        ? state[@"repeatMode"] : nil;
    if (self.repeatButton && repeat) {
        /*
         * 11142673：图标按用户要求换成
         *   QUEUE   -> U+21BB  列表循环 ↻
         *   SINGLE  -> U+2460  单曲循环 ①
         *   SHUFFLE -> U+2928  随机 ⤨
         */
        unichar rc = 0x21BB;
        if ([repeat isEqualToString:@"SINGLE"]) {
            rc = 0x2460;   /* ① 单曲循环 */
        } else if ([repeat isEqualToString:@"SHUFFLE"]) {
            rc = 0x2928;   /* ⤨ 随机 */
        }
        NSString *rs = [NSString stringWithCharacters:&rc length:1];
        [self.repeatButton setTitle:rs forState:0];
        BOOL nonDefault = ![repeat isEqualToString:@"QUEUE"];
        [self.repeatButton setTitleColor:(nonDefault
            ? MFCarPlayAccentColor()
            : [UIColor colorWithRed:0.75 green:0.75 blue:0.78 alpha:1.0])
                                forState:0];
    }

    /* 11142673：音质按钮已移除，不再处理 quality 字段 */

    /* 记录进度 + 检测切歌 */
    self.currentProgress = cur;
    NSString *newTitle = [state[@"title"] isKindOfClass:[NSString class]]
        ? state[@"title"] : nil;
    if (newTitle.length > 0 &&
        ![newTitle isEqualToString:self.lastRenderedTitle ?: @""]) {
        MFCarPlayLogBoth(@"[TRACK] changed: '%@' -> '%@'",
              self.lastRenderedTitle ?: @"(none)", newTitle);
        [self refreshNowPlayingContent:state];
    }
}

- (void)onCoverTap {
    self.showingLyric = !self.showingLyric;
    MFCarPlayLogBoth(@"NOWPLAYING toggle lyric mode -> %d", (int)self.showingLyric);

    if (self.showingLyric) {
        [self buildLyricTableIfNeeded];
        self.coverView.hidden = YES;
        self.lyricTable.hidden = NO;
        [self refreshLyricHighlight];
    } else {
        self.coverView.hidden = NO;
        self.lyricTable.hidden = YES;
    }
}

/* 懒建歌词表格 */
- (void)buildLyricTableIfNeeded {
    if (self.lyricTable) {
        return;
    }

    UITableView *tb = [[UITableView alloc] initWithFrame:CGRectZero
                                                   style:UITableViewStylePlain];
    tb.dataSource = self;
    tb.delegate = self;
    /* 11142672：歌词行高加大，车机屏上更好读 */
    tb.rowHeight = MFS(52.0);
    tb.backgroundColor = [UIColor clearColor];      /* 透出背景图 */
    tb.separatorColor = [UIColor clearColor];
    tb.showsVerticalScrollIndicator = NO;
    tb.translatesAutoresizingMaskIntoConstraints = NO;
    tb.hidden = YES;
    [self.view addSubview:tb];
    self.lyricTable = tb;

    /* 与封面同一位置，稍宽一点（歌词行更长） */
    [NSLayoutConstraint activateConstraints:@[
        /*
         * 11142672：歌词区域加高。
         * 原来和封面同高（168），只能显示 3 行。
         * 改为延伸到按钮行上方，约 300px，能显示 5-6 行。
         */
        [tb.topAnchor constraintEqualToAnchor:self.coverView.topAnchor constant:-MFS(10)],
        [tb.bottomAnchor constraintEqualToAnchor:self.progressView.topAnchor constant:-MFS(6)],
        [tb.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:MFS(60)],
        [tb.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-MFS(60)],
    ]];

    /* 加载当前歌词 */
    NSArray *lines = [MFCarPlayBridge shared].lyric;
    if (!lines || lines.count == 0) {
        lines = self.lyricLines;
    }
    self.lyricLines = lines ?: @[];
    [tb reloadData];

    MFCarPlayLogBoth(@"NOWPLAYING lyric table built: %lu lines",
          (unsigned long)self.lyricLines.count);
}

#pragma mark UITableViewDataSource（歌词）

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.lyricLines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"lyric";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = 0;
        /*
         * 11142670：歌词居中对齐。
         *
         * 用户要求「切换成歌词显示以后歌词居中」。
         *
         * 光设 textAlignment 不够 —— UILabel 在 cell 里的实际宽度
         * 是内容宽度，靠左排，中心点偏左。
         * 必须同时把 label 的 frame 撑满 cell 宽度，居中对齐才生效。
         */
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.detailTextLabel.textAlignment = NSTextAlignmentCenter;
        /* 让 label 宽度撑满，居中对齐才真正居中 */
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
    }
    if (indexPath.row < (NSInteger)self.lyricLines.count) {
        NSDictionary *line = self.lyricLines[(NSUInteger)indexPath.row];
        NSString *lrc = [line[@"lrc"] isKindOfClass:[NSString class]] ? line[@"lrc"] : @"";
        NSString *tr = [line[@"translation"] isKindOfClass:[NSString class]]
            ? line[@"translation"] : @"";

        BOOL isCurrent = (indexPath.row == self.currentLyricIndex);
        cell.textLabel.text = lrc;
        cell.textLabel.font = [UIFont systemFontOfSize:(isCurrent ? 22.0 : 18.0)];
        cell.textLabel.textColor = isCurrent
            ? MFCarPlayAccentColor()                       /* 当前行：浅蓝高亮 */
            : [UIColor colorWithRed:0.75 green:0.75 blue:0.78 alpha:1.0];
        cell.detailTextLabel.text = tr;
        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.6 green:0.6 blue:0.63 alpha:1.0];
    }
    return cell;
}

/* 歌词不响应点击（避免误触） */
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

/*
 * 根据播放进度刷新高亮行 + 自动滚动到中间。
 *
 * 由 handleNowPlayingState: 调用（JS 每秒推一次 progress）。
 */
/*
 * 11142670：歌词真正居中。
 *
 * UILabel 的 textAlignment=Center 只在 label 宽度 = cell 宽度时
 * 才视觉居中。系统 cell 的 textLabel 宽度由内容决定，
 * 所以要在 willDisplay 里把 frame 撑满。
 */
- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
   forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView != self.lyricTable) {
        return;
    }
    CGFloat w = tableView.bounds.size.width;
    CGFloat h = cell.contentView.bounds.size.height;
    if (w <= 0 || h <= 0) {
        return;
    }
    /* 左右各留 16，居中 */
    cell.textLabel.frame = CGRectMake(16, 0, w - 32, h * 0.65);
    cell.detailTextLabel.frame = CGRectMake(16, h * 0.6, w - 32, h * 0.4);
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.detailTextLabel.textAlignment = NSTextAlignmentCenter;
}

- (void)refreshLyricHighlight {
    /*
     * ============ 11142664：闪退修复 ============
     *
     * 日志证据：切换歌词时闪退，三次都停在
     *   "NOWPLAYING lyric table built: 0 lines"
     *
     * 根因：reloadRowsAtIndexPaths / scrollToRowAtIndexPath
     * 没有做边界检查，lyricLines 为空或长度变化时会抛
     * NSInternalInconsistencyException（越界）导致闪退。
     *
     * 修法：每个索引操作前都校验范围，任何异常状态直接返回。
     */
    /*
     * 11142671：加诊断日志。
     * 用户反馈「歌词不动，一直卡在开头」，需要确认卡在哪一步。
     */
    static int sLyricDbg = 0;
    BOOL shouldLog = (sLyricDbg++ % 10 == 0);   /* 每 10 次打一次 */

    if (!self.showingLyric) {
        if (shouldLog) {
            MFCarPlayLogBoth(@"LYRIC skip: not showing");
        }
        return;
    }
    if (!self.lyricTable) {
        if (shouldLog) {
            MFCarPlayLogBoth(@"LYRIC skip: no table");
        }
        return;
    }

    NSInteger count = (NSInteger)self.lyricLines.count;
    if (count <= 0) {
        if (shouldLog) {
            MFCarPlayLogBoth(@"LYRIC skip: 0 lines");
        }
        return;                    /* 没有歌词，什么都不做 */
    }

    double prog = self.currentProgress;

    /* 找到当前行（严格限制在 0..count-1） */
    NSInteger target = 0;
    for (NSInteger k = 0; k < count; k++) {
        NSDictionary *line = self.lyricLines[(NSUInteger)k];
        double tt = [line[@"time"] isKindOfClass:[NSNumber class]]
            ? [line[@"time"] doubleValue] : 0;
        if (tt <= prog) {
            target = k;
        } else {
            break;
        }
    }

    /* 三重校验，任何一条不满足都直接退出，绝不越界 */
    if (target < 0 || target >= count) {
        return;
    }
    /*
     * 11142671：首次必须滚动。
     *
     * 原逻辑 target == currentLyricIndex 就 return，
     * 但初值是 0，第 0 行时永远不滚 -> 一直卡在开头。
     * 改成：只有「不是首次」且「行没变」才跳过。
     */
    if (target == self.currentLyricIndex && self.currentLyricIndex >= 0) {
        return;
    }

    /* 刷新前再确认一次表格行数一致（防止 reloadData 竞态） */
    NSInteger rowCount = [self.lyricTable numberOfRowsInSection:0];
    if (rowCount != count) {
        /* 表格还没同步，只 reloadData 不滚动 */
        [self.lyricTable reloadData];
        self.currentLyricIndex = target;
        return;
    }

    NSInteger old = self.currentLyricIndex;
    self.currentLyricIndex = target;

    /* 只刷变化的行，且每个索引都校验 */
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    if (old >= 0 && old < count) {
        [paths addObject:[NSIndexPath indexPathForRow:old inSection:0]];
    }
    if (target >= 0 && target < count) {
        [paths addObject:[NSIndexPath indexPathForRow:target inSection:0]];
    }
    if (paths.count > 0) {
        @try {
            [self.lyricTable reloadRowsAtIndexPaths:paths
                                   withRowAnimation:UITableViewRowAnimationNone];
        } @catch (NSException *e) {
            MFCarPlayLogBoth(@"LYRIC reloadRows threw: %@", e.reason);
            [self.lyricTable reloadData];
        }
    }

    /* 滚动同样加保护 */
    if (target >= 0 && target < count) {
        @try {
            [self.lyricTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:target inSection:0]
                                   atScrollPosition:UITableViewScrollPositionMiddle
                                           animated:YES];
            MFCarPlayLogBoth(@"LYRIC scroll to row %ld (prog=%.1f, total=%ld)",
                  (long)target, prog, (long)count);
        } @catch (NSException *e) {
            MFCarPlayLogBoth(@"LYRIC scrollTo threw: %@", e.reason);
        }
    }
}


/* 收到歌词推送时刷新 */
- (void)handleLyricUpdate:(NSNotification *)note {
    NSArray *lines = note.userInfo[@"lines"];
    if (![lines isKindOfClass:[NSArray class]]) {
        return;
    }
    self.lyricLines = lines;
    self.currentLyricIndex = -1;
    if (self.lyricTable) {
        [self.lyricTable reloadData];
        [self refreshLyricHighlight];
    }
    MFCarPlayLogBoth(@"NOWPLAYING lyric updated: %lu lines", (unsigned long)lines.count);
}

/* 11142668：移除观察者 + 取消待执行的定时器，防止野指针闪退 */
- (void)dealloc {
    /* 11142669：停止轮询 */
    if (self.progressPollTimer) {
        [self.progressPollTimer invalidate];
        self.progressPollTimer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    MFCarPlayLogBoth(@"NOWPLAYING dealloc");
}

@end




