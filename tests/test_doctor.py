import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPTS = REPOSITORY / "shell" / "scripts"
for path in (str(SCRIPTS), str(REPOSITORY / "packaging")):
    if path not in sys.path:
        sys.path.insert(0, path)

import doctor  # noqa: E402


class RedactionTests(unittest.TestCase):
    def test_home_paths_collapse(self):
        self.assertEqual(doctor.redact({"path": "/home/blox/.config/blox"}, "/home/blox"), {"path": "~/.config/blox"})

    def test_mac_addresses_never_appear(self):
        redacted = doctor.redact({"device": "aa:bb:cc:dd:ee:ff"}, "/home/someone")
        self.assertEqual(redacted["device"], "<mac>")

    def test_sensitive_keys_are_replaced(self):
        redacted = doctor.redact({"ssid": "HomeNet", "ok": True}, "/home/someone")
        self.assertEqual(redacted["ssid"], "<redacted>")
        self.assertTrue(redacted["ok"])


class DoctorReportTests(unittest.TestCase):
    def test_report_is_typed_and_redacted_when_not_installed(self):
        report = doctor.collect()
        report["redacted"] = True
        payload = json.loads(json.dumps(report))
        self.assertEqual(payload["version"], 1)
        self.assertFalse(payload["healthy"])
        ids = {check["id"] for check in payload["checks"]}
        self.assertIn("install-manifest", ids)
        for check in payload["checks"]:
            self.assertIn("severity", check)
            self.assertIn("ok", check)

    def test_json_output_contains_no_home_path(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            doctor.main(as_json=True)
        text = buffer.getvalue()
        self.assertIn('"redacted": true', text)
        self.assertNotIn(os.path.expanduser("~"), text)


if __name__ == "__main__":
    unittest.main()
