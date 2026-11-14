"""CarPlay Phase 1 综合静态校验"""
import io
import os
import plistlib
import re
import subprocess
import sys
from collections import Counter

ROOT = r"C:\Users\Alone\Downloads\Telegram Desktop\MusicFree-iOS"
ok = True


def chk(name, cond, detail=""):
    global ok
    print(f"  [{'OK ' if cond else 'NG '}] {name} {detail.encode('ascii','replace').decode('ascii')}")
    if not cond:
        ok = False


# 1) 原生桥
bh = io.open(os.path.join(ROOT, "ios", "MusicFree", "CarPlayBridge.h"), encoding="utf-8").read()
bm = io.open(os.path.join(ROOT, "ios", "MusicFree", "CarPlayBridge.m"), encoding="utf-8").read()
chk("CarPlayBridge 是 RCTEventEmitter", "RCTEventEmitter" in bh and "RCTBridgeModule" in bh)
chk("supportedEvents 含 3 个事件", all(x in bm for x in ["CarPlayPlayTrack", "CarPlayRequestTracks", "CarPlayControl"]))
chk("JS->车机 3 个导出方法", all(x in bm for x in ["setSheets:", "setTracks:", "setNowPlaying:"]))
chk("车机->JS 3 个类方法", all(x in bm for x in ["emitPlayTrack", "emitRequestTracks", "emitControl"]))
chk("用 NSNotificationCenter 解耦", "NSNotificationCenter" in bm)
chk("冷启动 pending 事件重放", "sPendingEvents" in bm and "flushPendingEvents" in bm)
chk("桥暴露 JS 就绪冲刷", "carPlayJSReady" in bm)

# 2) CarPlaySceneDelegate
ch = io.open(os.path.join(ROOT, "ios", "MusicFree", "CarPlaySceneDelegate.h"), encoding="utf-8").read()
cm = io.open(os.path.join(ROOT, "ios", "MusicFree", "CarPlaySceneDelegate.m"), encoding="utf-8").read()
# 去注释后的纯代码，用于负向断言（注释里允许出现日志原文）
cm_code = re.sub(r"/\*[\s\S]*?\*/", "", cm)
cm_code = re.sub(r"//.*$", "", cm_code, flags=re.M)
# refreshRootSections 的独立函数体，用于确认推送闸门不依赖 completion
_refresh_match = re.search(r"-\s*\(void\)\s*refreshRootSections\s*\{([\s\S]*?)\n\}\n", cm_code)
_refresh_body = _refresh_match.group(1) if _refresh_match else ""
chk("用 CPListItem.handler（稳定 API）", "item.handler" in cm)
chk("不用 CPListTemplateDelegate（签名差异）", "didSelectListItem" not in cm)
chk("原生占位首屏", "placeholderSections" in cm and "正在加载歌单" in cm)
chk("root 幂等 + animated:NO", "installRootIfNeeded" in cm and "_rootInstalledFor == ic" in cm and "animated:NO" in cm)
chk("root 带 completion", "setRootTemplate:list" in cm and "completion:^" in cm and "BOOL success" in cm)
chk("watchdog 只诊断不重装（无风暴标记）",
    "scheduleRootWatchdogForController" in cm
    and "applied=0 inFlight=" in cm
    and "rearm exhausted" in cm
    and "root watchdog fired" not in cm_code)
chk("root 成功标记 _rootApplied", "_rootApplied" in cm and "self->_rootApplied = YES" in cm)
chk("一连接只装一次 root（不死循环重发）",
    "one-shot root install armed" in cm_code
    and "no retry (waiting framework)" in cm_code
    and "retry anyway" not in cm_code
    and "attempts exhausted" not in cm_code)
chk("生命周期不重装 root", "keep root, no reinstall" in cm_code
    and "retry install" not in cm_code)
chk("不靠 completion 判定成功（framework 真相）",
    "syncAppliedStateFromFramework" in cm_code
    and "framework confirms root is top" in cm_code)
# --- 11142616 新增：同步 XPC 隔离（真凶修复） ---
_install_match = re.search(r"-\s*\(void\)\s*installRootIfNeeded\s*\{([\s\S]*?)\n\}\n", cm_code)
_install_body = _install_match.group(1) if _install_match else ""
_sync_match = re.search(r"-\s*\(BOOL\)\s*syncAppliedStateFromFramework\s*\{([\s\S]*?)\n\}\n", cm_code)
_sync_body = _sync_match.group(1) if _sync_match else ""
_attach_match = re.search(
    r"attachInterfaceController:\(CPInterfaceController \*\)interfaceController\s*\n"
    r"\s*scene:\(CPTemplateApplicationScene \*\)scene\s*\n\{([\s\S]*?)\n\}\n",
    cm_code)
_attach_body = _attach_match.group(1) if _attach_match else ""
chk("syncAppliedStateFromFramework 有 _templateReady 硬门",
    "_templateReady" in cm_code
    and "if (!_templateReady)" in _sync_body
    and "topTemplate" in _sync_body)
chk("installRootIfNeeded 内零 topTemplate 同步读",
    "topTemplate" not in _install_body)
chk("didConnect 内零 topTemplate 同步读",
    _attach_body != "" and "topTemplate" not in _attach_body)
chk("didConnect 异步化（不阻塞握手）",
    "dispatch_async" in _attach_body)
chk("watchdog 第一轮解锁同步探针",
    "sync probe unlocked" in cm_code and "_templateReady = YES" in cm_code)
# --- 受限 rearm 规格（3s 窗口 / 2 次上限 / 静默失败计数 / exhausted 停止） ---
chk("rearm 上限常量为 2",
    "kMFMaxRearm = 2" in cm_code)
chk("rearm 回传窗口为 3 秒",
    "kMFInstallSettleWindow = 3.0" in cm_code
    and "rootInstallTimedOut" in cm_code)
chk("rearm 前先清 inFlight（否则被旧标志挡住）",
    "self->_rootInstallInFlight = NO;" in cm_code
    and "_rearmCount += 1" in cm_code
    and "_rearmPending = YES" in cm_code
    and "rearm #%lu/%lu" in cm_code)
chk("rearm 每次用全新 CPListTemplate",
    "installRootIfNeededAllowRearm" in cm_code
    and "fresh template" in cm_code
    and "CPListTemplate alloc] initWithTitle:@\"音乐\"" in cm_code)
chk("rearm 静默失败按 3s 判定（不能只等 completion）",
    "silently failed" in cm_code
    and "_rearmPending && timedOut" in cm_code)
chk("首发不提前 rearm（等自己的 3s 窗口）",
    "initial install still settling, wait" in cm_code
    and "initialSettling" in cm_code)
chk("rearm exhausted 后停止 polling",
    "rearm exhausted" in cm_code
    and "stop polling" in cm_code
    and "_rootExhausted = YES" in cm_code)
chk("stale controller 调用包了 @try（防闪退，非死循环解药）",
    "@catch (NSException *ex)" in cm_code
    and "threw on stale controller" in cm_code
    and "@try 只挡" in cm)
# --- ① @try 定位必须写清是防闪退保险 ---
chk("@try 文档定位为防闪退保险，不冒充死循环解法",
    "保护不了 completion 永远不回" in cm
    and "3s" in cm)
# --- ③ generation token 防晚到 completion 竞态 ---
chk("generation token 丢弃晚到 completion",
    "_rootGeneration" in cm_code
    and "stale completion dropped" in cm_code
    and "token != self->_rootGeneration" in cm_code)
# --- ② controller 失效直接 exhausted，不浪费次数 ---
chk("controller 失效直接 exhausted 不消耗次数",
    "_controllerInvalidated" in cm_code
    and "controller invalidated, stop polling" in cm_code
    and "controller already invalidated, no more attempts" in cm_code)
# --- 回归防护：didConnect 必须无条件把 controller 置回有效 ---
_attach_full = re.search(
    r"attachInterfaceController:\(CPInterfaceController \*\)interfaceController\s*\n"
    r"\s*scene:\(CPTemplateApplicationScene \*\)scene\s*\n\{([\s\S]*?)\n\}\n",
    cm_code)
_attach_full_body = _attach_full.group(1) if _attach_full else ""
chk("didConnect 无条件重置 _controllerInvalidated = NO（重连不被误判死）",
    "_controllerInvalidated = NO;" in _attach_full_body
    # 必须在 if (_rootInstalledFor != ...) 之前，不能关在块内
    and _attach_full_body.index("_controllerInvalidated = NO;")
        < _attach_full_body.index("if (_rootInstalledFor != interfaceController)"))
chk("3a 分支不与在途 rearm 抢夺（加 !_rearmPending）",
    "self->_controllerInvalidated && !self->_rootApplied && !self->_rearmPending" in cm_code)
chk("rearm 成功路径显式置 _templateReady=YES",
    "self->_templateReady = YES;" in cm_code)
# --- ⑤ 同步异常计入 rearm 计数 ---
chk("同步异常计入 rearm 次数",
    "rearm #%lu threw" in cm_code)
# --- ④ rearm 成功后重新推数据 ---
chk("rearm 成功后重新推 sections",
    "rearm succeeded, repush sections to fresh template" in cm_code
    and "initial root succeeded, push sections" in cm_code)
# --- ⑥ didConnect 打印新旧 controller 地址 ---
chk("didConnect 打印新旧 controller 地址",
    "didConnect ctrl new=%p old=%p same=%d" in cm_code)
# --- ⑦ 文档写明实际最早 rearm 是 4.5s ---
chk("文档写明实际最早 rearm 是 4.5s",
    "实际最早 rearm 时刻是 **4.5s**" in cm)
chk("pushTracks 握手未结算时拒绝",
    "template handshake not settled yet" in cm_code)
chk("updateSections 不再被二次自锁（completion 成功即推）",
    "if (!_rootApplied)" in _refresh_body
    and "syncAppliedStateFromFramework" in _refresh_body)
chk("watchdog 轮询核对而非一次性放弃",
    "round:(NSUInteger)round" in cm_code and "kMFWatchdogRounds" in cm_code)
chk("scene 生命周期重绑 controller", "recoverTemplateScene" in cm and "sceneDidBecomeActive" in cm and "interfaceControllerFromScene" in cm)
chk("点歌单 push", "pushTracksForSheet" in cm)
chk("点曲目发播放事件", "emitPlayTrack" in cm)
chk("数据到达只 updateSections", "handleDataUpdate" in cm and "updateSections" in cm and "rebuildRoot" not in cm)
chk("同一连接不重建 root", "root already installed, updateSections only" in cm)
chk("observer 幂等注册", "sDataObserverToken" in cm and "registerDataObserverIfNeeded" in cm)
chk("disconnect 配对清理", "unregisterDataObserver" in cm and "didDisconnectInterfaceController" in cm)
chk("无老危险 init 签名", "initWithText:detailText:image:accessoryType:" not in cm_code)
# 11142616 起已删除 didConnect 期间的 topTemplate 接管分支（它就是打断连接的元凶）
chk("已移除 didConnect 期 topTemplate 接管分支", "adopt without setRootTemplate" not in cm_code)

# 3) pbxproj
pbx = io.open(os.path.join(ROOT, "ios", "MusicFree.xcodeproj", "project.pbxproj"), encoding="utf-8").read()
chk("CarPlayBridge.m in Sources", "CarPlayBridge.m in Sources" in pbx)
chk("CarPlaySceneDelegate.m in Sources", "CarPlaySceneDelegate.m in Sources" in pbx)
defs = re.findall(r'^\s*([A-F0-9]{24}) /\*.*?\*/ = \{isa = ', pbx, re.M)
dup = [k for k, v in Counter(defs).items() if v > 1 and k.startswith("C4A9C9")]
chk("新 UUID 定义唯一", len(dup) == 0, str(dup[:3]))

# 4) JS 层
js = io.open(os.path.join(ROOT, "src", "core", "carPlay", "index.ts"), encoding="utf-8").read()
chk("JS 用 NativeEventEmitter", "NativeEventEmitter" in js)
chk("JS 订阅 3 事件", all(x in js for x in ["CarPlayRequestTracks", "CarPlayPlayTrack", "CarPlayControl"]))
chk("JS 推 setSheets/setTracks/setNowPlaying", all(x in js for x in ["setSheets", "setTracks", "setNowPlaying"]))
chk("JS 调 playWithReplacePlayList", "playWithReplacePlayList" in js)
chk("JS 非 iOS 静默降级", "Platform.OS === \"ios\"" in js)
chk("JS 幂等 setup", "started" in js)
chk("JS 就绪冲刷 + 首次推歌单", "carPlayJSReady" in js and "pushSheets()" in js)

# 5) musicSheet 新方法
ms = io.open(os.path.join(ROOT, "src", "core", "musicSheet", "index.ts"), encoding="utf-8").read()
chk("getAllSheetsForCarPlay", "getAllSheetsForCarPlay" in ms)
chk("getTracksForCarPlay", "getTracksForCarPlay" in ms)
chk("findMusicItemForCarPlay", "findMusicItemForCarPlay" in ms)

# 6) bootstrap 挂载
bs = io.open(os.path.join(ROOT, "src", "entry", "bootstrap", "bootstrap.ts"), encoding="utf-8").read()
chk("bootstrap import setupCarPlay", 'from "@/core/carPlay"' in bs)
chk("bootstrap 调 setupCarPlay()", "setupCarPlay()" in bs)

# 7) 方案 F 仍保持（主 App 不黑屏）
pl = plistlib.load(open(os.path.join(ROOT, "ios", "MusicFree", "Info.plist"), "rb"))
cfgs = (pl.get("UIApplicationSceneManifest") or {}).get("UISceneConfigurations", {})
w = cfgs.get("UIWindowSceneSessionRoleApplication", [{}])
c = cfgs.get("CPTemplateApplicationSceneSessionRoleApplication", [{}])
chk("主场景 delegateClass=AppDelegate", w and w[0].get("UISceneDelegateClassName") == "AppDelegate")
chk("CarPlay delegateClass=MFCarPlaySceneDelegate", c and c[0].get("UISceneDelegateClassName") == "MFCarPlaySceneDelegate")
chk("允许多场景（CarPlay + 主界面共存）",
    (pl.get("UIApplicationSceneManifest") or {}).get("UIApplicationSupportsMultipleScenes") is True)
ad = io.open(os.path.join(ROOT, "ios", "MusicFree", "AppDelegate.mm"), encoding="utf-8").read()
chk("AppDelegate 按 role 分发 scene 配置",
    "configurationForConnectingSceneSession" in ad
    and "CPTemplateApplicationSceneSessionRoleApplication" in ad
    and "[MFCarPlaySceneDelegate class]" in ad)

# 8) 既有自检
r = subprocess.run(["node", "scripts/verify-ios-patch.mjs"], cwd=ROOT, capture_output=True, timeout=120)
out = (r.stdout or b"").decode("utf-8", errors="replace")
chk("verify-ios-patch 11/11", "11/11" in out, " ".join(out.strip().split("\n")[-2:]))

print()
print("=" * 50)
print("Phase 1 static check:", "ALL PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
