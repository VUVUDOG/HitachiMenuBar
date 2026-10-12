"""Move the development session into the packaged worker's own Keychain entry."""
import json
import os
import shutil
import subprocess
from pathlib import Path

import keyring

root = Path(__file__).resolve().parent
runtime = Path.home() / "Library" / "Application Support" / "HitachiMenuBar"
runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
for name in ("report.json", "devices.json", "status.json"):
    if (root / ".runtime" / name).exists():
        shutil.copyfile(root / ".runtime" / name, runtime / name)
        (runtime / name).chmod(0o600)
session = keyring.get_password("HitachiMenuBar.XiaomiCloud", "session")
if not session:
    raise RuntimeError("未找到本机开发验证阶段的登录会话")
environment = dict(os.environ, HITACHI_RUNTIME_PATH=str(runtime))
worker = root / "dist" / "HitachiMenuBar.app" / "Contents" / "Resources" / "CloudWorker" / "CloudWorker"
subprocess.run([str(worker), "--import-session"], input=session, text=True, env=environment, check=True)
print("开发读取结果已迁移；应用内不包含任何登录凭证")
