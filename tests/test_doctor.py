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
        self.assertEqual(doctor.redact({"path": "/home/someone/.config/blox"}, "/home/someone"), {"path": "~/.config/blox"})

    def test_mac_addresses_never_appear(self):
        redacted = doctor.redact({"device": "aa:bb:cc:dd:ee:ff"}, "/home/someone")
        self.assertEqual(redacted["device"], "<mac>")

    def test_sensitive_keys_are_replaced(self):
        redacted = doctor.redact({"ssid": "HomeNet", "ok": True}, "/home/someone")
        self.assertEqual(redacted["ssid"], "<redacted>")
        self.assertTrue(redacted["ok"])


class DoctorReportTests(unittest.TestCase):
    def test_report_is_typed_and_redacted_when_not_installed(self):
        # Isolate HOME so "not installed" holds on any machine, including one
        # where Blox is currently installed.
        import shutil
        import tempfile

        fixture = tempfile.mkdtemp(prefix="blox-doctor-")
        saved = {key: os.environ.get(key) for key in ("HOME", "BLOX_PREFIX", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")}
        try:
            os.environ["HOME"] = fixture
            os.environ["BLOX_PREFIX"] = os.path.join(fixture, ".local")
            for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
                os.environ.pop(key, None)
            report = doctor.collect()
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
            shutil.rmtree(fixture, ignore_errors=True)
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
