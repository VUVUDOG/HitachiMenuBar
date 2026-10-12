"""Capture real native layouts in isolated runtimes, without cloud operations."""
import json
import argparse
import os
import plistlib
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--arch", choices=["arm64", "x86_64"], default="arm64")
args = parser.parse_args()
application = (root / "dist" / ("intel" if args.arch == "x86_64" else "") / "HitachiMenuBar.app/Contents/MacOS/HitachiMenuBar")
version = plistlib.loads((application.parent.parent / "Info.plist").read_bytes())["CFBundleShortVersionString"]
report = Path.home() / "Library/Application Support/HitachiMenuBar/report.json"
for phase in ("control", "logged-out"):
    with tempfile.TemporaryDirectory(prefix="hitachi-preview-") as temporary:
        runtime = Path(temporary)
        authenticated = phase == "control"
        (runtime / "auth.json").write_text(json.dumps({"generation": "preview", "state": "authenticated" if authenticated else "logged_out"}))
        if authenticated:
            (runtime / "report.json").write_bytes(report.read_bytes())
        (runtime / "status.json").write_text(json.dumps({"generation": "preview", "phase": "complete" if authenticated else "logged_out",
                                                        "message": "设备状态已更新" if authenticated else "已退出登录"}, ensure_ascii=False))
        target = root / ".runtime" / ("app-v" + version.replace(".", "") + "-" + phase + ("-intel" if args.arch == "x86_64" else "") + ".png")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.unlink(missing_ok=True)
        process = subprocess.Popen([str(application), "--preview=" + str(target)],
                                   env={**os.environ, "HITACHI_RUNTIME_PATH": str(runtime)})
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline and not target.exists():
                time.sleep(0.1)
            if not target.exists():
                raise RuntimeError("Native preview was not generated")
            geometry = json.loads(Path(str(target) + ".layout.json").read_text())
            assert abs(geometry["window_height"] - geometry["natural_height"]) <= 1
            assert abs(geometry["content_height"] - geometry["natural_height"]) <= 1
            subprocess.run(["sips", "-g", "hasAlpha", str(target)], check=True)
            print("Content fills window:", geometry)
            print(target)
        finally:
            process.terminate()
            process.wait(timeout=5)
