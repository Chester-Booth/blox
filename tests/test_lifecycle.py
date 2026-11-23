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
    def test_upgrade_retires_owned_desktop_icon_and_binary_alias_with_backups(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                desktop = source / "applications/.local/share/applications/old.desktop"
                icon = source / "applications/.local/share/icons/old.svg"
                for path, content in ((desktop, b"old desktop\n"), (icon, b"old icon\n")):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
                with mock.patch.object(installer, "INSTALLED_BINS", ("old-launcher",)):
                    installer.install(roots, source_root=source)
                old_link = roots.bins / "old-launcher"
                old_target = os.readlink(old_link)
                desktop.unlink()
                icon.unlink()
                report = installer.install(roots, source_root=source)
                self.assertFalse((roots.data.parent / "applications/old.desktop").exists())
                self.assertFalse((roots.data.parent / "icons/old.svg").exists())
                self.assertFalse(old_link.is_symlink())
                self.assertEqual(2, sum(action["kind"] == "remove-data" for action in report["plan"]["actions"]))
                self.assertEqual(1, sum(action["kind"] == "remove-bin" for action in report["plan"]["actions"]))
                self.assertEqual(b"old desktop\n", next(roots.backups.glob("*/data/applications/old.desktop")).read_bytes())
                self.assertEqual(b"old icon\n", next(roots.backups.glob("*/data/icons/old.svg")).read_bytes())
                self.assertEqual(old_target, os.readlink(next(roots.backups.glob("*/bins/old-launcher"))))
                self.assertEqual([], installer.build_plan(roots, source).actions)
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_retired_data_and_bin_personal_changes_are_preserved_even_with_force(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                relatives = ("applications/old.desktop", "icons/linked.svg", "icons/legacy/nested.svg")
                for relative in relatives:
                    path = source / "applications/.local/share" / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"old\n")
                with mock.patch.object(installer, "INSTALLED_BINS", ("old-link", "old-file")):
                    installer.install(roots, source_root=source)
                data_home = roots.data.parent
                (data_home / relatives[0]).write_bytes(b"personal desktop\n")
                foreign = roots.config / "personal.svg"
                foreign.write_bytes(b"old\n")
                (data_home / relatives[1]).unlink()
                (data_home / relatives[1]).symlink_to(foreign)
                outside = roots.config / "personal-icons"
                outside.mkdir()
                (outside / "nested.svg").write_bytes(b"old\n")
                shutil.rmtree(data_home / "icons/legacy")
                (data_home / "icons/legacy").symlink_to(outside, target_is_directory=True)
                for name in ("old-link", "old-file"):
                    (roots.bins / name).unlink()
                (roots.bins / "old-link").symlink_to(foreign)
                (roots.bins / "old-file").write_bytes(b"personal executable\n")
                for relative in relatives:
                    (source / "applications/.local/share" / relative).unlink()
                report = installer.install(roots, source_root=source, force=True)
                self.assertEqual(5, len(report["plan"]["leftovers"]))
                self.assertEqual(b"personal desktop\n", (data_home / relatives[0]).read_bytes())
                self.assertTrue((data_home / relatives[1]).is_symlink())
                self.assertTrue((data_home / "icons/legacy").is_symlink())
                self.assertEqual(b"old\n", foreign.read_bytes())
                self.assertEqual(b"old\n", (outside / "nested.svg").read_bytes())
                self.assertEqual(str(foreign), os.readlink(roots.bins / "old-link"))
                self.assertEqual(b"personal executable\n", (roots.bins / "old-file").read_bytes())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_retired_data_and_bin_removal_requires_current_user_ownership(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                desktop = source / "applications/.local/share/applications/old.desktop"
                desktop.parent.mkdir(parents=True)
                desktop.write_bytes(b"old\n")
                with mock.patch.object(installer, "INSTALLED_BINS", ("old-launcher",)):
                    installer.install(roots, source_root=source)
                desktop.unlink()
                uid = os.getuid()
                with mock.patch.object(installer.os, "getuid", return_value=uid + 1):
                    plan = installer.build_plan(roots, source)
                    with self.assertRaises(installer.LifecycleError):
                        installer.install(roots, source_root=source, force=True, migrate=False)
                self.assertEqual(2, len(plan.leftovers))
                self.assertEqual(b"old\n", (roots.data.parent / "applications/old.desktop").read_bytes())
                self.assertTrue((roots.bins / "old-launcher").is_symlink())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_later_failure_restores_retired_desktop_binary_link_and_manifest(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                desktop = source / "applications/.local/share/applications/old.desktop"
                desktop.parent.mkdir(parents=True)
                desktop.write_bytes(b"old\n")
                with mock.patch.object(installer, "INSTALLED_BINS", ("old-launcher",)):
                    installer.install(roots, source_root=source)
                old_link = roots.bins / "old-launcher"
                old_target = os.readlink(old_link)
                before = roots.manifest.read_bytes()
                desktop.unlink()
                real_copy = installer.shutil.copy2
                def fail_version(source_path, destination, *args, **kwargs):
                    if Path(source_path) == source / "VERSION":
                        raise OSError("injected final copy failure")
                    return real_copy(source_path, destination, *args, **kwargs)
                with mock.patch.object(installer.shutil, "copy2", side_effect=fail_version):
                    with self.assertRaises(OSError):
                        installer.install(roots, source_root=source)
                self.assertEqual(b"old\n", (roots.data.parent / "applications/old.desktop").read_bytes())
                self.assertEqual(old_target, os.readlink(old_link))
                self.assertEqual(before, roots.manifest.read_bytes())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_interrupt_at_retired_binary_unlink_restores_data_link_and_manifest(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                desktop = source / "applications/.local/share/applications/old.desktop"
                desktop.parent.mkdir(parents=True)
                desktop.write_bytes(b"old\n")
                with mock.patch.object(installer, "INSTALLED_BINS", ("old-launcher",)):
                    installer.install(roots, source_root=source)
                old_link = roots.bins / "old-launcher"
                target = os.readlink(old_link)
                before = roots.manifest.read_bytes()
                desktop.unlink()
                real_unlink = installer.os.unlink
                def interrupt_after_removal(path, *args, **kwargs):
                    real_unlink(path, *args, **kwargs)
                    if path == "old-launcher" and "dir_fd" in kwargs:
                        raise KeyboardInterrupt("interrupted immediately after removal")
                with mock.patch.object(installer.os, "unlink", side_effect=interrupt_after_removal):
                    with self.assertRaises(KeyboardInterrupt):
                        installer.install(roots, source_root=source)
                self.assertEqual(b"old\n", (roots.data.parent / "applications/old.desktop").read_bytes())
                self.assertEqual(target, os.readlink(old_link))
                self.assertEqual(before, roots.manifest.read_bytes())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_install_removes_only_unchanged_retired_package_files(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                old = source / "shell/old-picker.qml"
                old.write_bytes(b"obsolete picker\n")
                old.chmod(0o640)
                installer.install(roots, source_root=source)
                installed = roots.pkg_root / "shell/old-picker.qml"
                unrecorded = roots.pkg_root / "shell/personal.qml"
                unrecorded.write_bytes(b"personal\n")
                old.unlink()
                plan = installer.build_plan(roots, source)
                self.assertEqual([installed], [action.target for action in plan.actions if action.kind == "remove-owned"])
                report = installer.install(roots, source_root=source)
                self.assertFalse(installed.exists())
                self.assertEqual(b"personal\n", unrecorded.read_bytes())
                self.assertIn(str(installed), report["backed_up"])
                backup = next(roots.backups.glob("*/pkg/shell/old-picker.qml"))
                self.assertEqual(b"obsolete picker\n", backup.read_bytes())
                self.assertEqual(0o640, backup.stat().st_mode & 0o777)
                self.assertNotIn("shell/old-picker.qml", json.loads(roots.manifest.read_text())["files"])
                self.assertEqual([], installer.build_plan(roots, source).actions)
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_retired_modified_files_and_symlink_paths_are_preserved_even_with_force(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                nested = source / "shell/legacy"
                nested.mkdir()
                for name in ("modified.qml", "linked.qml", "legacy/nested.qml"):
                    (source / "shell" / name).write_bytes(b"old\n")
                installer.install(roots, source_root=source)
                modified = roots.pkg_root / "shell/modified.qml"
                modified.write_bytes(b"personal edit\n")
                linked = roots.pkg_root / "shell/linked.qml"
                linked.unlink()
                foreign = roots.config / "foreign.qml"
                foreign.write_bytes(b"old\n")
                linked.symlink_to(foreign)
                directory = roots.pkg_root / "shell/legacy"
                shutil.rmtree(directory)
                outside = roots.config / "personal-directory"
                outside.mkdir()
                (outside / "nested.qml").write_bytes(b"old\n")
                directory.symlink_to(outside, target_is_directory=True)
                for name in ("modified.qml", "linked.qml", "legacy/nested.qml"):
                    (source / "shell" / name).unlink()
                report = installer.install(roots, source_root=source, force=True)
                self.assertEqual(3, len(report["plan"]["leftovers"]))
                self.assertEqual(b"personal edit\n", modified.read_bytes())
                self.assertTrue(linked.is_symlink())
                self.assertTrue(directory.is_symlink())
                self.assertEqual(b"old\n", foreign.read_bytes())
                self.assertEqual(b"old\n", (outside / "nested.qml").read_bytes())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_retired_package_removal_requires_current_user_ownership(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                old = source / "shell/old.qml"
                old.write_bytes(b"old\n")
                installer.install(roots, source_root=source)
                old.unlink()
                uid = os.getuid()
                with mock.patch.object(installer.os, "getuid", return_value=uid + 1):
                    plan = installer.build_plan(roots, source)
                    with self.assertRaises(installer.LifecycleError):
                        installer.install(roots, source_root=source, force=True, migrate=False)
                self.assertEqual(1, len(plan.leftovers))
                self.assertEqual(b"old\n", (roots.pkg_root / "shell/old.qml").read_bytes())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_install_failure_restores_retired_file_and_manifest(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                old = source / "shell/old.qml"
                old.write_bytes(b"old\n")
                installer.install(roots, source_root=source)
                before = roots.manifest.read_bytes()
                old.unlink()
                real_copy = installer.shutil.copy2
                def fail_version(source_path, destination, *args, **kwargs):
                    if Path(source_path) == source / "VERSION":
                        raise OSError("injected final copy failure")
                    return real_copy(source_path, destination, *args, **kwargs)
                with mock.patch.object(installer.shutil, "copy2", side_effect=fail_version):
                    with self.assertRaises(OSError):
                        installer.install(roots, source_root=source)
                self.assertEqual(b"old\n", (roots.pkg_root / "shell/old.qml").read_bytes())
                self.assertEqual(before, roots.manifest.read_bytes())
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_private_config_migration_preserves_bytes_and_failure_restores_mode(self):
        with Fixture() as roots:
            roots.config.mkdir(parents=True, mode=0o755)
            env = roots.config / "env"
            env.write_bytes(b"personal environment\n")
            roots.backups.mkdir(parents=True)
            before = len(migrations.read_ledger(roots))
            migrations.run_migrations(roots, "old", "new")
            self.assertEqual(roots.config.stat().st_mode & 0o777, 0o700)
            self.assertEqual(env.read_bytes(), b"personal environment\n")
            migrations.restore_ledger_after(roots, before)
            self.assertEqual(roots.config.stat().st_mode & 0o777, 0o755)
            self.assertEqual(env.read_bytes(), b"personal environment\n")

    def test_private_config_migration_refuses_symlink(self):
        with Fixture() as roots:
            roots.config.parent.mkdir(parents=True)
            other = roots.config.parent / "personal"
            other.mkdir(mode=0o755)
            roots.config.symlink_to(other)
            with self.assertRaises(OSError):
                migrations.migrate_private_config(roots, roots.backups)
            self.assertEqual(other.stat().st_mode & 0o777, 0o755)

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
            roots.config.mkdir(parents=True, exist_ok=True)
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
    def test_helium_desktop_id_rename_removes_only_the_old_blox_entry(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                source_entry = source / "applications/.local/share/applications/helium.desktop"
                source_entry.parent.mkdir(parents=True, exist_ok=True)
                source_entry.write_text(
                    "[Desktop Entry]\nName=Helium Browser\nExec=blox-helium-browser %U\n",
                    encoding="utf-8",
                )
                legacy = roots.data.parent / "applications/helium-browser.desktop"
                legacy.parent.mkdir(parents=True, exist_ok=True)
                legacy.write_text(source_entry.read_text(encoding="utf-8"), encoding="utf-8")

                installer.install(roots, source_root=source)

                self.assertFalse(legacy.exists())
                self.assertTrue((roots.data.parent / "applications/helium.desktop").is_file())
                ledger = migrations.read_ledger(roots)
                self.assertTrue(any(entry["migration"] == "helium-desktop-id" and entry["result"] == "applied" for entry in ledger))
            finally:
                shutil.rmtree(source, ignore_errors=True)

    def test_helium_desktop_id_rename_keeps_a_foreign_old_entry(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                source_entry = source / "applications/.local/share/applications/helium.desktop"
                source_entry.parent.mkdir(parents=True, exist_ok=True)
                source_entry.write_text("[Desktop Entry]\nName=Helium Browser\nExec=blox-helium-browser %U\n", encoding="utf-8")
                legacy = roots.data.parent / "applications/helium-browser.desktop"
                legacy.parent.mkdir(parents=True, exist_ok=True)
                legacy.write_text("[Desktop Entry]\nName=Helium Browser\nExec=helium-browser %U\n", encoding="utf-8")

                installer.install(roots, source_root=source)

                self.assertTrue(legacy.is_file())
            finally:
                shutil.rmtree(source, ignore_errors=True)

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


class ThemeStateRootMigrationTests(unittest.TestCase):
    @staticmethod
    def _pre_release_state(roots):
        return roots.state.parent / "blox-theme"

    def _seed_state(self, roots):
        legacy = self._pre_release_state(roots)
        generation = legacy / "generations" / "20260901T120000Z-12345678"
        generation.mkdir(parents=True)
        (generation / "cursor" / "metadata.json").parent.mkdir()
        (generation / "cursor" / "metadata.json").write_text('{"cache_key":"abc"}\n', encoding="utf-8")
        (generation / "integration.json").write_text('{"version":1}\n', encoding="utf-8")
        (legacy / "current").symlink_to("generations/20260901T120000Z-12345678")
        (legacy / "active.json").symlink_to("current/manifest.json")
        (generation / "manifest.json").write_text("{}\n", encoding="utf-8")
        return legacy

    def test_state_root_migration_preserves_tree_links_and_can_restore(self):
        with Fixture() as roots:
            legacy = self._seed_state(roots)
            results = migrations.run_migrations(roots, from_version="0.1.0", to_version="0.1.1")
            entry = next(item for item in results if item["migration"] == "theme-state-root")

            self.assertEqual(entry["result"], "applied")
            self.assertTrue(roots.theme_state.is_dir())
            self.assertFalse(legacy.exists())
            self.assertEqual("generations/20260901T120000Z-12345678", os.readlink(roots.theme_state / "current"))
            self.assertEqual("current/manifest.json", os.readlink(roots.theme_state / "active.json"))
            self.assertEqual('{"cache_key":"abc"}\n', (roots.theme_state / "current/cursor/metadata.json").read_text(encoding="utf-8"))
            self.assertTrue(Path(entry["pre_image_tree"]).is_dir())

            repeated = migrations.run_migrations(roots, from_version="0.1.1", to_version="0.1.2")
            repeated_entry = next(item for item in repeated if item["migration"] == "theme-state-root")
            self.assertEqual(repeated_entry["result"], "nothing-to-do")

            migrations.restore_ledger_after(roots, 0)
            self.assertTrue(legacy.is_dir())
            self.assertFalse(legacy.is_symlink())
            self.assertFalse(roots.theme_state.exists())
            self.assertEqual("generations/20260901T120000Z-12345678", os.readlink(legacy / "current"))
            self.assertEqual('{"cache_key":"abc"}\n', (legacy / "current/cursor/metadata.json").read_text(encoding="utf-8"))

    def test_state_root_migration_rejects_links_outside_the_tree(self):
        with Fixture() as roots:
            legacy = self._pre_release_state(roots)
            legacy.mkdir(parents=True)
            outside = Path(os.environ["HOME"]).parent / "outside"
            outside.mkdir()
            (legacy / "current").symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "absolute link"):
                migrations.migrate_theme_state_root(roots, roots.backups / "test")
            self.assertTrue(legacy.is_dir())
            self.assertFalse(roots.theme_state.exists())

    def test_state_root_migration_repoints_external_generated_links_and_restores_them(self):
        with Fixture() as roots:
            legacy = self._seed_state(roots)
            config_home = roots.config.parent
            data_home = roots.data.parent
            links = {
                config_home / "hypr/blox-theme.lua": legacy / "current/hyprland/theme.lua",
                config_home / "gtk-3.0/settings.ini": legacy / "current/gtk/gtk-3.0/settings.ini",
                config_home / "kitty/blox-theme.conf": legacy / "current/kitty/theme.conf",
                data_home / "icons/blox-generated": legacy / "cursors/cache/theme",
            }
            for link, target in links.items():
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(target)

            foreign = config_home / "some-app/theme-link"
            foreign.parent.mkdir(parents=True, exist_ok=True)
            foreign.symlink_to(legacy / "current/foreign/theme.css")

            results = migrations.run_migrations(roots, from_version="0.1.0", to_version="0.1.1")
            entry = next(item for item in results if item["migration"] == "theme-state-links")

            self.assertEqual(entry["result"], "applied")
            for link, target in links.items():
                self.assertEqual(str(roots.theme_state / target.relative_to(legacy)), os.readlink(link))
            self.assertEqual(str(legacy / "current/foreign/theme.css"), os.readlink(foreign))

            migrations.restore_ledger_after(roots, 0)
            for link, target in links.items():
                self.assertEqual(str(target), os.readlink(link))
            self.assertEqual(str(legacy / "current/foreign/theme.css"), os.readlink(foreign))


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

    def test_failed_first_install_restores_the_pre_release_theme_state_root(self):
        with Fixture() as roots:
            legacy = roots.state.parent / "blox-theme"
            legacy.mkdir(parents=True)
            (legacy / "cursors/cache-marker").parent.mkdir(parents=True)
            (legacy / "cursors/cache-marker").write_bytes(b"old state")
            real_copy2 = shutil.copy2

            def exploding(source, destination, **kwargs):
                if "/share/blox/" in str(destination):
                    raise OSError("injected package copy failure")
                return real_copy2(source, destination, **kwargs)

            with mock.patch.object(installer.shutil, "copy2", side_effect=exploding):
                with self.assertRaises(OSError):
                    installer.install(roots)
            self.assertTrue(legacy.is_dir())
            self.assertFalse(legacy.is_symlink())
            self.assertEqual(b"old state", (legacy / "cursors/cache-marker").read_bytes())
            self.assertFalse(roots.theme_state.exists())
            self.assertEqual([], migrations.read_ledger(roots))


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


def snapshot_state(roots):
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


class TransactionalFailureTests(unittest.TestCase):
    def _snapshot_state(self, roots):
        return snapshot_state(roots)

    def test_failed_install_restores_exact_prior_state(self):
        with Fixture() as roots:
            before = snapshot_state(roots)
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
                before = snapshot_state(roots)
                generations_before = roots.generations.read_bytes()

                with mock.patch.object(migrations, "run_migrations", side_effect=OSError("injected migration failure")):
                    with self.assertRaises(OSError):
                        installer.update(roots, source_root=source_b)

                after = snapshot_state(roots)
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


class VersionJournalTests(unittest.TestCase):
    def test_failed_manifest_write_restores_version_units_and_links(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source_a)
                before = snapshot_state(roots)

                # Same version, different payload: every package file becomes
                # an owned update, so the journal carries real backups.
                (source_a / "shell" / "shell.qml").write_text("// changed\n", encoding="utf-8")

                real_dumps = installer.json.dumps

                def exploding(payload=None, **kwargs):
                    if isinstance(payload, dict) and payload.get("manifest_version") == 1:
                        raise OSError("injected manifest-write failure")
                    return real_dumps(payload, **kwargs)

                with mock.patch.object(installer.json, "dumps", side_effect=exploding):
                    with self.assertRaises(OSError):
                        installer.install(roots, source_root=source_a)

                after = snapshot_state(roots)
                self.assertEqual(after["pkg"], before["pkg"])
                self.assertEqual(after["units"], before["units"])
                self.assertEqual(after["bins"], before["bins"])
                self.assertEqual(after["manifest"], before["manifest"])
                # The VERSION backup was real, not a placeholder string.
                ledger_lines = [json.loads(line) for line in (roots.backups / "ledger.jsonl").read_text(encoding="utf-8").strip().splitlines()]
                version_entries = [e for e in ledger_lines if e["original"].endswith("/VERSION")]
                self.assertTrue(version_entries)
                self.assertTrue(Path(version_entries[-1]["backup"]).is_file())
            finally:
                shutil.rmtree(source_a, ignore_errors=True)


class PreviousGenerationPreservationTests(unittest.TestCase):
    def test_failed_update_keeps_current_and_previous_intact(self):
        with Fixture() as roots:
            sources = {v: fake_source(v) for v in ("0.1.0", "0.1.1", "0.1.2")}
            try:
                installer.install(roots, source_root=sources["0.1.0"])
                installer.update(roots, source_root=sources["0.1.1"])

                with mock.patch.object(migrations, "run_migrations", side_effect=OSError("injected")):
                    with self.assertRaises(OSError):
                        installer.update(roots, source_root=sources["0.1.2"])

                manifest = json.loads(roots.manifest.read_text(encoding="utf-8"))
                self.assertEqual(manifest["product_version"], "0.1.1", "current must remain B")
                previous_manifest = json.loads((roots.previous_pkg_root / "manifest.json").read_text(encoding="utf-8"))
                self.assertEqual(previous_manifest["product_version"], "0.1.0", "previous must remain A")
                generations = json.loads(roots.generations.read_text(encoding="utf-8"))
                self.assertEqual(generations[-1]["result"], "applied")
                self.assertEqual(generations[-1]["to"], "0.1.1")
                snapshots = list(roots.state.glob(".update-snapshot-*"))
                self.assertEqual(snapshots, [])
            finally:
                for source in sources.values():
                    shutil.rmtree(source, ignore_errors=True)


class ActiveThemeManifestMigrationTests(unittest.TestCase):
    def _seed_active_manifest(self, legacy_root):
        # Real topology: active.json -> current/manifest.json and
        # current -> generations/<id>, both relative links.
        state = Path(os.environ["XDG_STATE_HOME"]) / "blox-theme"
        generation_id = "20260820T122956Z-1a6d2fd2"
        generations = state / "generations" / generation_id
        generations.mkdir(parents=True, exist_ok=True)
        document = {
            "created_at": "2026-08-20T12:29:56+00:00",
            "source": str(legacy_root / "themes" / "default-many-widgets.json"),
            "enabled_targets": ["quickshell", "gtk", "wallpaper"],
            "target_sources": {
                "quickshell": {"source": str(legacy_root / "themes" / "default-many-widgets.json")},
                "code": {"source": "/home/someone/code/personal-checkout/themes/builtin/frappe.json"},
                "wallpaper": {"source": str(legacy_root / "themes" / "default-many-widgets.json")},
            },
            "metadata": {"path": str(legacy_root / "themes" / "default-many-widgets.json")},
        }
        manifest_path = generations / "manifest.json"
        original = json.dumps(document, indent=2) + "\n"
        manifest_path.write_text(original, encoding="utf-8")
        (state / "current").symlink_to(f"generations/{generation_id}")
        active = state / "active.json"
        active.symlink_to("current/manifest.json")
        return active, manifest_path, original

    def test_active_manifest_paths_are_rewritten_with_pre_image(self):
        with Fixture() as roots:
            legacy_home = Path(os.environ["XDG_DATA_HOME"]) / "blox"
            (legacy_home / "themes").mkdir(parents=True, exist_ok=True)
            (legacy_home / "themes" / "default-many-widgets.json").write_text('{"id": "x"}\n', encoding="utf-8")
            active_link, manifest_path, original = self._seed_active_manifest(legacy_home)
            generation_id = "20260820T122956Z-1a6d2fd2"
            pre_release_current = manifest_path.parents[2] / "current"

            report = installer.install(roots)
            entry = next(e for e in report["migrations"] if e["migration"] == "active-theme-paths")
            self.assertEqual(entry["result"], "applied")

            canonical_state = Path(os.environ["XDG_STATE_HOME"]) / "blox" / "theme"
            migrated_active = canonical_state / "active.json"
            migrated_current = canonical_state / "current"
            migrated_manifest_path = canonical_state / "generations" / generation_id / "manifest.json"
            self.assertTrue(canonical_state.is_dir())
            self.assertFalse((canonical_state.parent / "blox-theme").exists())
            self.assertTrue(migrated_active.is_symlink() and migrated_current.is_symlink())
            self.assertEqual(os.readlink(migrated_active), "current/manifest.json")
            self.assertEqual(os.readlink(migrated_current), f"generations/{generation_id}")
            self.assertEqual(migrated_active.resolve(), migrated_manifest_path.resolve())
            migrated = json.loads(migrated_manifest_path.read_text(encoding="utf-8"))
            new_prefix = str(roots.data / "themes")
            self.assertTrue(migrated["source"].startswith(new_prefix))
            self.assertTrue(migrated["target_sources"]["quickshell"]["source"].startswith(new_prefix))
            self.assertTrue(migrated["metadata"]["path"].startswith(str(legacy_home / "themes")))
            # The checkout reference is machine policy and stays untouched.
            self.assertEqual(
                migrated["target_sources"]["code"]["source"],
                "/home/someone/code/personal-checkout/themes/builtin/frappe.json",
            )
            # Pre-image preserves the exact original bytes.
            pre_image = Path(entry["pre_image_file"])
            self.assertEqual(pre_image.read_text(encoding="utf-8"), original)

            # Transactional undo of just this entry restores the original.
            ledger = migrations.read_ledger(roots)
            migrations.restore_ledger_after(roots, len(ledger) - 1)
            self.assertEqual(migrated_manifest_path.read_text(encoding="utf-8"), original)
            self.assertFalse(active_link.is_symlink())
            self.assertFalse(pre_release_current.is_symlink())


if __name__ == "__main__":
    unittest.main()


class StaleManifestTests(unittest.TestCase):
    def test_out_of_band_sync_of_identical_content_is_not_a_conflict(self):
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source_a)
                # Simulate an out-of-band sync that updates both the source
                # tree and the installed copy while the manifest still
                # records the previous checksums.
                (source_a / "shell" / "shell.qml").write_text("// synced\n", encoding="utf-8")
                shutil.copy2(source_a / "shell" / "shell.qml",
                             roots.pkg_root / "shell" / "shell.qml")

                report = installer.install(roots, source_root=source_a)
                self.assertTrue(report["installed"])
                self.assertEqual(report["plan"]["conflicts"], [])
                plan_after = installer.build_plan(roots, source_a)
                self.assertEqual(plan_after.conflicts, [])
                self.assertEqual(plan_after.actions, [])
            finally:
                shutil.rmtree(source_a, ignore_errors=True)


class PackageOverlapTests(unittest.TestCase):
    def test_repeated_install_with_prefix_overlap_leaves_no_debris(self):
        """Default prefix equals the legacy data home: the second install
        must neither delete nor duplicate any packaged theme file."""
        with Fixture() as roots:
            source_a = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source_a)
                manifest_files = set(installer._read_manifest(roots.manifest)["files"])
                installer.install(roots, source_root=source_a)

                missing = [rel for rel in manifest_files if not (roots.pkg_root / rel).exists()]
                self.assertEqual([], missing)
                plan_after = installer.build_plan(roots, source_a)
                self.assertEqual(plan_after.actions, [])
                # No package mirror leaked into the separated user library.
                leaked = [p.name for p in (roots.data / "themes").rglob("*") if p.is_file()]
                self.assertEqual([], [n for n in leaked if n == "v1.json"])
            finally:
                shutil.rmtree(source_a, ignore_errors=True)


class LifecycleOwnershipTests(unittest.TestCase):
    def test_uninstall_preserves_modified_external_paths_and_salvages_package_edits(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                data = source / "applications/.local/share/applications/test.desktop"
                data.parent.mkdir(parents=True)
                data.write_text("original desktop\n")
                installer.install(roots, source_root=source)
                desktop = roots.data.parent / "applications/test.desktop"
                desktop.write_text("personal desktop\n")
                unit = roots.systemd_user / "quickshell.service"
                unit.write_text("personal unit\n")
                binary = roots.bins / "bloxctl"
                binary.unlink()
                binary.write_text("personal program\n")
                package = roots.pkg_root / "shell/shell.qml"
                package.write_text("personal shell\n")
                report = installer.uninstall(roots)
                for path, expected in ((desktop, "personal desktop\n"), (unit, "personal unit\n"), (binary, "personal program\n")):
                    self.assertEqual(path.read_text(), expected)
                    self.assertIn(str(path), report["leftovers"])
                self.assertFalse(roots.pkg_root.exists())
                self.assertIn(str(package), report["salvaged"])
                backups = list(roots.backups.glob("*/pkg-leftovers/shell/shell.qml"))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_text(), "personal shell\n")
            finally:
                shutil.rmtree(source)

    def test_uninstall_preserves_symlink_replacements_without_touching_targets(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source)
                personal = roots.config / "personal.service"
                personal.parent.mkdir(parents=True, exist_ok=True)
                personal.write_text("personal target\n")
                unit = roots.systemd_user / "quickshell.service"
                unit.unlink()
                unit.symlink_to(personal)
                alias = roots.bins / "bloxctl"
                alias.unlink()
                alias.symlink_to(personal)
                report = installer.uninstall(roots)
                self.assertEqual(personal.read_text(), "personal target\n")
                self.assertTrue(unit.is_symlink())
                self.assertTrue(alias.is_symlink())
                self.assertIn(str(unit), report["leftovers"])
                self.assertIn(str(alias), report["leftovers"])
            finally:
                shutil.rmtree(source)

    def test_purge_keeps_modified_package_backup_outside_deleted_state(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source)
                (roots.pkg_root / "shell/shell.qml").write_text("personal change\n")
                report = installer.uninstall(roots, purge=True)
                self.assertFalse(roots.state.exists())
                preserved = list(Path(report["salvage_backup"]).glob("*/pkg-leftovers/shell/shell.qml"))
                self.assertEqual(preserved[0].read_text(), "personal change\n")
            finally:
                shutil.rmtree(source)

    def test_modified_unit_blocks_update_without_force_and_manifest_records_unit_hashes(self):
        with Fixture() as roots:
            sources = [fake_source(v) for v in ("0.1.0", "0.1.1")]
            try:
                installer.install(roots, source_root=sources[0])
                manifest = json.loads(roots.manifest.read_text())
                unit = roots.systemd_user / "quickshell.service"
                self.assertEqual(manifest["unit_files"][unit.name]["sha256"], installer.sha256(unit))
                unit.write_text("personal replacement\n")
                with self.assertRaises(installer.LifecycleError) as error:
                    installer.update(roots, source_root=sources[1])
                self.assertEqual(error.exception.code, "conflict")
                self.assertEqual(unit.read_text(), "personal replacement\n")
            finally:
                for source in sources:
                    shutil.rmtree(source)


class CompleteGenerationRestoreTests(unittest.TestCase):
    def _sources(self):
        sources = [fake_source(v) for v in ("0.1.0", "0.1.1")]
        for index, source in enumerate(sources):
            directory = source / "applications/.local/share/applications"
            directory.mkdir(parents=True)
            (directory / ("old.desktop" if index == 0 else "new.desktop")).write_text(f"generation {index}\n")
            common = directory / "common.desktop"
            common.write_text(f"common {index}\n")
            common.chmod(0o600 if index == 0 else 0o644)
            icons = source / "applications/.local/share/icons/hicolor"
            icons.mkdir(parents=True)
            (icons / ("old.png" if index == 0 else "new.png")).write_bytes(bytes([index, 23]))
        return sources

    def _external_state(self, roots):
        state = {}
        for label, directory in (("data", roots.data.parent), ("unit", roots.systemd_user), ("bin", roots.bins)):
            paths = list(directory.rglob("*")) if label == "data" else list(directory.iterdir())
            for path in paths:
                if label == "data" and path.relative_to(directory).parts[0] not in {"applications", "icons"}:
                    continue
                if path.is_symlink():
                    state[(label, str(path.relative_to(directory)))] = ("link", os.readlink(path))
                elif path.is_file():
                    state[(label, str(path.relative_to(directory)))] = ("file", path.read_bytes(), path.stat().st_mode & 0o777)
        return state

    def test_rollback_restores_all_external_files_modes_and_created_removed_aliases(self):
        with Fixture() as roots:
            sources = self._sources()
            try:
                with mock.patch.object(installer, "INSTALLED_BINS", ("old-alias",)):
                    installer.install(roots, source_root=sources[0])
                before = self._external_state(roots)
                with mock.patch.object(installer, "INSTALLED_BINS", ("new-alias",)):
                    installer.update(roots, source_root=sources[1])
                self.assertFalse((roots.bins / "old-alias").exists())
                self.assertTrue((roots.bins / "new-alias").is_symlink())
                installer.rollback(roots)
                self.assertEqual(self._external_state(roots), before)
                self.assertEqual(json.loads(roots.manifest.read_text())["product_version"], "0.1.0")
            finally:
                for source in sources:
                    shutil.rmtree(source)

    def test_failed_migration_restores_external_preimages_and_previous_generation(self):
        with Fixture() as roots:
            sources = self._sources()
            try:
                installer.install(roots, source_root=sources[0])
                before = self._external_state(roots)
                package_before = snapshot_state(roots)["pkg"]
                with mock.patch.object(migrations, "run_migrations", side_effect=OSError("after external writes")):
                    with self.assertRaises(OSError):
                        installer.update(roots, source_root=sources[1])
                self.assertEqual(self._external_state(roots), before)
                self.assertEqual(snapshot_state(roots)["pkg"], package_before)
                self.assertEqual(list(roots.state.glob(".update-snapshot-*")), [])
            finally:
                for source in sources:
                    shutil.rmtree(source)

    def test_personal_post_update_change_blocks_rollback_before_mutation(self):
        with Fixture() as roots:
            sources = self._sources()
            try:
                installer.install(roots, source_root=sources[0])
                installer.update(roots, source_root=sources[1])
                desktop = roots.data.parent / "applications/common.desktop"
                desktop.write_text("personal after update\n")
                before = snapshot_state(roots)
                with self.assertRaises(installer.LifecycleError) as error:
                    installer.rollback(roots)
                self.assertEqual(error.exception.code, "conflict")
                self.assertEqual(snapshot_state(roots), before)
                self.assertEqual(desktop.read_text(), "personal after update\n")
                self.assertTrue(roots.previous_pkg_root.exists())
            finally:
                for source in sources:
                    shutil.rmtree(source)

    def test_same_second_installs_keep_distinct_backup_bytes(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source)
                with mock.patch.object(installer.time, "strftime", return_value="same-second"):
                    for text in ("second\n", "third\n"):
                        (source / "shell/shell.qml").write_text(text)
                        installer.install(roots, source_root=source)
                backups = sorted(roots.backups.glob("same-second-*/pkg/shell/shell.qml"))
                self.assertEqual(len(backups), 2)
                self.assertEqual({path.read_text() for path in backups}, {"// shell\n", "second\n"})
            finally:
                shutil.rmtree(source)

    def test_failed_previous_generation_promotion_restores_current_and_older_receipts(self):
        with Fixture() as roots:
            sources = self._sources()
            third = fake_source("0.1.2")
            try:
                installer.install(roots, source_root=sources[0])
                installer.update(roots, source_root=sources[1])
                before = self._external_state(roots)
                package_before = snapshot_state(roots)["pkg"]
                previous_before = (roots.previous_pkg_root / "manifest.json").read_bytes()
                receipt_before = (roots.state / "previous-external/manifest.json").read_bytes()
                real_move = shutil.move

                def fail_external_promotion(source, destination, *args, **kwargs):
                    if Path(source).name == "external" and Path(destination) == roots.state / "previous-external":
                        raise OSError("injected generation promotion failure")
                    return real_move(source, destination, *args, **kwargs)

                with mock.patch.object(installer.shutil, "move", side_effect=fail_external_promotion):
                    with self.assertRaises(OSError):
                        installer.update(roots, source_root=third)
                self.assertEqual(self._external_state(roots), before)
                self.assertEqual(snapshot_state(roots)["pkg"], package_before)
                self.assertEqual((roots.previous_pkg_root / "manifest.json").read_bytes(), previous_before)
                self.assertEqual((roots.state / "previous-external/manifest.json").read_bytes(), receipt_before)
                installer.rollback(roots)
                self.assertEqual(json.loads(roots.manifest.read_text())["product_version"], "0.1.0")
            finally:
                for source in sources + [third]:
                    shutil.rmtree(source)

    def test_failed_update_recovery_retains_complete_preimages_for_repair(self):
        with Fixture() as roots:
            sources = self._sources()
            try:
                installer.install(roots, source_root=sources[0])
                with mock.patch.object(migrations, "run_migrations", side_effect=OSError("migration failed")), mock.patch.object(installer, "_restore_external", side_effect=OSError("recovery storage unavailable")):
                    with self.assertRaises(installer.LifecycleError) as error:
                        installer.update(roots, source_root=sources[1])
                self.assertEqual(error.exception.code, "conflict")
                snapshot = Path(error.exception.data["snapshot"])
                self.assertTrue((snapshot / "package/manifest.json").is_file())
                receipt = json.loads((snapshot / "external/manifest.json").read_text())
                image = next(entry for entry in receipt["images"] if entry["relative"] == "applications/common.desktop")
                self.assertEqual((snapshot / "external" / image["backup"]).read_bytes(), b"common 0\n")
            finally:
                for source in sources:
                    shutil.rmtree(source)

    def test_other_process_waits_for_lifecycle_lock_before_installing(self):
        import fcntl
        import subprocess
        import time
        with Fixture() as roots:
            source = fake_source("0.1.0")
            roots.state.mkdir(parents=True)
            started = roots.state / "child-started"
            complete = roots.state / "child-complete"
            child = None
            try:
                lock_path = roots.pkg_root.parent / ".blox-lifecycle.lock"
                lock_path.parent.mkdir(parents=True, exist_ok=True)
                with lock_path.open("w") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    code = "\n".join([
                        "import sys", "from pathlib import Path",
                        "sys.path.insert(0, sys.argv[1])", "import install, layout",
                        "Path(sys.argv[3]).write_text('started')",
                        "install.install(layout.resolve_roots(), source_root=Path(sys.argv[2]))",
                        "Path(sys.argv[4]).write_text('complete')",
                    ])
                    child = subprocess.Popen([sys.executable, "-c", code, str(REPOSITORY / "packaging"), str(source), str(started), str(complete)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    deadline = time.monotonic() + 5
                    while not started.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(started.exists())
                    with self.assertRaises(subprocess.TimeoutExpired):
                        child.wait(timeout=0.1)
                    self.assertFalse(roots.pkg_root.exists())
                    self.assertFalse(complete.exists())
                    fcntl.flock(lock, fcntl.LOCK_UN)
                output, errors = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, errors.decode())
                self.assertTrue(complete.exists())
                self.assertTrue(roots.manifest.is_file())
            finally:
                if child is not None and child.poll() is None:
                    child.kill()
                    child.communicate()
                shutil.rmtree(source)

    def test_purge_and_changed_state_home_keep_the_same_prefix_lock_inode(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                installer.install(roots, source_root=source)
                lock = roots.pkg_root.parent / ".blox-lifecycle.lock"
                before = (lock.stat().st_dev, lock.stat().st_ino)
                installer.uninstall(roots, purge=True)
                self.assertFalse(roots.state.exists())
                self.assertEqual((lock.stat().st_dev, lock.stat().st_ino), before)
                with mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(roots.state.parent / "other-state-home")}):
                    alternative = layout.resolve_roots()
                    installer.install(alternative, source_root=source)
                self.assertEqual((lock.stat().st_dev, lock.stat().st_ino), before)
                self.assertTrue(alternative.manifest.is_file())
                self.assertFalse(roots.state.exists())
            finally:
                shutil.rmtree(source)


class HyprlandModuleBootstrapTests(unittest.TestCase):
    def test_fresh_install_creates_owned_noop_module_without_editing_entrypoint(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                entrypoint = roots.config.parent / "hypr/hyprland.lua"
                entrypoint.parent.mkdir(parents=True)
                entrypoint.write_text("-- personal entrypoint\n")
                module = roots.config / "hyprland-settings.lua"
                dry_run = installer.install(roots, source_root=source, dry_run=True)
                self.assertTrue(any(action["kind"] == "init-config" for action in dry_run["plan"]["actions"]))
                self.assertFalse(module.exists())
                installer.install(roots, source_root=source)
                self.assertEqual(module.read_bytes(), installer.HYPRLAND_DEFAULT_MODULE)
                self.assertEqual(module.stat().st_mode & 0o777, 0o600)
                self.assertEqual(roots.config.stat().st_mode & 0o777, 0o700)
                self.assertEqual(entrypoint.read_text(), "-- personal entrypoint\n")
                manifest = json.loads(roots.manifest.read_text())
                self.assertEqual(manifest["config_defaults"][module.name]["sha256"], installer.sha256(module))
                self.assertEqual(installer.build_plan(roots, source).actions, [])
            finally:
                shutil.rmtree(source)

    def test_existing_personal_module_and_symlink_are_never_replaced(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                roots.config.mkdir(mode=0o700, parents=True)
                module = roots.config / "hyprland-settings.lua"
                module.write_text("personal module\n")
                installer.install(roots, source_root=source)
                self.assertEqual(module.read_text(), "personal module\n")
                self.assertNotIn(module.name, json.loads(roots.manifest.read_text())["config_defaults"])
                installer.uninstall(roots)
                module.unlink()
                target = roots.config.parent / "personal.lua"
                target.write_text("personal target\n")
                module.symlink_to(target)
                installer.install(roots, source_root=source)
                self.assertEqual(os.readlink(module), str(target))
                self.assertEqual(target.read_text(), "personal target\n")
            finally:
                shutil.rmtree(source)

    def test_failed_install_removes_new_module_and_restores_existing_directory_mode(self):
        with Fixture() as roots:
            source = fake_source("0.1.0")
            try:
                roots.config.mkdir(mode=0o705, parents=True)
                (roots.config / "personal.json").write_text("personal config\n")
                real_copy = shutil.copy2

                def fail_package_copy(source, destination, **kwargs):
                    if Path(destination).is_relative_to(roots.pkg_root):
                        raise OSError("injected package failure")
                    return real_copy(source, destination, **kwargs)

                with mock.patch.object(installer.shutil, "copy2", side_effect=fail_package_copy):
                    with self.assertRaises(OSError):
                        installer.install(roots, source_root=source, migrate=False)
                self.assertFalse((roots.config / "hyprland-settings.lua").exists())
                self.assertEqual(roots.config.stat().st_mode & 0o777, 0o705)
                self.assertEqual((roots.config / "personal.json").read_text(), "personal config\n")
            finally:
                shutil.rmtree(source)

    def test_failed_update_restores_module_absence_after_bootstrap(self):
        with Fixture() as roots:
            sources = [fake_source(version) for version in ("0.1.0", "0.1.1")]
            try:
                installer.install(roots, source_root=sources[0])
                module = roots.config / "hyprland-settings.lua"
                module.unlink()
                with mock.patch.object(migrations, "run_migrations", side_effect=OSError("after module bootstrap")):
                    with self.assertRaises(OSError):
                        installer.update(roots, source_root=sources[1])
                self.assertFalse(module.exists())
                self.assertEqual(json.loads(roots.manifest.read_text())["product_version"], "0.1.0")
            finally:
                for source in sources:
                    shutil.rmtree(source)
