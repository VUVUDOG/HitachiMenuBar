"""Xiaomi cloud client for explicitly selected HVAC properties."""
import base64
import hashlib
import json
import os
import time
from urllib.parse import urlparse

import requests
from Crypto.Cipher import ARC4


class CloudError(Exception):
    pass


def decode_account(text):
    return json.loads(text.removeprefix("&&&START&&&"))


def rc4(key, payload):
    cipher = ARC4.new(base64.b64decode(key))
    cipher.encrypt(bytes(1024))
    return cipher.encrypt(payload)


def signature(path, params, signed_nonce):
    parts = ["POST", path.removeprefix("/app")]
    parts.extend(f"{k}={v}" for k, v in params.items())
    parts.append(signed_nonce)
    return base64.b64encode(hashlib.sha1("&".join(parts).encode()).digest()).decode()


class XiaomiCloud:
    def __init__(self, credentials=None):
        self.session = requests.Session()
        self.agent = "Android-7.1.1-1.0.0-ONEPLUS A3010-136-HITACHIMENUBAR APP/xiaomi.smarthome APPV/62830"
        self.session.headers["User-Agent"] = self.agent
        self.credentials = credentials

    @staticmethod
    def account_url(url):
        parsed = urlparse(url)
        # Account replies may carry login secrets in the query. Never log these URLs.
        if parsed.scheme != "https" or not parsed.hostname or not any(
            parsed.hostname == host or parsed.hostname.endswith("." + host)
            for host in ("xiaomi.com", "mi.com")
        ):
            raise CloudError("登录服务返回了无法识别的地址")
        return url

    def start_qr(self):
        response = self.session.get(
            "https://account.xiaomi.com/longPolling/loginUrl",
            params={"_qrsize": "480", "qs": "%3Fsid%3Dxiaomiio%26_json%3Dtrue",
                    "callback": "https://sts.api.io.mi.com/sts", "_hasLogo": "false",
                    "sid": "xiaomiio", "serviceParam": "", "_locale": "zh_CN",
                    "_dc": str(int(time.time() * 1000))}, timeout=20,
        )
        response.raise_for_status()
        data = decode_account(response.text)
        if not all(data.get(k) for k in ("qr", "lp", "loginUrl")):
            raise CloudError(f"米家扫码登录暂不可用（code={data.get('code', 'unknown')}）")
        image = self.session.get(self.account_url(data["qr"]), timeout=20)
        image.raise_for_status()
        return image.content, data

    def wait_qr(self, data):
        deadline = time.monotonic() + min(float(data.get("timeout", 180)), 300)
        while time.monotonic() < deadline:
            try:
                response = self.session.get(self.account_url(data["lp"]), timeout=20)
            except requests.Timeout:
                continue
            response.raise_for_status()
            result = decode_account(response.text)
            if result.get("code") != 0 or not result.get("ssecurity"):
                raise CloudError(f"扫码登录未完成或已过期（code={result.get('code', 'unknown')}）")
            token_response = self.session.get(self.account_url(result["location"]), timeout=20)
            token_response.raise_for_status()
            tokens = [c.value for r in [*token_response.history, token_response]
                      for c in r.cookies if c.name == "serviceToken"]
            if not tokens:
                tokens = [c.value for c in self.session.cookies if c.name == "serviceToken"]
            if not tokens:
                raise CloudError("扫码已确认，但未获得米家云端会话")
            self.credentials = {"user_id": str(result["userId"]),
                                "ssecurity": result["ssecurity"], "service_token": tokens[-1]}
            return
        raise CloudError("二维码已过期，请重新生成后扫码")

    def api(self, path, payload):
        # Restrict the compatibility probe to read-only operations.
        allowed = {"v2/homeroom/gethome_merged", "v2/home/home_device_list",
                   "home/device_list", "miotspec/prop/get"}
        if path not in allowed:
            raise CloudError("验证工具只支持读取设备")
        return self._request(path, payload)

    def set_property(self, device, spec, field, value):
        allowed = {"on", "mode", "target-temperature", "fan-level"}
        if field not in allowed:
            raise CloudError("不支持这个控制功能")
        properties = [(s, p) for s in spec.get("services", [])
                      if any(part in s.get("type", "") for part in (":air-conditioner:", ":fan-control:"))
                      for p in s.get("properties", []) if f":{field}:" in p.get("type", "")]
        if len(properties) != 1:
            raise CloudError("设备未提供唯一的控制属性")
        service, prop = properties[0]
        if "write" not in prop.get("access", []):
            raise CloudError("该设备属性不可写")
        if prop.get("format") == "bool":
            if type(value) is not bool:
                raise CloudError("开关值必须是 true 或 false")
        elif type(value) not in (int, float):
            raise CloudError("控制值必须是数字")
        if options := prop.get("value-list"):
            if value not in [o["value"] for o in options]:
                raise CloudError("控制值不在设备支持的选项中")
        if limits := prop.get("value-range"):
            low, high, step = limits
            if not low <= value <= high or abs((value - low) / step - round((value - low) / step)) > 1e-6:
                raise CloudError("温度超出设备范围或不符合调节步长")
        change = {"did": device["did"], "siid": service["iid"], "piid": prop["iid"], "value": value}
        result = self._request("miotspec/prop/set", {"params": [change]})
        if not isinstance(result, list) or len(result) != 1 or result[0].get("code") != 0:
            code = result[0].get("code", "unknown") if isinstance(result, list) and result else "unknown"
            raise CloudError(f"空调控制未成功（code={code}）")
        # A successful acknowledgement is not sufficient: read back the changed value.
        for _ in range(4):
            time.sleep(1)
            state = self.api("miotspec/prop/get", {"params": [{k: v for k, v in change.items() if k != "value"}]}) or []
            if any(p.get("code") == 0 and p.get("value") == value and
                   p.get("siid") == change["siid"] and p.get("piid") == change["piid"] for p in state):
                return result
        raise CloudError("指令已发送，但暂未确认设备状态；请刷新查看")

    def _request(self, path, payload):
        if not self.credentials:
            raise CloudError("请先扫码登录米家")
        cred = self.credentials
        nonce = base64.b64encode(os.urandom(8) + int(time.time() / 60).to_bytes(4, "big")).decode()
        signed_nonce = base64.b64encode(hashlib.sha256(
            base64.b64decode(cred["ssecurity"]) + base64.b64decode(nonce)).digest()).decode()
        url = "https://api.io.mi.com/app/" + path
        params = {"data": json.dumps(payload, separators=(",", ":"))}
        params["rc4_hash__"] = signature("/" + path, params, signed_nonce)
        params = {k: base64.b64encode(rc4(signed_nonce, v.encode())).decode() for k, v in params.items()}
        params["signature"] = signature("/" + path, params, signed_nonce)
        params.update({"ssecurity": cred["ssecurity"], "_nonce": nonce})
        response = self.session.post(url, data=params, timeout=30,
            headers={"MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4", "Accept-Encoding": "identity",
                     "Content-Type": "application/x-www-form-urlencoded",
                     "X-XIAOMI-PROTOCAL-FLAG-CLI": "PROTOCAL-HTTP2"},
            cookies={"userId": cred["user_id"], "serviceToken": cred["service_token"],
                     "yetAnotherServiceToken": cred["service_token"], "locale": "zh_CN",
                     "timezone": "GMT+08:00", "channel": "MI_APP_STORE"})
        response.raise_for_status()
        try:
            result = json.loads(response.text)
        except ValueError:
            result = json.loads(rc4(signed_nonce, base64.b64decode(response.text)))
        if result.get("code", 0) != 0:
            raise CloudError(f"米家云端请求失败（{path}, code={result.get('code')}）")
        return result.get("result")

    def devices(self):
        merged = self.api("v2/homeroom/gethome_merged", {
            "fg": True, "fetch_share": True, "fetch_share_dev": True,
            "fetch_cariot": True, "limit": 300, "app_ver": 7, "plat_form": 0}) or {}
        homes = list(merged.get("homelist") or [])
        homes += list(merged.get("share_home_list") or [])
        baseline = self.api("home/device_list", {
            "getVirtualModel": True, "getHuamiDevices": 1,
            "get_split_device": False, "support_smart_home": True}) or {}
        devices = {d["did"]: d for d in baseline.get("list", []) if d.get("did")}
        for home in homes:
            home_id = home.get("id", home.get("home_id"))
            owner = home.get("uid", home.get("home_owner", self.credentials["user_id"]))
            if home_id is None:
                continue
            start = ""
            seen = set()
            while True:
                page = self.api("v2/home/home_device_list", {
                    "home_owner": int(owner), "home_id": int(home_id), "limit": 300,
                    "start_did": start, "get_split_device": False,
                    "support_smart_home": True, "get_cariot_device": True,
                    "get_third_device": True}) or {}
                for device in page.get("device_info") or []:
                    did = device.get("did")
                    if did:
                        devices.setdefault(did, {}).update(device)
                following = page.get("max_did") or ""
                if not page.get("has_more") or not following or following in seen:
                    break
                seen.add(following)
                start = following
        return list(devices.values())

    def spec(self, model):
        response = self.session.get("https://miot-spec.org/miot-spec-v2/instances",
                                    params={"status": "all"}, timeout=30)
        response.raise_for_status()
        matches = [i for i in response.json().get("instances", []) if i.get("model") == model]
        if not matches:
            return None
        urn = max(matches, key=lambda i: i.get("version", 0))["type"]
        response = self.session.get("https://miot-spec.org/miot-spec-v2/instance",
                                    params={"type": urn}, timeout=30)
        response.raise_for_status()
        return response.json()

    def read_state(self, device, spec):
        properties = []
        for service in spec.get("services", []):
            # Only inspect HVAC, fan, environment and temperature-related services.
            if not any(word in service.get("type", "") for word in
                       (":air-conditioner:", ":environment:", ":fan-control:", ":thermostat:")):
                continue
            for prop in service.get("properties", []):
                if "read" in prop.get("access", []):
                    properties.append({"did": device["did"], "siid": service["iid"], "piid": prop["iid"]})
        values = []
        for start in range(0, len(properties), 10):
            values += self.api("miotspec/prop/get", {"params": properties[start:start + 10]}) or []
        return values
