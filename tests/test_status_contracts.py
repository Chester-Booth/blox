import json
import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
CONTRACT_PATH = REPOSITORY / "shell/scripts/contracts/status.json"
QML_ROOT = REPOSITORY / "shell"
CAPABILITY_FIELDS = {"available", "ready", "canChange", "permission", "reason"}
PERMISSIONS = {"not-required", "unknown", "granted", "denied"}


def value_for(expected):
    if isinstance(expected, list):
        return value_for(expected[0])
    return {
        "array": [],
        "boolean": False,
        "number": 0,
        "object": {},
        "string": "",
        "null": None,
    }[expected]


def fixture_for(spec, capability):
    payload = {field: value_for(expected) for field, expected in spec["required"].items()}
    payload["capability"] = capability
    for field, child_spec in spec.get("children", {}).items():
        if field == "capability":
            continue
        if field in payload and isinstance(child_spec, dict):
            payload[field] = {
                child_field: value_for(expected)
                for child_field, expected in child_spec.items()
            }
    return payload


def assert_type(test, value, expected, label):
    expected_types = expected if isinstance(expected, list) else [expected]
    names = {
        "array": list,
        "boolean": bool,
        "number": (int, float),
        "object": dict,
        "string": str,
        "null": type(None),
    }
    test.assertTrue(
        any(isinstance(value, names[item]) and not (item == "number" and isinstance(value, bool)) for item in expected_types),
        f"{label}: expected {expected}, got {type(value).__name__}",
    )


class StatusContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contracts = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))

    def validate_fixture(self, name, payload):
        spec = self.contracts[name]
        for field, expected in spec["required"].items():
            self.assertIn(field, payload, f"{name}: missing {field}")
            assert_type(self, payload[field], expected, f"{name}.{field}")
        capability = payload["capability"]
        self.assertEqual(set(capability), CAPABILITY_FIELDS)
        self.assertIn(capability["permission"], PERMISSIONS)
        self.assertIsInstance(capability["reason"], (str, type(None)))

    def test_every_producer_has_the_common_capability_contract(self):
        self.assertEqual(len(self.contracts), 10)
        for name, spec in self.contracts.items():
            self.assertEqual(spec["required"]["capability"], "object", name)
            child = spec["children"]["capability"]
            self.assertEqual(set(child["required"]), CAPABILITY_FIELDS, name)
            self.assertEqual(set(child["enum"]["permission"]), PERMISSIONS, name)

    def test_all_producer_classes_keep_each_state_typed(self):
        states = {
            "useful": {"available": True, "ready": True, "canChange": True, "permission": "granted", "reason": None},
            "empty": {"available": True, "ready": True, "canChange": False, "permission": "not-required", "reason": None},
            "unavailable": {"available": False, "ready": False, "canChange": False, "permission": "unknown", "reason": "command-unavailable"},
            "not-ready": {"available": True, "ready": False, "canChange": False, "permission": "unknown", "reason": "query-failed"},
            "denied": {"available": True, "ready": True, "canChange": False, "permission": "denied", "reason": "permission-denied"},
            "failed": {"available": True, "ready": False, "canChange": False, "permission": "unknown", "reason": "query-failed"},
        }
        for state, capability in states.items():
            for name, spec in self.contracts.items():
                with self.subTest(state=state, producer=name):
                    payload = fixture_for(spec, capability)
                    self.validate_fixture(name, payload)
                    if not capability["available"]:
                        self.assertFalse(payload["capability"]["ready"])
                        self.assertFalse(payload["capability"]["canChange"])
                    if not capability["ready"] or capability["permission"] == "denied":
                        self.assertFalse(payload["capability"]["canChange"])
                    if not capability["available"] or not capability["ready"] or capability["permission"] == "denied":
                        self.assertIsNotNone(payload["capability"]["reason"])

    def test_structured_panel_fields_exist(self):
        for name in ("brightness", "privacy"):
            self.assertEqual(self.contracts[name]["required"]["details"], "string")

    def test_network_and_bluetooth_use_native_owners(self):
        network = (QML_ROOT / "services/NetworkManagerProvider.qml").read_text(encoding="utf-8")
        bluetooth = (QML_ROOT / "services/BluezProvider.qml").read_text(encoding="utf-8")
        self.assertIn("import Quickshell.Networking", network)
        self.assertIn("signalStrength) * 100", network)
        self.assertNotIn("nmcli", network)
        self.assertIn("import Quickshell.Bluetooth", bluetooth)
        self.assertNotIn("bluetoothctl", bluetooth)

    def test_status_consumers_do_not_parse_presentation_fields(self):
        pattern = re.compile(r"(?:tooltip|label|details)\s*\.\s*(?:split|match|replace)|(?:split|match|replace)\s*\([^)]*\)\s*.*(?:tooltip|label|details)")
        offenders = []
        for path in QML_ROOT.rglob("*.qml"):
            text = path.read_text(encoding="utf-8")
            if pattern.search(text):
                offenders.append(str(path.relative_to(REPOSITORY)))
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
