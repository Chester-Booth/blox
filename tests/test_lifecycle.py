import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
from unittest import mock
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


class SymlinkUnitTests(unittest.TestCase):
    def test_unit_symlink_is_replaced_without_touching_its_target(self):
        with Fixture() as roots:
            # A mock dotfiles tree owns the real unit file; the live path is
            # a symlink into it, exactly like the checkout machine.
            dotfiles = Path(os.environ["BLOX_PREFIX"]).parent / "dotfiles" / "systemd"
            dotfiles.mkdir(parents=True)
            real = dotfiles / "quickshell.service"
            real.write_text("[Unit]\nDescription=checkout original\n", encoding="utf-8")
            live = roots.systemd_user / "quickshell.service"
            live.parent.mkdir(parents=True, exist_ok=True)
            live.symlink_to(real)

            installer.install(roots, force=True)

            # Target byte-identical, link replaced by an owned regular file.
            self.assertEqual(real.read_text(encoding="utf-8"), "[Unit]\nDescription=checkout original\n")
            self.assertFalse(live.is_symlink())
            installed = live.read_text(encoding="utf-8")
            self.assertIn("@PKG_ROOT@".replace("@PKG_ROOT@", str(roots.pkg_root)), installed)
            entry = json.loads((roots.backups / "ledger.jsonl").read_text(encoding="utf-8").strip().splitlines()[-1])
            self.assertEqual(entry["kind"], "symlink")
            self.assertEqual(entry["target_of_link"], str(real))


class DataSeparationTests(unittest.TestCase):
    def _seed_imported_theme(self, roots):
        imported = roots.data / "imported-themes"
        imported.mkdir(parents=True, exist_ok=True)
        theme = imported / "user-theme.json"
        theme.write_text('{"id": "user-theme"}\n', encoding="utf-8")
        return theme

    def _assert_theme_survives(self, roots, theme):
        self.assertTrue(theme.is_file())
        self.assertEqual(theme.read_text(encoding="utf-8"), '{"id": "user-theme"}\n')

    def test_user_data_survives_install_update_rollback_and_uninstall(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            source_b = fake_source("0.1.1")
            try:
                theme = self._seed_imported_theme(roots)
                installer.install(roots, source_root=source_a)
                self._assert_theme_survives(roots, theme)
                installer.update(roots, source_root=source_b)
                self._assert_theme_survives(roots, theme)
                installer.rollback(roots)
                self._assert_theme_survives(roots, theme)
                installer.uninstall(roots)
                self._assert_theme_survives(roots, theme)
                # Immutable and mutable trees stay distinct directories.
                self.assertNotEqual(roots.pkg_root, roots.data)
                self.assertFalse(roots.pkg_root.exists())
            finally:
                shutil.rmtree(source_a, ignore_errors=True)
                shutil.rmtree(source_b, ignore_errors=True)


class MigrationRestoreTests(unittest.TestCase):
    def test_restore_removes_destination_the_migration_created(self):
        with Fixture() as roots:
            legacy = Path(os.environ["XDG_CONFIG_HOME"]) / "quickshell" / "blox"
            legacy.mkdir(parents=True)
            (legacy / "calendar.json").write_text('{"writable_calendar_ids":["a"]}', encoding="utf-8")
            migrations.run_migrations(roots, from_version="0.1.0", to_version="0.1.1")
            migrated = roots.config / "calendar.json"
            self.assertTrue(migrated.is_file())
            migrations.restore_pre_images(roots)
            # The destination did not exist before the migration; rollback
            # removes it instead of recreating it.
            self.assertFalse(migrated.exists())

    def test_restore_leaves_pre_existing_destinations_alone(self):
        with Fixture() as roots:
            roots.config.mkdir(parents=True, exist_ok=True)
            existing = roots.config / "calendar.json"
            existing.write_text("{}", encoding="utf-8")
            results = migrations.run_migrations(roots, from_version="0.1.0", to_version="0.1.1")
            calendar = next(entry for entry in results if entry["migration"] == "calendar-config-xdg")
            self.assertEqual(calendar["result"], "nothing-to-do")
            migrations.restore_pre_images(roots)
            self.assertEqual(existing.read_text(encoding="utf-8"), "{}")


class InstallMigrationsTests(unittest.TestCase):
    def test_first_install_runs_migrations_in_the_transaction(self):
        with Fixture() as roots:
            legacy = Path(os.environ["XDG_CONFIG_HOME"]) / "quickshell" / "blox"
            legacy.mkdir(parents=True)
            (legacy / "env").write_text("PERSONAL_TOKEN=abc\n", encoding="utf-8")

            report = installer.install(roots)

            migrated = [entry["migration"] for entry in report.get("migrations", [])]
            self.assertIn("shell-env-config", migrated)
            self.assertTrue((roots.config / "env").is_file())
            ledger = json.loads(roots.generations.read_text(encoding="utf-8"))
            self.assertEqual(ledger[-1]["result"], "installed")


class LegacyThemeMigrationTests(unittest.TestCase):
    def _seed_legacy_themes(self):
        legacy = Path(os.environ["XDG_DATA_HOME"]) / "blox" / "themes"
        legacy.mkdir(parents=True)
        (legacy / "imported.json").write_text('{"id": "old-import"}\n', encoding="utf-8")
        (legacy / "nested").mkdir()
        (legacy / "nested" / "deep.json").write_text('{"id": "deep"}\n', encoding="utf-8")
        return legacy

    def _assert_migrated(self, roots, legacy):
        # Content is preserved byte-for-byte at the separated root; the
        # contested legacy originals are removed once the install commits.
        new_root = roots.data / "themes"
        self.assertEqual((new_root / "imported.json").read_text(encoding="utf-8"), '{"id": "old-import"}\n')
        self.assertEqual((new_root / "nested" / "deep.json").read_text(encoding="utf-8"), '{"id": "deep"}\n')

    def test_first_install_relocates_legacy_themes(self):
        with Fixture() as roots:
            legacy = self._seed_legacy_themes()
            report = installer.install(roots)
            moved = next(entry for entry in report["migrations"] if entry["migration"] == "legacy-user-themes")
            self.assertEqual(moved["result"], "applied")
            self._assert_migrated(roots, legacy)

    def test_migration_survives_update_rollback_and_uninstall(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            source_b = fake_source("0.1.1")
            try:
                legacy = self._seed_legacy_themes()
                installer.install(roots, source_root=source_a)
                installer.update(roots, source_root=source_b)
                self._assert_migrated(roots, legacy)
                installer.rollback(roots)
                self._assert_migrated(roots, legacy)
                installer.uninstall(roots)
                self._assert_migrated(roots, legacy)
            finally:
                shutil.rmtree(source_a, ignore_errors=True)
                shutil.rmtree(source_b, ignore_errors=True)

    def test_conflicting_destination_is_left_untouched_and_reported(self):
        with Fixture() as roots:
            self._seed_legacy_themes()
            conflicting = roots.data / "themes" / "imported.json"
            conflicting.parent.mkdir(parents=True, exist_ok=True)
            conflicting.write_text('{"id": "users-newer-version"}\n', encoding="utf-8")
            report = installer.install(roots)
            moved = next(entry for entry in report["migrations"] if entry["migration"] == "legacy-user-themes")
            self.assertIn(str(conflicting), moved.get("conflicts", []))
            self.assertEqual(conflicting.read_text(encoding="utf-8"), '{"id": "users-newer-version"}\n')


class TransactionalFailureTests(unittest.TestCase):
    def _snapshot_state(self, roots):
        state = {}
        for label, base in (("pkg", roots.pkg_root), ("units", roots.systemd_user), ("bins", roots.bins), ("data", roots.data)):
            files = {}
            if base.is_dir():
                for path in sorted(base.rglob("*")):
                    if path.is_file() or path.is_symlink():
                        key = str(path.relative_to(base))
                        if path.is_symlink():
                            files[key] = "link:" + os.readlink(path)
                        else:
                            files[key] = installer.sha256(path)
            state[label] = files
        state["manifest"] = roots.manifest.read_bytes() if roots.manifest.exists() else None
        return state

    def test_failed_install_restores_exact_prior_state(self):
        with Fixture() as roots:
            before = self._snapshot_state(roots)
            real_copy2 = shutil.copy2
            calls = {"n": 0}

            def exploding(source, destination, **kwargs):
                if "/share/blox/" in str(destination):
                    raise OSError("injected copy failure")
                return real_copy2(source, destination, **kwargs)

            with mock.patch.object(installer.shutil, "copy2", side_effect=exploding):
                with self.assertRaises(OSError):
                    installer.install(roots)
            self.assertEqual(self._snapshot_state(roots), before)
            ledger_lines = migrations.read_ledger(roots)
            self.assertEqual(ledger_lines, [])

    def test_failed_update_restores_previous_tree_and_ledger(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            source_b = fake_source("0.1.1")
            try:
                installer.install(roots, source_root=source_a)
                before = self._snapshot_state(roots)
                generations_before = roots.generations.read_bytes()

                with mock.patch.object(migrations, "run_migrations", side_effect=OSError("injected migration failure")):
                    with self.assertRaises(OSError):
                        installer.update(roots, source_root=source_b)

                after = self._snapshot_state(roots)
                self.assertEqual(after["pkg"], before["pkg"])
                self.assertFalse(roots.previous_pkg_root.exists())
                manifest = json.loads(roots.manifest.read_text(encoding="utf-8"))
                self.assertEqual(manifest["product_version"], "0.1.0")
                self.assertEqual(roots.generations.read_bytes(), generations_before)
            finally:
                shutil.rmtree(source_a, ignore_errors=True)
                shutil.rmtree(source_b, ignore_errors=True)

    def test_failed_unit_render_restores_symlinked_units(self):
        with Fixture() as roots:
            dotfiles = Path(os.environ["BLOX_PREFIX"]).parent / "dotfiles" / "systemd"
            dotfiles.mkdir(parents=True)
            real = dotfiles / "quickshell.service"
            original = "[Unit]\nDescription=checkout original\n"
            real.write_text(original, encoding="utf-8")
            live = roots.systemd_user / "quickshell.service"
            live.parent.mkdir(parents=True, exist_ok=True)
            live.symlink_to(real)

            real_render = installer.render_unit

            def exploding_render(template, *args, **kwargs):
                raise OSError("injected render failure")

            with mock.patch.object(installer, "render_unit", side_effect=exploding_render):
                with self.assertRaises(OSError):
                    installer.install(roots, force=True)

            self.assertTrue(live.is_symlink())
            self.assertEqual(os.readlink(live), str(real))
            self.assertEqual(real.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
