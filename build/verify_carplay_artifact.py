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

EXPECTED_VERSION = "11142623"
EXPECTED_BUNDLE_ID = "app.musicfree.ios"

BINARY_MARKERS = [
    b"connected (phase1)",
    b"native placeholder root installed",
    b"setRootTemplate success",
    b"one-shot root install armed",
    b"no retry (waiting framework)",
    b"keep root, no reinstall",
    b"framework confirms root is top",
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
    b"stale completion dropped",
    b"rearm succeeded, repush sections to fresh template",
    b"initial root succeeded, push sections",
    b"didConnect ctrl new=%p old=%p same=%d",
    b"didConnect WITH CPWindow=%p ctrl=%p",
    b"carWindow attached & key",
    b"pushing anyway",
    b"data ready sections=",
    b"applied via framework check",
    b"recoverTemplateScene",
    b"rebind controller",
    b"carPlayJSReady",
    b"flush pending",
    b"requestSheets retry",
    b"CarPlayPlayTrack",
    b"CarPlayRequestTracks",
    b"MFCarPlayDataDidUpdate",
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
        car_role = cfgs.get("CPTemplateApplicationSceneSessionRoleApplication") or [{}]
        main_delegate = main_role[0].get("UISceneDelegateClassName", "")
        car_delegate = car_role[0].get("UISceneDelegateClassName", "")
        print(f"MainDelegate={main_delegate}")
        print(f"CarPlayDelegate={car_delegate}")
        if main_delegate != "AppDelegate":
            fail("main scene delegate mismatch")
        if car_delegate != "MFCarPlaySceneDelegate":
            fail("CarPlay scene delegate mismatch")

        binary = read_entry(zf, bin_path)
        missing_binary = [m.decode("ascii", "replace") for m in BINARY_MARKERS if m not in binary]
        print(f"BinaryMarkers={len(BINARY_MARKERS) - len(missing_binary)}/{len(BINARY_MARKERS)}")
        if missing_binary:
            fail("binary markers missing: " + ", ".join(missing_binary))

        present_old = [m.decode("ascii", "replace") for m in FORBIDDEN_BINARY_MARKERS if m in binary]
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

    print("ARTIFACT_OK")


if __name__ == "__main__":
    main()
