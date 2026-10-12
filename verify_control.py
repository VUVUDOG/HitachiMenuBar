"""One bounded integration check: change an OFF room's setpoint, then restore it."""
import argparse
import json

import keyring

from cloud import XiaomiCloud
from probe import RUNTIME, SERVICE


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--room", required=True)
    args = parser.parse_args()
    report = json.loads((RUNTIME / "report.json").read_text())
    item = next(d for d in report["devices"] if d["device"]["name"] == args.room)
    cloud = XiaomiCloud(json.loads(keyring.get_password(SERVICE, "session")))
    states = cloud.read_state(item["device"], item["spec"])
    power = next(s for s in states if s["siid"] == 2 and s["piid"] == 1)
    temp = next(s for s in states if s["siid"] == 2 and s["piid"] == 4)
    if power.get("code") != 0 or power.get("value") is not False or temp.get("code") != 0:
        raise RuntimeError("无法确认该房间处于关机状态，跳过验证")
    original = temp["value"]
    trial = original + 1 if original < 32 else original - 1
    print(f"{args.room}保持关机；设定温度 {original} → {trial} → {original}", flush=True)
    try:
        cloud.set_property(item["device"], item["spec"], "target-temperature", trial)
        print("试调温度：云端回读确认成功", flush=True)
    finally:
        cloud.set_property(item["device"], item["spec"], "target-temperature", original)
        print("恢复原温度：云端回读确认成功", flush=True)


if __name__ == "__main__":
    main()
