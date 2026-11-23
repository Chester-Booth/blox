"""Reject stale terminal binaries before the installer writes state."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_lifecycle import installer
import build_native_widgets as native


class NativeWidgetsPackagingTests(unittest.TestCase):
    def fixture(self, root):
        for name in native.SOURCES:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture source\n")
        module = root / "widgets/qml/Blox/Widgets/Terminal"
        (module / native.PLUGIN).write_bytes(b"fixture binary")
        (module / ".build.json").write_text(json.dumps({
            "format": 1, "sources": native.hashes(root),
            "sha256": installer.sha256(module / native.PLUGIN),
        }))
        return module

    def test_prebuilt_module_validates_without_compiling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            with mock.patch.object(native, "run", side_effect=AssertionError("compiler invoked")):
                installer._require_native_widgets(root)

    def test_stale_or_missing_artifacts_refuse_installation(self):
        for changed in (*native.SOURCES, "widgets/qml/Blox/Widgets/Terminal/" + native.PLUGIN,
                        "widgets/qml/Blox/Widgets/Terminal/.build.json"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                path = root / changed
                path.write_bytes(path.read_bytes() + b"changed")
                with self.assertRaises(installer.LifecycleError) as failure:
                    installer._require_native_widgets(root)
                self.assertEqual(failure.exception.code, "unavailable")
                self.assertIn("make native-widgets", str(failure.exception))

    def test_missing_binary_refuses_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = self.fixture(root)
            (module / native.PLUGIN).unlink()
            with self.assertRaises(installer.LifecycleError):
                installer._require_native_widgets(root)


if __name__ == "__main__":
    unittest.main()
