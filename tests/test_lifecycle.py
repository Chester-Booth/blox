import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "packaging"))

import layout  # noqa: E402
import install as installer  # noqa: E402
import migrations  # noqa: E402


class Fixture:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="blox-lifecycle-"))
        self._environ = {
            "HOME": str(self.root / "home"),
            "XDG_CONFIG_HOME": str(self.root / "home" / ".config"),
            "XDG_DATA_HOME": str(self.root / "home" / ".local" / "share"),
            "XDG_STATE_HOME": str(self.root / "home" / ".local" / "state"),
            "XDG_CACHE_HOME": str(self.root / "home" / ".cache"),
            "BLOX_PREFIX": str(self.root / "home" / ".local"),
        }
        self._saved = {}

    def __enter__(self):
        for key, value in self._environ.items():
            self._saved[key] = os.environ.get(key)
            os.environ[key] = value
        (self.root / "home").mkdir(parents=True, exist_ok=True)
        return layout.resolve_roots()

    def __exit__(self, *args):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(self.root, ignore_errors=True)


def fake_source(version: str) -> Path:
    source = Path(tempfile.mkdtemp(prefix="blox-source-"))
    (source / "VERSION").write_text(version + "\n", encoding="utf-8")
    shutil.copytree(REPOSITORY / "packaging", source / "packaging", ignore=shutil.ignore_patterns("__pycache__"))
    (source / "shell").mkdir()
    (source / "shell" / "shell.qml").write_text("// shell\n", encoding="utf-8")
    (source / "themes").mkdir()
    (source / "themes" / "defaults").mkdir(parents=True)
    (source / "themes" / "defaults" / "v1.json").write_text("{}\n", encoding="utf-8")
    return source


class LifecycleTests(unittest.TestCase):
    def test_install_creates_manifest_and_repeats_change_nothing(self):
        with Fixture() as roots:
            first = installer.install(roots)
            self.assertTrue(first["installed"])
            self.assertTrue(roots.manifest.is_file())
            self.assertTrue((roots.pkg_root / "shell" / "shell.qml").is_file())
            link = roots.bins / "bloxctl"
            self.assertTrue(link.is_symlink())
            plan = installer.build_plan(roots)
            self.assertEqual(plan.actions, [])
            self.assertEqual(plan.conflicts, [])
            self.assertGreater(plan.unchanged, 0)

    def test_dry_run_writes_nothing(self):
        with Fixture() as roots:
            report = installer.install(roots, dry_run=True)
            self.assertTrue(report["dry_run"])
            self.assertFalse(roots.pkg_root.exists())
            self.assertFalse(roots.manifest.exists())

    def test_foreign_files_conflict_then_back_up_with_force(self):
        with Fixture() as roots:
            foreign = roots.pkg_root / "shell" / "shell.qml"
            foreign.parent.mkdir(parents=True)
            foreign.write_text("foreign\n", encoding="utf-8")
            try:
                installer.install(roots)
            except installer.LifecycleError as error:
                self.assertEqual(error.code, "conflict")
            else:
                self.fail("expected a conflict")
            report = installer.install(roots, force=True)
            self.assertEqual(len(report["backed_up"]), 1)
            ledger = (roots.backups / "ledger.jsonl").read_text(encoding="utf-8").strip().splitlines()
            entry = json.loads(ledger[-1])
            self.assertEqual(entry["sha256"], installer.sha256(Path(entry["backup"])))

    def test_update_keeps_previous_generation_and_records_it(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            source_b = fake_source("0.1.1")
            try:
                installer.install(roots, source_root=source_a)
                result = installer.update(roots, source_root=source_b)
                self.assertTrue(result["updated"])
                self.assertEqual(result["from"], "0.1.0")
                self.assertEqual(result["to"], "0.1.1")
                self.assertTrue(roots.previous_pkg_root.exists())
                ledger = json.loads(roots.generations.read_text(encoding="utf-8"))
                self.assertEqual(ledger[-1]["result"], "applied")
            finally:
                shutil.rmtree(source_a, ignore_errors=True)
                shutil.rmtree(source_b, ignore_errors=True)

    def test_rollback_returns_to_the_previous_generation(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            source_b = fake_source("0.1.1")
            try:
                installer.install(roots, source_root=source_a)
                installer.update(roots, source_root=source_b)
                result = installer.rollback(roots)
                self.assertTrue(result["rolled_back"])
                manifest = json.loads(roots.manifest.read_text(encoding="utf-8"))
                self.assertEqual(manifest["product_version"], "0.1.0")
                self.assertFalse(roots.previous_pkg_root.exists())
            finally:
                shutil.rmtree(source_a, ignore_errors=True)
                shutil.rmtree(source_b, ignore_errors=True)

    def test_uninstall_keeps_user_data_until_purge(self):
        with Fixture() as roots:
            installer.install(roots)
            roots.config.mkdir(parents=True)
            (roots.config / "config.json").write_text("{}", encoding="utf-8")
            report = installer.uninstall(roots)
            self.assertFalse(roots.pkg_root.exists())
            self.assertTrue(roots.config.exists())
            installer.install(roots)
            report = installer.uninstall(roots, purge=True)
            self.assertFalse(roots.config.exists())

    def test_calendar_migration_copies_legacy_file_with_pre_image(self):
        with Fixture() as roots:
            legacy = Path(os.environ["XDG_CONFIG_HOME"]) / "quickshell" / "blox"
            legacy.mkdir(parents=True)
            (legacy / "calendar.json").write_text('{"writable_calendar_ids":["a"]}', encoding="utf-8")
            results = migrations.run_migrations(roots, from_version="0.1.0", to_version="0.1.1")
            calendar = next(entry for entry in results if entry["migration"] == "calendar-config-xdg")
            self.assertEqual(calendar["result"], "applied")
            migrated = roots.config / "calendar.json"
            self.assertEqual(json.loads(migrated.read_text(encoding="utf-8"))["writable_calendar_ids"], ["a"])
            restored = migrations.restore_pre_images(roots)
            self.assertIn(str(migrated), restored)


if __name__ == "__main__":
    unittest.main()


class DesktopEntryTests(unittest.TestCase):
    def test_desktop_entries_install_update_and_uninstall(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                entry = source / "applications" / ".local" / "share" / "applications" / "blox-test.desktop"
                entry.parent.mkdir(parents=True, exist_ok=True)
                entry.write_text("[Desktop Entry]\nType=Application\nName=Blox Test\n", encoding="utf-8")
                installer.install(roots, source_root=source)
                data_home = roots.data.parent
                installed_entry = data_home / "applications" / "blox-test.desktop"
                self.assertTrue(installed_entry.is_file())
                manifest = json.loads(roots.manifest.read_text(encoding="utf-8"))
                self.assertIn("applications/blox-test.desktop", manifest["data_files"])
                # idempotent repeat
                plan = installer.build_plan(roots, source)
                self.assertEqual(plan.actions, [])
                # uninstall removes them
                installer.uninstall(roots)
                self.assertFalse(installed_entry.exists())
            finally:
                shutil.rmtree(source, ignore_errors=True)
