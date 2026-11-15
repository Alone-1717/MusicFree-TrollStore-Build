#import "AppDelegate.h"
#import "CarPlaySceneDelegate.h"

#import <CarPlay/CarPlay.h>
#import <React/RCTBundleURLProvider.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  self.moduleName = @"MusicFree";
  // You can add your custom initial props in the dictionary below.
  // They will be passed down to the ViewController used by React Native.
  self.initialProps = @{};

  // RCTAppDelegate 在这里用 legacy 方式建好 window + RN rootView。
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  return [self bundleURL];
}

- (NSURL *)bundleURL
{
#if DEBUG
  return [[RCTBundleURLProvider sharedSettings] jsBundleURLForBundleRoot:@".expo/.virtual-metro-entry"];
#else
  return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
#endif
}

#pragma mark - Scene 配置（多场景开启后按 role 显式分发）

/*
 * UIApplicationSupportsMultipleScenes = YES 之后，系统同时持有
 * 主界面 UIWindowScene 和 CarPlay CPTemplateApplicationScene。
 * 必须显式给每个 role 返回配置，否则 CarPlay 场景会落到主 App 的
 * AppDelegate 上（它不实现 CPTemplateApplicationSceneDelegate），
 * 结果是模板场景没有 delegate => 车机黑屏。
 */
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0))
{
    NSString *role = connectingSceneSession.role;

    /*
     * ============ 11142639：完全交给 Info.plist（kumone 的做法）============
     *
     * 十轮演进到这里，程序化构造 config 的所有变体都试过了：
     *   - 只设 delegateClass            -> 半连接（11142635 及之前）
     *   - 补 sceneClass                 -> 仍半连接（11142636/11142637）
     *   - 空模板 + sceneClass           -> 仍半连接（11142638 Demo 实证）
     *
     * 而参考实现（missuo/kumone，上架 App Store 的 CarPlay 音频 App）
     * 全文 **0 次** 实现 configurationForConnectingSceneSession /
     * UISceneConfiguration —— 它完全依赖 Info.plist 的
     * UISceneConfigurations 让系统自己查表。
     *
     * 返回 nil 的语义（UIKit 文档）：系统会去 Info.plist 的
     * UIApplicationSceneManifest -> UISceneConfigurations 里，
     * 按 connectingSceneSession.role 查找匹配的配置项并使用它。
     * 这样 UISceneClassName / UISceneDelegateClassName 全部由 plist 决定，
     * 零手工干预，和 kumone 完全一致。
     *
     * 我们当前 Info.plist 已确认配置完整：
     *   CPTemplateApplicationSceneSessionRoleApplication -> {
     *     UISceneConfigurationName    = "CarPlay"
     *     UISceneClassName            = "CPTemplateApplicationScene"
     *     UISceneDelegateClassName    = "MFCarPlaySceneDelegate"
     *   }
     *   UIWindowSceneSessionRoleApplication -> {
     *     UISceneConfigurationName    = "Default Configuration"
     *     UISceneDelegateClassName    = "AppDelegate"
     *   }
     *
     * 唯一变量：从"程序构造 config"改为"让 plist 查表"。
     */
    NSLog(@"[MusicFree] scene config -> delegate to Info.plist for role=%@", role);
    return nil;
}

#pragma mark - UISceneDelegate (main app window)

/*
 * 方案 F：主 App 的 key window 接入 UIScene。
 *
 * 真机日志 v11142006 决定性证据：
 *   currentApplicationKeyWindow: 0x0
 *   evaluatedKeyWindowScene: <UIWindowScene 0x15df14e00>
 *   -> 系统创建了场景，但 RN 在 didFinishLaunching 里建的 legacy window
 *      没有关联到该场景，系统不认它是 key window，于是黑屏。
 *
 * 逐版复盘：
 *   v17        无 SceneManifest + AppDelegate 不实现任何 scene 方法
 *              -> UIKit 的 legacy 兼容逻辑把 UIApplicationDelegate.window
 *                 自动 attach 到默认 UIWindowScene -> 正常显示
 *   v11141849  声明主场景但没 delegateClass -> 没人负责 window -> 黑
 *   v11141931  写了 willConnect 但没 delegateClass -> 方法没被调用 -> 黑
 *   v11142006  实现 configurationForConnecting 对主场景 return nil
 *              -> 系统视为 scene-aware，legacy 自动 attach 被跳过，
 *                 而 nil 配置又没建出 window -> 黑
 *
 * 方案 F 把每一环都钉死：
 *   Info.plist 主场景 UISceneDelegateClassName = AppDelegate
 *   -> 系统必定回调本方法（v11141931 就是缺这一步才没生效）
 *   -> 这里把真正的 AppDelegate 实例持有的 window 挂到场景。
 *
 * 关键坑：UISceneDelegateClassName 指向的类可能被 UIKit 单独实例化，
 *   所以不能用 self.window（可能是新实例、为 nil），必须取
 *   UIApplication.sharedApplication.delegate —— 那才是持有
 *   RCTAppDelegate 建好的 window 的实例。
 *
 * CarPlay 场景由 MFCarPlaySceneDelegate 处理，传的是
 * CPTemplateApplicationScene（非 UIWindowScene），不会进这里。
 */
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions API_AVAILABLE(ios(13.0))
{
  if (![scene isKindOfClass:[UIWindowScene class]]) {
    return;
  }
  UIWindowScene *windowScene = (UIWindowScene *)scene;

  __weak UIWindowScene *weakScene = windowScene;
  dispatch_block_t attach = ^{
    __strong UIWindowScene *ws = weakScene;
    if (!ws) {
      return;
    }
    // 取真正的 UIApplicationDelegate（持有 RN window 的实例）。
    // RCTAppDelegate 公开声明了 window 属性，直接强转即可，不用 performSelector。
    AppDelegate *realDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    UIWindow *win = realDelegate.window;
    if (win) {
      /*
       * 多场景开启后系统可能为 CarPlay/主界面各建一次连接回调。
       * 只在 window 尚未归属任何 scene（或本来就是本 scene）时 attach，
       * 避免把已经在主界面显示的 window 抢到另一个 scene 上。
       */
      if (win.windowScene && win.windowScene != ws) {
        NSLog(@"[MusicFree] skip attach: window already in another scene");
        return;
      }
      // 关键：把 RN 的 legacy window 关联到 UIWindowScene 并成为 key window
      [win setWindowScene:ws];
      [win makeKeyAndVisible];
      NSLog(@"[MusicFree] key window attached to scene: %@", win);
    } else {
      NSLog(@"[MusicFree] WARN: app window not ready yet");
    }
  };

  // didFinishLaunching 通常先于 willConnect，但保险起见两种情况都覆盖
  attach();
  dispatch_async(dispatch_get_main_queue(), attach);
}

@end
