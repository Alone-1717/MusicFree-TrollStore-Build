import argparse
import io
import os
import plistlib
import sys
import zipfile

"""
verify_carplay_demo.py — 最小 CarPlay Demo 的产物校验。

与全量版 verify_carplay_artifact.py 分开，因为 Demo 只有 154 行实现，
不含全量版的 69 个标记。这里只校验 Demo 必须的几项。

判据：
  1) 版本号 / bundle id / delegate 类名
  2) Demo 关键日志字符串都在二进制里（UTF8 或 UTF16LE）
  3) Info.plist 三件套齐全
  4) 无危险项
  5) JS bundle 存在
"""


def marker_present(binary, m):
    if m in binary:
        return True
    try:
        if m.decode("utf-8").encode("utf-16-le") in binary:
            return True
    except Exception:
        pass
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", required=True)
    args = ap.parse_args()

    path = args.path
    if not os.path.isfile(path):
        print("FAIL: file not found: " + path)
        return 1

    errors = []
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        bin_path = "Payload/MusicFree.app/MusicFree"
        info_path = "Payload/MusicFree.app/Info.plist"
        if bin_path not in names:
            print("FAIL: binary missing")
            return 1
        binary = z.read(bin_path)
        info = plistlib.loads(z.read(info_path))

    print("FILE=" + path)
    print("BYTES=" + str(os.path.getsize(path)))

    import hashlib
    with open(path, "rb") as f:
        print("SHA256=" + hashlib.sha256(f.read()).hexdigest().upper())

    ver = info.get("CFBundleVersion")
    bid = info.get("CFBundleIdentifier")
    print("CFBundleIdentifier=" + str(bid))
    print("CFBundleVersion=" + str(ver))
    if ver != "11142638":
        errors.append("version mismatch: " + str(ver))
    if bid != "app.musicfree.ios":
        errors.append("bundle id mismatch")

    print()
    print("=== Demo 关键日志 ===")
    demo_markers = [
        b"[Demo] didConnect ctrl=%p",
        b"[Demo] after setRoot: top=%p templates=%lu ourList=%p",
        b"[Demo] setRootTemplate THREW: %@",
        b"!!! [Demo] templateDidAppear template=%p isOurs=%d animated=%d",
        b"[Demo] didDisconnect ctrl=%p",
    ]
    found = 0
    for m in demo_markers:
        ok = marker_present(binary, m)
        print(("  HAS " if ok else "  MISS") + " " + m.decode("ascii", "replace")[:60])
        if ok:
            found += 1
        else:
            errors.append("demo marker missing: " + m.decode("ascii", "replace"))
    print("DemoMarkers=%d/%d" % (found, len(demo_markers)))

    print()
    print("=== Info.plist ===")
    ip_bytes = io.BytesIO()
    plistlib.dump(info, ip_bytes)
    ipb = ip_bytes.getvalue()
    for k in [b"UISceneClassName", b"CPTemplateApplicationScene", b"UISupportsCarPlay"]:
        ok = k in ipb
        print(("  HAS " if ok else "  MISS") + " " + k.decode())
        if not ok:
            errors.append("Info.plist key missing: " + k.decode())

    print()
    print("=== 危险项（应为无） ===")
    for m in [b"retry anyway", b"attempts exhausted", b"get-task-allow"]:
        bad = marker_present(binary, m)
        print(("  BAD " if bad else "  ok  ") + m.decode())
        if bad:
            errors.append("forbidden marker present: " + m.decode())

    print()
    print("=== JS bundle ===")
    js = [n for n in names if n.endswith("main.jsbundle")]
    print("  " + (js[0] if js else "MISSING"))
    if not js:
        errors.append("main.jsbundle missing")

    print()
    if errors:
        for e in errors:
            print("FAIL: " + e)
        print("DEMO_ARTIFACT_FAIL")
        return 1
    print("DEMO_ARTIFACT_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
