import unittest
from types import SimpleNamespace
from unittest.mock import patch

import probe
from cloud import CloudError, XiaomiCloud

LIGHT = {"type": "urn:miot-spec-v2:device:light:1", "services": [
    {"iid": 2, "type": "urn:miot-spec-v2:service:light:1", "properties": [
        {"iid": 1, "type": "urn:miot-spec-v2:property:on:1", "format": "bool", "access": ["read", "write"]},
        {"iid": 2, "type": "urn:miot-spec-v2:property:brightness:1", "format": "uint8", "access": ["read", "write"],
         "value-range": [1, 100, 1]},
        {"iid": 7, "type": "urn:miot-spec-v2:property:mode:1", "format": "uint8", "access": ["read", "write"],
         "value-list": [{"value": 0, "description": "None"}]}]}]}
CURTAIN = {"type": "urn:miot-spec-v2:device:curtain:1", "services": [
    {"iid": 2, "type": "urn:miot-spec-v2:service:curtain:1", "properties": [
        {"iid": 1, "type": "urn:miot-spec-v2:property:motor-control:1", "format": "uint8", "access": ["write"],
         "value-list": [{"value": 0, "description": "Pause"}, {"value": 1, "description": "Open"}]},
        {"iid": 3, "type": "urn:miot-spec-v2:property:current-position:1", "format": "uint8", "access": ["read"],
         "value-range": [0, 100, 1]},
        {"iid": 4, "type": "urn:miot-spec-v2:property:target-position:1", "format": "uint8",
         "access": ["read", "write"], "value-range": [0, 100, 1]}]}]}


class AccessoryTests(unittest.TestCase):
    def test_only_whitelisted_properties_are_exposed(self):
        props = {p["address"]: p for p in probe.accessory_props(LIGHT)}
        self.assertEqual(set(props), {"light.on", "light.brightness"})
        self.assertEqual(props["light.brightness"]["range"], [1, 100, 1])

    def test_home_follows_air_conditioners(self):
        cloud = SimpleNamespace(device_homes={"ac1": "御江廷", "ac2": "御江廷", "x": "公司", "y": "公司", "z": "公司"})
        self.assertEqual(probe.choose_home(cloud, [{"did": "ac1"}, {"did": "ac2"}]), "御江廷")

    def test_write_only_command_is_not_read_back(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: [{"code": 1}]
        cloud.api = lambda path, payload: self.fail("write-only commands cannot be read back")
        cloud.set_addresses({"did": "c"}, CURTAIN, {"curtain.motor-control": 1})

    def test_brightness_readback_tolerates_small_quantisation(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: [{"code": 0}]
        cloud.api = lambda path, payload: [{"siid": 2, "piid": 2, "code": 0, "value": 64}]
        with patch("cloud.time.sleep"):
            cloud.set_addresses({"did": "l"}, LIGHT, {"light.brightness": 65})

    def test_invalid_values_are_rejected_before_sending(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: self.fail("must validate first")
        for address, value in [("light.brightness", 0), ("light.brightness", 50.5), ("light.on", 1),
                               ("curtain.target-position", 101), ("light.unknown", 1)]:
            spec = CURTAIN if address.startswith("curtain") else LIGHT
            with self.assertRaises(CloudError):
                cloud.set_addresses({"did": "d"}, spec, {address: value})


if __name__ == "__main__":
    unittest.main()
