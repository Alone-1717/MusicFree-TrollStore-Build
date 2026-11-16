#!/usr/bin/env python3
"""Verify the final CarPlay-stable TIPA/IPA artifact.

Checks:
  1. Payload/MusicFree.app/Info.plist is parsed as plist (binary plist safe)
  2. CFBundleIdentifier / CFBundleVersion / scene delegates
  3. Payload/MusicFree.app/MusicFree contains all native CarPlay markers
  4. embedded main.jsbundle contains the JS CarPlay-ready markers
  5. prints SHA256
"""
import argparse
import hashlib
import io
import plistlib
import sys
import zipfile
from pathlib import Path

EXPECTED_VERSION = "11142700"
EXPECTED_BUNDLE_ID = "app.musicfree.ios"

BINARY_MARKERS = [
    b"connected (phase1)",
    b"native placeholder root installed",
    b"one-shot root install armed",
    b"no retry (waiting framework)",
    b"keep root, no reinstall",
    b"applied=0 inFlight=",
    b"sync probe unlocked",
    b"carplay.1.log",
    b"MusicFree CarPlay log ",
    b"[native-data] %@",
    b"sheets from NATIVE",
    b"tracks from NATIVE",
    b"initial install still settling, wait",
    b"template handshake not settled yet",
    b"rearm #%lu/%lu",
    b"silently failed",
    b"rearm exhausted",
    b"threw on stale controller",
    b"controller invalidated, stop polling",
    b"controller already invalidated, no more attempts",
    b"didConnect ctrl new=%p old=%p same=%d",
    b"SYNC CONFIRM: topTemplate IS our root (via top-template check)",
    b"updateSections done root.sectionCount=",
    b"applied via sync-confirm path",
    b"didConnect ctrl=%p (template-only audio path)",
    b"ROOT TEMPLATE VISIBLE",
    b"templateDidAppear template=%p isList=",
    b"content unchanged, skip updateSections",
    b"CPInterfaceControllerDelegate registered",
    b"data ready sections=",
    b"recoverTemplateScene",
    b"rebind controller",
    b"carPlayJSReady",
    b"flush pending",
    b"requestSheets retry",
    b"CarPlayPlayTrack",
    b"CarPlayRequestTracks",
    b"MFCarPlayDataDidUpdate",
    b"dataSheets=",
    b"scene KVC interfaceController failed:",
    b"scene KVC interfaceController failed: %@ (%@)",
    b"EMPTY_SECTIONS_BUG",
    b"verdict=%s",
    b"RESET exhausted on scene reactivation",
    b"same controller, applied=0, framework still not confirming",
    b"ready=%d exhausted=%d",
    b"setRootTemplate dispatched (completion:nil)",
    b"dispatchRootTemplate on main thread, ok",
    b"WARN: dispatchRootTemplate on NON-MAIN thread",
    b"watchdog round=%lu: framework confirms root, push sections",
    b"AVAudioSession final: catOK=%d opts=%@ actOK=%d",
    b"AVAudioSession step1 (Playback+A2DP) FAILED",
    b"AVAudioSession step2 (Playback plain) FAILED",
    b"AVAudioSession setActive FAILED",
    b"CPNowPlayingTemplate factory found:",
    b"both factory candidates missing",
    b"NO_SECTIONCOUNT_API",
    b"ON-SCREEN CONTENT: sectionCount=%lu hasAPI=%d dataSheets=%lu",
    b"ON-SCREEN CONTENT: sectionCount=%lu hasAPI=%d dataSheets=%lu appliedBefore=%d sameAsRoot=%d verdict=%s",
    b"updateSections done root.sectionCount=%lu (probe=%d) pushed=%lu sheetsReceived=%d applied=%d",
    b"CPNowPlayingTemplate: both factory candidates missing",
    b"one-shot root install armed controller=%p (EMPTY template",
    b"fresh EMPTY template=%p, no sections yet",
    b"emptyViewTitleVariants set on root template",
    b"emptyViewTitleVariants NOT available on CPListTemplate",
    b"ROOT TEMPLATE VISIBLE -> applied=1, about to refresh",
    b"TOP-TEMPLATE PROBE: mainThread=%d top=%p class=%@ ourRoot=%p match=%d templates=%lu [%@]",
    b"scene config -> delegate to Info.plist for role=%@",
    b"SCENE willConnect class=%@ role=%@ mainThread=%d",
    b"SCENE willConnect: WINDOW PATH ACTIVE",
    b"SCENE willConnect: WINDOW PATH ACTIVE window=%p frame=%@ ",
    b"not a UIWindowScene (%@)",
    b"TRACKS VC: sheet=%@ title=%@ tracks=%lu",
    b"TRACKS tap row=%ld track=%@ sheet=%@",
    b"emitted CarPlayPlayTrack track=%@",
    b"WINDOW DATA UPDATE -> reload root table",
    b"history total = %lu (requested %lu)",
    b"search '%@' hits = %lu",
    b"NOWPLAYING VC: title=%@ artist=%@ album=%@ duration=%.0f",
    b"NOWPLAYING tap PREV",
    b"NOWPLAYING tap NEXT",
    b"NOWPLAYING cover loaded %lu bytes",
    b"ROOT search '%@' -> local=%lu jsReady=%d",
    b"ROOT sheets tap row=%ld sheet=%@",
    b"ROOT history tap row=%ld track=%@",
    b"ROOT search tap row=%ld track=%@",
    b"BRIDGE got %lu search results for '%@'",
    b"JS READY (sJSReady=1)",
    b"RN init: triggering from CarPlay scene",
    b"RN init: bridge %@",
    b"emitted CarPlaySearch '%@'",
    b"ROOT search '%@' -> local=%lu jsReady=%d",
    b"ROOT search: JS returned %lu results for '%@'",
    b"BRIDGE got %lu lyric lines",
    b"NOWPLAYING lyric table built: %lu lines",
    b"NOWPLAYING lyric updated: %lu lines",
    b"SEARCH kb: using built-in keyboard (system kb blocked by CarPlay)",
    b"ROOT tab -> %ld (0=sheets 1=search 2=toplist 3=history)",
    b"ROOT topLists loaded: %lu",
    b"TOPLIST VC: title=%@ listId=%@ plugin=%@",
    b"TOPLIST VC: loaded %lu tracks for '%@'",
    b"TOPLIST tap row=%ld track=%@",
    b"RELOAD(%@) threw: %@ -- %@",
    b"LYRIC reloadRows threw: %@",
    b"LYRIC scrollTo threw: %@",
    b"BRIDGE JS READY (sJSReady=1) -- JS runtime is up",
    b"RN start OK: bridge=%@ rootView=%@",
    b"RN start SKIP: rootViewFactory is nil",
    b"BRIDGE got %lu top lists",
    b"ROOT layout: screen=%.0fx%.0f scale=%.2f",
    b"CELL cover set threw: %@",
    b"NOWPLAYING cover set threw: %@",
    b"ROOT dealloc",
    b"TOPLIST dealloc",
    b"NOWPLAYING dealloc",
    b"SCENE DELEGATE dealloc",
    b"ROOT tab IGNORED: bad tag=%ld",
    b"NOWPLAYING progress poll started",
    b"NOWPLAYING content updated: %@ - %@",
    b"BRIDGE state: %@ - %@ playing=%@ pos=%@/%@",
    b"JS | %@",
    b"LYRIC scroll to row %ld",
    b"LYRIC skip: not showing",
    b"LYRIC skip: 0 lines",
    b"[POLL] tick #%d",
    b"[STATE] apply #%d",
    b"[TRACK] changed:",
    b"[TRACK] cover applied",
    b"[LYRIC] poll:",
    b"[LYRIC] table reloaded",
    b"[ACTION] favorite tapped",
    b"[ACTION] repeat tapped",
    b"[ACTION] play/pause tapped",
    b"[KEYBOARD] letter",
    b"[KEYBOARD] hidden by bg tap",
    b"[SEEK] tap at %.2f",
    b"lyric table built: %lu lines",
    b"favorite tapped (btn=%@)",
    b"[POLL] state step EXCEPTION: %@",
    b"NOWPLAYING progress poll started (GCD timer)",
    b"[POLL] dispatch_source_create FAILED",
    b"[POLL] GCD timer EXCEPTION: %@ -- %@",
    b"NOWPLAYING cancelled stale GCD timer",
    b"CRASH HANDLER installed",
    b"========== CRASH (ObjC Exception) ==========",
    b"NOWPLAYING handleNowPlayingState",
    b"NOWPLAYING state userInfo not dict",
    b"BRIDGE block EXCEPTION: %@ -- %@",
    b"AVAudioSession FINAL: catOK=%d",
    b"no nav and no presenter",
    b"shouldReceiveTouch",
]

# 旧版已证伪/致命的标记，产物里绝不能再出现
FORBIDDEN_BINARY_MARKERS = [
    b"retry anyway",
    b"attempts exhausted",
    b"root watchdog fired",
    # 11142616：didConnect 期 topTemplate 同步读是打断 template 连接的真凶
    b"adopt without setRootTemplate",
    b"framework already has topTemplate",
]

JS_MARKERS = [
    "carPlayJSReady",
    "CarPlayPlayTrack",
    "CarPlayRequestTracks",
    "CarPlayControl",
    "[CarPlay] JS bridge started",
]



def marker_present(binary, m):
    """CFString 常量编码探测。

    纯 ASCII 的 C 字符串以 UTF-8 落在 __cstring；
    含非 ASCII 字符（如 em dash —— ）的 NSString 常量会转成 UTF-16LE，
    只做 UTF-8 字节匹配会把它们全判成缺失。
    曾因此误报 "RESET exhausted..." 和 "WARN: template on screen ..." 两组标记。
    """
    if m in binary:
        return True
    try:
        if m.decode("utf-8").encode("utf-16-le") in binary:
            return True
    except Exception:
        pass
    return False

def fail(msg: str):
    print(f"FAIL: {msg}")
    sys.exit(1)


def read_entry(zf: zipfile.ZipFile, name: str) -> bytes:
    try:
        return zf.read(name)
    except KeyError:
        fail(f"missing zip entry {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", required=True)
    args = ap.parse_args()
    path = Path(args.path)
    if not path.is_file():
        fail(f"file missing: {path}")

    digest = hashlib.sha256(path.read_bytes()).hexdigest().upper()
    print(f"FILE={path}")
    print(f"BYTES={path.stat().st_size}")
    print(f"SHA256={digest}")

    with zipfile.ZipFile(path, "r") as zf:
        names = zf.namelist()
        info_path = "Payload/MusicFree.app/Info.plist"
        bin_path = "Payload/MusicFree.app/MusicFree"
        if info_path not in names:
            fail(f"missing {info_path}")
        if bin_path not in names:
            fail(f"missing {bin_path}")

        info = plistlib.loads(read_entry(zf, info_path))
        bundle_id = str(info.get("CFBundleIdentifier", ""))
        version = str(info.get("CFBundleVersion", ""))
        print(f"CFBundleIdentifier={bundle_id}")
        print(f"CFBundleVersion={version}")
        if bundle_id != EXPECTED_BUNDLE_ID:
            fail(f"bundle id mismatch: {bundle_id}")
        if version != EXPECTED_VERSION:
            fail(f"version mismatch: {version}")

        manifest = info.get("UIApplicationSceneManifest") or {}
        cfgs = manifest.get("UISceneConfigurations") or {}
        main_role = cfgs.get("UIWindowSceneSessionRoleApplication") or [{}]
        # 11142646：模板 role 已移除，CarPlay 入口改为 UIWindowSceneSessionRoleCarPlay
        car_role = cfgs.get("UIWindowSceneSessionRoleCarPlay") or [{}]
        main_delegate = main_role[0].get("UISceneDelegateClassName", "")
        car_delegate = car_role[0].get("UISceneDelegateClassName", "")
        print(f"MainDelegate={main_delegate}")
        print(f"CarPlayDelegate={car_delegate}")
        if main_delegate != "AppDelegate":
            fail("main scene delegate mismatch")
        if car_delegate != "MFCarPlaySceneDelegate":
            fail("CarPlay scene delegate mismatch")

        binary = read_entry(zf, bin_path)
        missing_binary = [m.decode("utf-8", "replace") for m in BINARY_MARKERS
                          if not marker_present(binary, m)]
        print(f"BinaryMarkers={len(BINARY_MARKERS) - len(missing_binary)}/{len(BINARY_MARKERS)}")
        if missing_binary:
            fail("binary markers missing: " + ", ".join(missing_binary))

        present_old = [m.decode("utf-8", "replace") for m in FORBIDDEN_BINARY_MARKERS if marker_present(binary, m)]
        print(f"ForbiddenMarkers={len(present_old)}")
        if present_old:
            fail("legacy reinstall-loop markers still present: " + ", ".join(present_old))

        js_candidates = [n for n in names if n.endswith("main.jsbundle")]
        if not js_candidates:
            fail("embedded main.jsbundle missing")
        js_name = js_candidates[0]
        js = read_entry(zf, js_name).decode("utf-8", errors="ignore")
        missing_js = [m for m in JS_MARKERS if m not in js]
        print(f"JSBundle={js_name}")
        print(f"JSMarkers={len(JS_MARKERS) - len(missing_js)}/{len(JS_MARKERS)}")
        if missing_js:
            fail("JS markers missing: " + ", ".join(missing_js))

        # 11142646：CarPlay 图标资源必须打进 bundle（CarMovie 同款命名）
    icon_missing = []
    for _ic in ("CarPlayIcon120x120.png", "CarPlayIcon180x180.png"):
        if not any(n.endswith(_ic) for n in names):
            icon_missing.append(_ic)
    if icon_missing:
        fail("CarPlay icon missing in bundle: " + ", ".join(icon_missing))
    else:
        print("CarPlayIcons=2/2")

print("ARTIFACT_OK")


if __name__ == "__main__":
    main()
