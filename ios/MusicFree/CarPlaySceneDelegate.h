/*
 * CarPlaySceneDelegate.h — Phase 1
 * 车机界面：歌单列表 -> 曲目列表 -> 点播。
 *
 * ==================== 类型与方法分工（别再搞错） ====================
 *
 * CPTemplateApplicationSceneDelegate 有两个 didConnect 方法，分工是硬性的：
 *
 *   didConnectInterfaceController:            <- 模板类 App（音频/通讯/停车/充电）
 *   didConnectInterfaceController:toWindow:   <- 导航类 App（需要 CPWindow 画地图）
 *
 * MusicFree 是**音频 App**：界面完全由 CPListTemplate 承载，
 * 不画地图、不需要 CPWindow。系统按 carplay-audio entitlement 分配场景，
 * 永远走不带 window 的那条路径。
 *
 * 真机日志里那句
 *     "App supports CPTemplateApplicationScene method without window"
 * 是框架在陈述**正常状态**，不是错误，也不是缺了什么。
 *
 * 所以本类：
 *   - 只实现 didConnectInterfaceController:（模板路径）
 *   - 不持有 CPWindow，不调 setWindowScene: / makeKeyAndVisible
 *   - 不设 rootViewController（CPInterfaceController 是 NSObject，不是 UIViewController）
 *
 * ==================== 类型事实 ====================
 *   CPInterfaceController      : NSObject   —— 纯逻辑控制器，不是视图
 *   CPWindow                   : UIWindow   —— 仅导航 App 使用，本项目不碰
 *   CPTemplateApplicationScene : UIScene    —— 不是 UIWindowScene
 *
 * ==================== 成功判据 ====================
 *   模板真的上屏时，框架会调 CPInterfaceControllerDelegate 的
 *   templateDidAppear:animated: —— 这是唯一权威信号，
 *   比 setRootTemplate 的 completion（实测不回调）和 topTemplate 轮询都可靠。
 */
#import <Foundation/Foundation.h>
#import <CarPlay/CarPlay.h>

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(ios(14.0))
/*
 * ============ 11142640：同时实现两套 delegate 协议 ============
 *
 * 现在 Info.plist 里配了两条 CarPlay 路径，系统选中哪条不确定：
 *
 *   1) CPTemplateApplicationSceneSessionRoleApplication（传统模板路径）
 *        -> CPTemplateApplicationScene
 *        -> CPTemplateApplicationSceneDelegate
 *        -> templateApplicationScene:didConnectInterfaceController:
 *
 *   2) UIWindowSceneSessionRoleCarPlay（CarMovie 式，11142640 新增）
 *        -> UIWindowScene
 *        -> UISceneDelegate
 *        -> scene:willConnectToSession:options:
 *
 * 只实现第 1 套的话，一旦系统选中第 2 套，delegate 方法永不触发，
 * didConnect 会直接消失。所以两套都实现，哪条路来人就接哪条。
 */
@interface MFCarPlaySceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate,
                                                CPListTemplateDelegate,
                                                CPInterfaceControllerDelegate,
                                                UISceneDelegate>

@property (nonatomic, strong, nullable) CPInterfaceController *interfaceController;

/*
 * UIWindowSceneSessionRoleCarPlay 路径专用：车机上自建的窗口。
 * 该 role 由 UIWindowScene 实例化，不经过 CPInterfaceController，
 * 所以需要自己持有 window 并在其上画界面。
 */
@property (nonatomic, strong, nullable) UIWindow *carPlayWindow;

@end

NS_ASSUME_NONNULL_END
