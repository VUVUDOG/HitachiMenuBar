"""Cloud worker for the menu bar app. Credentials stay in macOS Keychain."""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests
from keyring.errors import KeyringError

from auth import SessionStore, StaleSession
from cloud import CloudError, XiaomiCloud

ROOT = Path(__file__).resolve().parent
RUNTIME = Path(os.environ.get("HITACHI_RUNTIME_PATH", str(ROOT / ".runtime")))
SERVICE = "HitachiMenuBar.CloudWorker" if getattr(sys, "frozen", False) else "HitachiMenuBar.XiaomiCloud"
store = None
session_output = False


def write_json(name, value):
    store.write_json(name, value)


def status(phase, message, reason=None):
    try:
        write_json("status.json", {"phase": phase, "message": message, **({"reason": reason} if reason else {})})
    except StaleSession:
        return
    print(message, file=sys.stderr if session_output else sys.stdout, flush=True)


SENSOR_WORDS = ("sensor_ht", "temp_hum", "thermo", "sensor_temp", "weather", "airmonitor", "airm.")


def is_air_conditioner(device):
    return "空调" in device.get("name", "") or any(
        w in device.get("model", "").lower() for w in ("hitachi", "aircondition", ".airc"))


def discover_sensors(cloud, devices):
    """Find MiJia thermometers and remember which property holds temperature / humidity."""
    sensors = []
    for device in devices:
        model = device.get("model", "").lower()
        if is_air_conditioner(device) or not (
                any(w in model for w in SENSOR_WORDS) or any(w in device.get("name", "") for w in ("温度", "温湿度"))):
            continue
        entry = {"device": {k: device.get(k) for k in ("did", "name", "model", "isOnline")},
                 "room": cloud.device_rooms.get(device.get("did"))}
        try:
            spec = cloud.spec(device.get("model"))
            entry["fields"] = cloud.climate_fields(spec) if spec else {}
        except (CloudError, requests.RequestException, ValueError, KeyError):
            entry["fields"] = {}
        if entry["fields"]:
            sensors.append(entry)
    return sensors


def pair_sensor(item, sensors):
    """Same MiJia room first; otherwise a sensor whose name or room mentions the AC's room name."""
    readable = [s for s in sensors if "temperature" in s.get("values", {})]
    room = item.get("room")
    same_room = [s for s in readable if room and s.get("room") == room]
    if same_room:
        return same_room[0]
    label = item["device"].get("name", "").replace("空调", "").strip()
    return next((s for s in readable if label and (label in s["device"].get("name", "") or label == s.get("room"))), None)


def read_climate(cloud, report):
    for sensor in report.get("sensors", []):
        try:
            sensor["values"], sensor["codes"] = cloud.read_climate(sensor["device"]["did"], sensor["fields"])
        except (CloudError, requests.RequestException, ValueError, KeyError):
            sensor["values"], sensor["codes"] = {}, {"temperature": "error"}
        sensor["read_at"] = time.time()
    for item in report["devices"]:
        sensor = pair_sensor(item, report.get("sensors", []))
        item["climate"] = None if not sensor else {
            "temperature": sensor["values"]["temperature"], "humidity": sensor["values"].get("relative-humidity"),
            "sensor": sensor["device"].get("name")}


def main(argv=None):
    global store, session_output
    parser = argparse.ArgumentParser()
    parser.add_argument("--login", action="store_true", help="重新扫码登录")
    parser.add_argument("--logout", action="store_true", help="退出登录并清除本机设备缓存")
    parser.add_argument("--refresh", action="store_true", help="刷新已发现设备的状态")
    parser.add_argument("--room", help="指定已发现设备的标识")
    parser.add_argument("--field", action="append", choices=["on", "mode", "target-temperature", "fan-level"],
                        help="控制属性，可重复；与 --value 按顺序配对")
    parser.add_argument("--value", action="append", help="JSON 控制值，可重复")
    parser.add_argument("--import-session", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--session-stdin", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--session-output", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--require-session", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    session_output = args.session_output
    os.umask(0o077)
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    store = SessionStore(RUNTIME, SERVICE)
    try:
        action = "import" if args.import_session else "logout" if args.logout else "login" if args.login else None
        store.begin(action, os.environ.get("HITACHI_AUTH_GENERATION"))
        if args.logout:
            status("logged_out", "已退出登录")
            return 0
        if args.import_session:
            session = json.load(sys.stdin)
            if not all(isinstance(session.get(k), str) and session[k] for k in ("user_id", "ssecurity", "service_token")):
                raise CloudError("登录会话格式不正确")
            store.save_credentials(session)
            print("登录会话已迁移到本机钥匙串", flush=True)
            return 0
        if args.require_session and not args.login and not args.session_stdin:
            # The GUI owns credential reads. A missing/malformed private pipe
            # must never silently cause a second system authorization request.
            with store.locked():
                authenticated = store._current()["state"] == "authenticated"
            status("error" if authenticated else "logged_out",
                   "登录凭证未传入，请手动刷新或重新登录" if authenticated else "请扫码登录米家",
                   reason="keychain_access" if authenticated else None)
            return 1 if authenticated else 0
        if not args.login and not args.session_stdin:
            status("authenticating", "正在读取钥匙串中的登录会话…")
        credentials = store.memory_credentials(json.load(sys.stdin)) if args.session_stdin else store.credentials()
        cloud = XiaomiCloud(credentials)
        if args.login:
            status("starting", "正在获取米家登录二维码…")
            image, login = cloud.start_qr()
            store.write_qr(image)
            status("awaiting_scan", "请用米家 App 的扫一扫扫描登录二维码，并在手机上确认登录。")
            cloud.wait_qr(login)
            store.save_credentials(cloud.credentials)
            store.clear_qr()
        elif not cloud.credentials:
            status("logged_out", "请扫码登录米家")
            return 0
        if session_output:
            # The native app captures this pipe privately. No credentials go in
            # argv, environment, logs, status.json or other runtime files.
            print(json.dumps({"generation": store.generation, "session": cloud.credentials}), flush=True)
        if args.room or args.field or args.value or args.refresh:
            if not (RUNTIME / "report.json").exists():
                raise CloudError("请先同步空调设备")
            report = json.loads((RUNTIME / "report.json").read_text())
            if "sensors" not in report:
                # Reports from before thermometer support: discover rooms and sensors once.
                # A failed lookup must not block the air-conditioner refresh; retry next time.
                try:
                    devices = cloud.devices()
                    for item in report["devices"]:
                        item["room"] = cloud.device_rooms.get(item["device"]["did"])
                    report["sensors"] = discover_sensors(cloud, devices)
                except (CloudError, requests.RequestException, ValueError, KeyError):
                    pass
            targets = report["devices"]
            if args.room or args.field or args.value:
                if not (args.room and args.field and args.value and len(args.field) == len(args.value)):
                    raise CloudError("控制指令缺少房间、属性或数值")
                matches = [d for d in report["devices"] if d["device"]["did"] == args.room]
                if len(matches) != 1 or not matches[0].get("spec"):
                    raise CloudError("没有找到已验证的空调设备")
                status("controlling", "正在发送指令并确认设备状态…")
                item = matches[0]
                changes = {field: json.loads(value) for field, value in zip(args.field, args.value)}
                half = changes.get("target-temperature")
                half = isinstance(half, float) and not half.is_integer()
                try:
                    cloud.set_properties(item["device"], item["spec"], changes)
                except CloudError:
                    if not half:
                        raise
                    # The unit rejected or rounded a half degree: remember it and use whole degrees.
                    item["half_step"] = False
                    write_json("report.json", report)
                    raise CloudError("这台空调不支持 0.5 度调节，之后改为按 1 度调节")
                if half:
                    item["half_step"] = True
                # Only the controlled room changed; other rooms keep their last reading.
                targets = [item]
            else:
                status("reading", "正在刷新空调状态…")
            for item in targets:
                if item.get("spec"):
                    item["state"] = cloud.read_state(item["device"], item["spec"])
            if not args.field:
                read_climate(cloud, report)
            report["read_at"] = time.time()
            write_json("report.json", report)
            status("complete", "设备状态已更新" if not args.field else "指令已执行，云端回读已确认")
            return 0
        status("reading", "已登录，正在读取米家第三方设备…")
        devices = cloud.devices()
        # Export only the information relevant to this project; never cloud tokens/IPs/MACs.
        summaries = [{k: d.get(k) for k in ("did", "name", "model", "isOnline")}
                     for d in devices if is_air_conditioner(d)]
        write_json("devices.json", summaries)
        reports = []
        specs = {}
        for device in summaries:
            report = {"device": device, "room": cloud.device_rooms.get(device["did"])}
            model = device.get("model")
            try:
                if model and model not in specs:
                    specs[model] = cloud.spec(model)
                spec = specs.get(model)
                if spec:
                    report["spec"] = spec
                    report["state"] = cloud.read_state(device, spec)
                else:
                    report["message"] = "未找到标准 MIoT 功能定义，需要继续确认第三方控制接口。"
            except (CloudError, requests.RequestException, ValueError, KeyError) as exc:
                report["message"] = str(exc) if isinstance(exc, CloudError) else "状态查询失败，需要检查接口兼容性。"
            reports.append(report)
        full = {"devices": reports, "sensors": discover_sensors(cloud, devices),
                "total_device_count": len(devices), "read_at": time.time()}
        read_climate(cloud, full)
        write_json("report.json", full)
        if not summaries:
            status("not_found", "登录成功，但没有找到空调设备；需要继续核对第三方设备同步接口。")
        else:
            status("complete", "设备状态已更新")
    except StaleSession:
        return 0
    except KeyringError:
        status("error", "钥匙串未授权，请允许访问后手动刷新，或重新扫码登录", reason="keychain_access")
        return 1
    except CloudError as exc:
        status("error", str(exc))
        return 1
    except requests.RequestException as exc:
        code = exc.response.status_code if exc.response is not None else "network"
        status("error", f"连接米家服务失败（{code}），请稍后刷新。")
        return 1
    except Exception as exc:
        status("error", f"连接未完成（{type(exc).__name__}），请重试。")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
