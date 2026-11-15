/*
 * CarPlaySceneDelegate.m — MINIMAL DEMO BUILD (11142638-demo)
 * ============================================================
 *
 * 目的：用最小可复现代码判定「问题在业务代码」还是「问题在环境/签名层」。
 *
 * 背景：11142637 的真机日志给出了决定性证据 ——
 *
 *   TOP-TEMPLATE PROBE: mainThread=1 top=0x0 class=(nil)
 *                       ourRoot=0x2826bb5c0 match=0 templates=0 [(empty)]
 *
 * 我们前后调用了 12 次 setRootTemplate，controller 内部 templates 恒为 0。
 * 不是"提交了没渲染"，也不是"渲染了没回调"，而是提交从未进入 controller。
 *
 * 已逐项排除的 App 侧因素（每个都试过、都无效）：
 *   topTemplate 同步读 / completion 机制 / CPWindow / UISceneClassName /
 *   CPNowPlayingTemplate / AVAudioSession / 模板内容校验 / sceneClass
 *
 * 本文件刻意只保留**最低限度**的代码：
 *   1) didConnectInterfaceController: 里建一个空 CPListTemplate
 *   2) 立刻 setRootTemplate（主线程、同步、completion:nil）
 *   3) 打日志（含 topTemplate 探针）
 *   4) didDisconnect 清理
 *
 * 刻意**不含**：MMKV、原生数据、CarPlayBridge、AVAudioSession、
 *               CPNowPlayingTemplate、watchdog、rearm、指纹、观察者。
 *
 * 结果判读：
 *   A) 日志出现 templateDidAppear 或 TOP-TEMPLATE 里 templates>0
 *      -> Demo 能上屏，说明问题在业务代码某一处，回到全量实现二分定位
 *   B) 日志仍是 top=0x0 templates=0
 *      -> 连最小 Demo 都无法提交模板，锁定环境/签名层，
 *         业务代码不用再改，转而验证有线 CarPlay 或 TrollStore 签名
 *
 * 类名保持 MFCarPlaySceneDelegate 不变 —— Info.plist 里的
 * UISceneDelegateClassName 和 AppDelegate 里的 delegateClass 都指向它，
 * 这样本次实验**不改任何其他文件**，变量唯一。
 */

#import "CarPlaySceneDelegate.h"
#import "MFCarPlayLog.h"

@interface MFCarPlaySceneDelegate () <CPInterfaceControllerDelegate>
/* interfaceController 已在 .h 中声明，这里不重复 */
@property (nonatomic, strong, nullable) CPListTemplate *demoList;
@end

@implementation MFCarPlaySceneDelegate

#pragma mark - CPTemplateApplicationSceneDelegate

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didConnectInterfaceController:(CPInterfaceController *)interfaceController
{
    MFCarPlayLogBoth(@"[Demo] didConnect ctrl=%p", (__bridge void *)interfaceController);

    self.interfaceController = interfaceController;

    /* 注册 delegate，用于捕获 templateDidAppear 这个权威信号 */
    interfaceController.delegate = self;

    /*
     * 最小模板：一个空 CPListTemplate。
     * 不设 emptyViewTitleVariants、不设 sections。
     * 如果连这个都无法被接受，就与内容无关。
     */
    CPListTemplate *list = [[CPListTemplate alloc] initWithTitle:@"TEST" sections:@[]];
    self.demoList = list;

    /* 同步、主线程、completion:nil —— 与参考实现完全一致的调用形态 */
    @try {
        [interfaceController setRootTemplate:list animated:NO completion:nil];
    } @catch (NSException *e) {
        MFCarPlayLogBoth(@"[Demo] setRootTemplate THREW: %@", e.reason);
    }

    /*
     * ★ 唯一判据：setRootTemplate 返回后**立刻**读 topTemplate / templates。
     *
     * setRootTemplate 是同步设置 top 的，completion 才是异步。
     * 正常调用后 topTemplate 应立即变成 list、templates.count 应为 1。
     *
     *   top=0x... templates=1  -> 业务代码问题，回正式版二分定位
     *   top=0x0   templates=0  -> 连 154 行 Demo 都提交不进 controller，
     *                              签名/环境问题坐实，业务代码无解
     *
     * 刻意不做 dispatch_after 延迟探测 —— 那会引入"握手结算"这个额外变量。
     */
    CPTemplate *immediateTop = interfaceController.topTemplate;
    NSUInteger immediateCount = interfaceController.templates.count;
    MFCarPlayLogBoth(@"[Demo] after setRoot: top=%p templates=%lu ourList=%p",
          (__bridge void *)immediateTop,
          (unsigned long)immediateCount,
          (__bridge void *)list);
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene
    didDisconnectInterfaceController:(CPInterfaceController *)interfaceController
{
    MFCarPlayLogBoth(@"[Demo] didDisconnect ctrl=%p", (__bridge void *)interfaceController);
    if (interfaceController.delegate == self) {
        interfaceController.delegate = nil;
    }
    self.interfaceController = nil;
    self.demoList = nil;
}

#pragma mark - CPInterfaceControllerDelegate

- (void)templateDidAppear:(CPTemplate *)template animated:(BOOL)animated
{
    BOOL isOurs = (template == (CPTemplate *)self.demoList);
    MFCarPlayLogBoth(@"!!! [Demo] templateDidAppear template=%p isOurs=%d animated=%d",
          (__bridge void *)template, isOurs, animated);
}

- (void)templateWillAppear:(CPTemplate *)template animated:(BOOL)animated
{
    MFCarPlayLogBoth(@"[Demo] templateWillAppear template=%p", (__bridge void *)template);
}

- (void)templateWillDisappear:(CPTemplate *)template animated:(BOOL)animated
{
    MFCarPlayLogBoth(@"[Demo] templateWillDisappear template=%p", (__bridge void *)template);
}

- (void)templateDidDisappear:(CPTemplate *)template animated:(BOOL)animated
{
    MFCarPlayLogBoth(@"[Demo] templateDidDisappear template=%p", (__bridge void *)template);
}

@end
