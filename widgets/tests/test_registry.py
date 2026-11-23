"""Trusted QML discovery validates files without loading executable code."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from blox_widgets.registry import MAX_MANIFEST_BYTES, scan_registry
from blox_widgets.model import ValidationError


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "packages"
        self.root.mkdir()

    def package(self, directory="clock", **changes):
        package = self.root / directory
        package.mkdir()
        manifest = {"id": "community-clock", "name": "Community clock", "layouts": ["native"],
                    "providers": ["clock"]}
        manifest.update(changes)
        (package / "widget.json").write_text(json.dumps(manifest), encoding="utf-8")
        # Invalid QML is intentional. Discovery must never parse or execute it.
        (package / "Main.qml").write_text("This is deliberately not QML", encoding="utf-8")
        return package

    def test_local_source_and_shared_layout_provider_validation(self):
        package = self.package()
        result = scan_registry(self.root)
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["registry"], {"community-clock": {
            "source": (package / "Main.qml").as_uri(), "name": "Community clock",
            "layouts": ["native"], "providers": ["clock"]}})
        for directory, change in (("bad-id", {"id": "../../outside"}),
                                  ("bad-layout", {"layouts": ["unknown"]}),
                                  ("bad-provider", {"providers": ["dbus"]}),
                                  ("duplicate-provider", {"providers": ["clock", "clock"]}),
                                  ("empty-layouts", {"layouts": []}),
                                  ("empty-name", {"name": " "}),
                                  ("source-injection", {"source": "https://example.invalid/run.qml"})):
            with self.subTest(directory=directory):
                self.package(directory, **change)
        result = scan_registry(self.root)
        self.assertEqual(list(result["registry"]), ["community-clock"])
        self.assertEqual(len(result["errors"]), 7)

    def test_symlink_containment_for_packages_manifest_and_source(self):
        external = Path(self.temporary.name) / "external"
        external.mkdir()
        (external / "widget.json").write_text('{}', encoding="utf-8")
        (external / "Main.qml").write_text("external", encoding="utf-8")
        (self.root / "external-package").symlink_to(external, target_is_directory=True)
        source_package = self.package("escaped-source", id="escaped-source")
        (source_package / "Main.qml").unlink()
        (source_package / "Main.qml").symlink_to(external / "Main.qml")
        manifest_package = self.package("escaped-manifest", id="escaped-manifest")
        (manifest_package / "widget.json").unlink()
        (manifest_package / "widget.json").symlink_to(external / "widget.json")
        result = scan_registry(self.root)
        self.assertEqual(result["registry"], {})
        self.assertEqual(len(result["errors"]), 3)
        self.assertTrue(all("escapes" in error["message"] for error in result["errors"]))

    def test_duplicate_identity_has_no_winner(self):
        self.package("one")
        self.package("two")
        self.package("three")
        result = scan_registry(self.root)
        self.assertEqual(result["registry"], {})
        self.assertEqual(len(result["errors"]), 3)
        self.assertTrue(all("duplicate id" in error["message"] for error in result["errors"]))

    def test_bounded_duplicate_key_and_missing_file_errors(self):
        huge = self.package("huge", id="huge")
        (huge / "widget.json").write_bytes(b" " * (MAX_MANIFEST_BYTES + 1))
        duplicate = self.package("duplicate", id="duplicate")
        (duplicate / "widget.json").write_text('{"id":"one","id":"two"}', encoding="utf-8")
        missing = self.package("missing", id="missing")
        (missing / "Main.qml").unlink()
        result = scan_registry(self.root)
        self.assertEqual(result["registry"], {})
        self.assertEqual(len(result["errors"]), 3)
        self.assertTrue(any("64 KiB" in error["message"] for error in result["errors"]))
        self.assertTrue(any("duplicate field" in error["message"] for error in result["errors"]))

    def test_explicit_xdg_directory_and_cli_partial_errors(self):
        package_root = self.root / "blox-user" / "widgets"
        package_root.mkdir(parents=True)
        self.root = package_root
        self.package("valid")
        self.package("invalid", id="invalid", providers=["unknown"])
        data_home = package_root.parents[1]
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(data_home)}):
            self.assertEqual(list(scan_registry()["registry"]), ["community-clock"])
        command = [sys.executable, "-m", "blox_widgets.cli", "registry", "--root", str(self.root)]
        result = subprocess.run(command, env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "lib")},
                                capture_output=True, text=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertTrue(response["ok"])
        self.assertEqual(list(response["registry"]), ["community-clock"])
        self.assertEqual(len(response["errors"]), 1)

    def test_default_cli_ignores_installed_application_tree(self):
        data_home = self.root
        application = data_home / "blox" / "widgets"
        for name in ("examples", "lib", "qml", "schema", "tests"):
            (application / name).mkdir(parents=True)
        # Even a manifest in the application directory is not a fallback package.
        self.root = application
        self.package("not-user-owned", id="application-package")
        environment = {**os.environ, "XDG_DATA_HOME": str(data_home),
                       "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "lib")}
        command = [sys.executable, "-m", "blox_widgets.cli", "registry"]
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "registry": {}, "errors": []})
        self.root = data_home / "blox-user" / "widgets"
        self.root.mkdir(parents=True)
        package = self.package("user-clock")
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["errors"], [])
        self.assertEqual(list(response["registry"]), ["community-clock"])
        self.assertEqual(response["registry"]["community-clock"]["source"], (package / "Main.qml").as_uri())

    def test_package_count_is_bounded_before_loading_manifests(self):
        for name in ("one", "two", "three"):
            (self.root / name).mkdir()
        with patch("blox_widgets.registry.MAX_PACKAGES", 2):
            with self.assertRaisesRegex(ValidationError, "at most 2"):
                scan_registry(self.root)

    def test_missing_root_empty_and_invalid_root_cli_error(self):
        self.assertEqual(scan_registry(self.root / "absent"), {"registry": {}, "errors": []})
        bad_root = self.root / "file"
        bad_root.write_text("not a directory", encoding="utf-8")
        result = subprocess.run([sys.executable, "-m", "blox_widgets.cli", "registry", "--root", str(bad_root)],
                                env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "lib")},
                                capture_output=True, text=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"]["type"], "io")


if __name__ == "__main__":
    unittest.main()
