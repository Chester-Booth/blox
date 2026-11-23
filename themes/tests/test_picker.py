from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
PICKER_MODULES = REPOSITORY / "shell/modules"
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme import cli
from blox_theme.core import load_theme, resolve_wallpaper_path



class ThemeLibraryMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.library = self.root / "data"
        self.user_library = self.root / "user"
        (self.library / "builtin").mkdir(parents=True)
        (self.user_library / "themes").mkdir(parents=True)
        self.source = load_theme("catppuccin-mocha")[1]
        (self.library / "builtin/catppuccin-mocha.json").write_text(json.dumps(self.source), encoding="utf-8")
        editable = copy.deepcopy(self.source)
        editable.update(id="editable-theme", name="Editable Theme")
        (self.user_library / "themes/editable-theme.json").write_text(json.dumps(editable), encoding="utf-8")

        def resolve(reference: str) -> Path:
            builtin = self.library / "builtin" / f"{reference}.json"
            user = self.user_library / "themes" / f"{reference}.json"
            return builtin if builtin.is_file() else user

        self.patches = [
            mock.patch("blox_theme.cli.themes_dir", return_value=self.library),
            mock.patch("blox_theme.cli.builtin_themes_dir", return_value=self.library / "builtin"),
            mock.patch("blox_theme.cli.user_theme_library", return_value=self.user_library),
            mock.patch("blox_theme.cli.theme_path", side_effect=resolve),
            mock.patch("blox_theme.cli.is_builtin_theme_path", side_effect=lambda path: path.parent == self.library / "builtin"),
        ]
        for patcher in self.patches:
            patcher.start()

    def tearDown(self) -> None:
        for patcher in reversed(self.patches):
            patcher.stop()
        self.temporary.cleanup()

    def invoke(self, *arguments: str) -> tuple[dict, int]:
        return cli.run(cli.parser().parse_args(arguments))

    def test_palette_returns_each_backend_in_both_modes(self) -> None:
        wallpaper = self.root / "wallpaper.png"
        wallpaper.write_bytes(b"image")

        def generated(_wallpaper: Path, backend: str, mode: str):
            return ({"colours": {"background": f"#{backend}-{mode}"}}, [])

        with mock.patch("blox_theme.cli.generate_theme", side_effect=generated):
            response, code = self.invoke("palette", str(wallpaper), "--json")

        self.assertEqual(0, code, response)
        self.assertEqual(
            [("matugen", "dark"), ("matugen", "light"), ("pywal", "dark"), ("pywal", "light")],
            [(entry["backend"], entry["mode"]) for entry in response["data"]],
        )

    def test_duplicate_rename_and_confirmed_delete_preserve_stable_ids(self) -> None:
        duplicate, code = self.invoke("duplicate", "catppuccin-mocha", "phase6-copy", "--name", "Phase Six Copy", "--json")
        self.assertEqual(0, code)
        self.assertEqual("phase6-copy", duplicate["data"]["id"])
        copied = json.loads((self.user_library / "themes/phase6-copy.json").read_text(encoding="utf-8"))
        self.assertEqual("phase6-copy", copied["id"])

        renamed, code = self.invoke("rename", "phase6-copy", "Renamed Display", "--json")
        self.assertEqual(0, code)
        self.assertEqual("phase6-copy", renamed["data"]["id"])
        self.assertEqual("Renamed Display", json.loads((self.user_library / "themes/phase6-copy.json").read_text())["name"])

        refused, code = self.invoke("delete", "phase6-copy", "--json")
        self.assertEqual(2, code)
        self.assertTrue((self.user_library / "themes/phase6-copy.json").exists())
        with mock.patch("blox_theme.cli.current_generation", return_value=None):
            deleted, code = self.invoke("delete", "phase6-copy", "--yes", "--json")
        self.assertEqual(0, code)
        self.assertTrue(deleted["data"]["deleted"])
        self.assertFalse((self.user_library / "themes/phase6-copy.json").exists())
        self.assertFalse(list((self.user_library / "themes").glob(".*.tmp")))

    def test_delete_protects_canonical_active_and_unsafe_references(self) -> None:
        _, code = self.invoke("delete", "catppuccin-mocha", "--yes", "--json")
        self.assertEqual(3, code)
        _, code = self.invoke("delete", "../escape", "--yes", "--json")
        self.assertEqual(2, code)
        self.invoke("duplicate", "catppuccin-mocha", "active-copy", "--json")
        active = (Path("generation"), {"theme_id": "active-copy"})
        with mock.patch("blox_theme.cli.current_generation", return_value=active):
            response, code = self.invoke("delete", "active-copy", "--yes", "--json")
        self.assertEqual(3, code)
        self.assertIn("active", response["errors"][0])

    def test_replace_requires_matching_digest_and_never_changes_id(self) -> None:
        path = self.user_library / "themes/editable-theme.json"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        candidate = copy.deepcopy(self.source)
        candidate["id"] = "editable-theme"
        candidate["name"] = "Updated Display"
        response, code = self.invoke("save", json.dumps(candidate), "--replace", "--expect-sha256", digest, "--json")
        self.assertEqual(0, code)
        self.assertEqual("editable-theme", json.loads(path.read_text())["id"])
        self.assertEqual("Updated Display", json.loads(path.read_text())["name"])

        stale = copy.deepcopy(candidate)
        stale["name"] = "Should Not Win"
        response, code = self.invoke("save", json.dumps(stale), "--replace", "--expect-sha256", digest, "--json")
        self.assertEqual(6, code)
        self.assertIn("changed since", response["errors"][0])
        self.assertEqual("Updated Display", json.loads(path.read_text())["name"])

    def test_duplicate_refuses_invalid_or_existing_id(self) -> None:
        response, code = self.invoke("duplicate", "catppuccin-mocha", "Invalid ID", "--json")
        self.assertEqual(3, code)
        self.assertTrue(response["errors"])
        response, code = self.invoke("duplicate", "catppuccin-mocha", "catppuccin-mocha", "--json")
        self.assertEqual(3, code)
        self.assertIn("already exists", response["errors"][0])

    def test_sparse_source_round_trip_keeps_inherited_fields_out_of_the_file(self) -> None:
        raw = copy.deepcopy(self.source)
        raw.update(id="legacy-theme", name="Legacy Theme")
        raw["targets"].pop("helium")
        raw.pop("overrides")
        path = self.user_library / "themes/legacy-theme.json"
        path.write_text(json.dumps(raw), encoding="utf-8")

        with mock.patch("blox_theme.core.theme_path", return_value=path):
            shown, code = self.invoke("show", "legacy-theme", "--json")
        self.assertEqual(0, code, shown)
        self.assertFalse(shown["data"]["targets"]["helium"])
        self.assertNotIn("helium", shown["source"]["targets"])

        untouched_candidate = copy.deepcopy(shown["data"])
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        saved, code = self.invoke(
            "save",
            json.dumps(untouched_candidate),
            "--source",
            json.dumps(shown["source"]),
            "--touched",
            json.dumps(["targets.helium"]),
            "--replace",
            "--expect-sha256",
            digest,
            "--json",
        )
        self.assertEqual(0, code, saved)
        written = json.loads(path.read_text(encoding="utf-8"))
        self.assertIn("helium", written["targets"])
        self.assertFalse(written["targets"]["helium"])

        with mock.patch("blox_theme.core.theme_path", return_value=path):
            shown, code = self.invoke("show", "legacy-theme", "--json")
        self.assertEqual(0, code, shown)

        candidate = copy.deepcopy(shown["data"])
        candidate["targets"]["helium"] = True
        candidate["shape"]["density_scale"] = 1.1
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        saved, code = self.invoke(
            "save",
            json.dumps(candidate),
            "--source",
            json.dumps(shown["source"]),
            "--replace",
            "--expect-sha256",
            digest,
            "--json",
        )
        self.assertEqual(0, code, saved)
        written = json.loads(path.read_text(encoding="utf-8"))
        self.assertTrue(written["targets"]["helium"])
        self.assertEqual(1.1, written["shape"]["density_scale"])
        self.assertNotIn("overrides", written)

    def test_inline_preview_is_side_effect_free(self) -> None:
        candidate = copy.deepcopy(self.source)
        candidate["targets"] = {target: target == "quickshell" for target in candidate["targets"]}
        def snapshot():
            return {str(path.relative_to(self.root)): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        before = snapshot()
        with mock.patch("shell.scripts.bloxctl.run_theme") as apply_owner:
            response, code = self.invoke("preview", json.dumps(candidate), "--json")
        self.assertEqual(0, code, response)
        self.assertTrue(response["ok"])
        apply_owner.assert_not_called()
        self.assertEqual(before, snapshot())

    def test_saved_apply_delegates_to_the_public_settings_owner(self) -> None:
        result = {"version": 1, "ok": True, "code": "ok", "message": "", "data": {
            "generation_id": "test-generation", "theme_id": "editable-theme", "enabled_targets": []}}
        with mock.patch("shell.scripts.bloxctl.run_theme", return_value=(0, result)) as apply_owner:
            response, code = self.invoke("apply", "editable-theme", "--json")
        self.assertEqual(0, code, response)
        self.assertTrue(response["ok"])
        self.assertEqual(result["data"], response["data"])
        arguments = apply_owner.call_args.args[0]
        self.assertEqual("apply", arguments.theme_command)
        self.assertEqual("editable-theme", arguments.theme)

    def test_saved_apply_preserves_owner_rejection(self) -> None:
        result = {"version": 1, "ok": False, "code": "conflict", "message": "Resolve the retained Apply first", "data": None}
        with mock.patch("shell.scripts.bloxctl.run_theme", return_value=(4, result)):
            response, code = self.invoke("apply", "editable-theme", "--json")
        self.assertEqual(4, code)
        self.assertFalse(response["ok"])
        self.assertEqual([result["message"]], response["errors"])

    def test_mutations_reject_a_non_object_source(self) -> None:
        path = self.user_library / "themes/broken.json"
        path.write_text("[]", encoding="utf-8")
        response, code = self.invoke("rename", "broken", "Still Broken", "--json")
        self.assertEqual(3, code)
        self.assertIn("JSON object", response["errors"][0])
        self.assertEqual([], json.loads(path.read_text(encoding="utf-8")))

    def test_generated_target_files_can_be_exported_without_path_escape(self) -> None:
        state = self.root / "state"
        generated = state / "current/code/themes/blox-generated-color-theme.json"
        generated.parent.mkdir(parents=True)
        generated.write_text('{"name":"Blox"}', encoding="utf-8")
        output = self.root / "downloads/blox-generated-color-theme.json"
        with mock.patch("blox_theme.cli.state_dir", return_value=state):
            response, code = self.invoke("export-target", "code", "--file", "code/themes/blox-generated-color-theme.json", "--output", str(output), "--json")
            self.assertEqual(0, code, response)
            self.assertEqual('{"name":"Blox"}', output.read_text(encoding="utf-8"))

            response, code = self.invoke("export-target", "code", "--file", "../outside", "--output", str(self.root / "outside"), "--json")
            self.assertEqual(3, code)
            self.assertIn("not a generated file", response["errors"][0])

    def test_generated_target_files_can_be_exported_as_one_zip(self) -> None:
        state = self.root / "state"
        expected = {
            "code/settings.json": "settings",
            "code/package.json": "package",
            "code/themes/blox-generated-color-theme.json": "theme",
        }
        for name, content in expected.items():
            generated = state / "current" / name
            generated.parent.mkdir(parents=True, exist_ok=True)
            generated.write_text(content, encoding="utf-8")
        output = self.root / "downloads/code-generated-files.zip"
        with mock.patch("blox_theme.cli.state_dir", return_value=state):
            response, code = self.invoke("export-target", "code", "--archive", "--output", str(output), "--json")
        self.assertEqual(0, code, response)
        self.assertTrue(response["data"]["archive"])
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(set(expected), set(archive.namelist()))
            for name, content in expected.items():
                self.assertEqual(content, archive.read(name).decode("utf-8"))


class SettingsIntegrationSourceTests(unittest.TestCase):


    def test_inline_builtin_preview_keeps_its_application_data_base(self) -> None:
        source, candidate = load_theme("catppuccin-mocha")
        candidate = copy.deepcopy(candidate)

        path, _, failure, code = cli.checked_theme(
            "preview", json.dumps(candidate), check_dependencies=False
        )

        self.assertEqual(0, code, failure)
        self.assertEqual(source, path)
        self.assertEqual(
            THEMES / "wallpapers/showcase/catppuccin-mocha.webp",
            resolve_wallpaper_path(candidate["wallpaper"]["path"], path),
        )


    def test_quickshell_modules_are_registered_for_live_reload(self) -> None:
        modules = REPOSITORY / "shell/modules"
        registered = set()
        for line in (modules / "qmldir").read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            fields = line.split()
            registered.add(fields[1] if fields[0] == "singleton" else fields[0])
        available = {path.stem for path in modules.glob("*.qml")}

        self.assertEqual(available, registered)

    def test_theme_cursor_reload_recreates_blox_windows(self) -> None:
        theme = (REPOSITORY / "shell/shared/Theme.qml").read_text(encoding="utf-8")
        self.assertIn("function reloadCursor() : string", theme)
        self.assertIn('Quickshell.execDetached(["systemctl", "--user", "restart", "quickshell.service"]);', theme)
        self.assertIn("Quickshell.reload(true);", theme)
        self.assertIn('function reloadCursor() : string {\n            return root.reloadCursor();', theme)

    def test_apply_defers_quickshell_reload_until_completion(self) -> None:
        page = (PICKER_MODULES / "SettingsApplyReviewPage.qml").read_text(encoding="utf-8")
        owner = (REPOSITORY / "shell/services/SettingsApplyController.qml").read_text(encoding="utf-8")
        launcher = (PICKER_MODULES / "LauncherThemeApplyWindow.qml").read_text(encoding="utf-8")

        self.assertIn("SettingsApplyReviewPage", launcher)
        self.assertIn('text: root.pendingReload ? "Restart Quickshell" : "Done"', page)
        self.assertIn("root.flowState.completeQuickshellReload();", page)
        self.assertIn("root.flowState.finishApply();", page)
        self.assertIn('function completeQuickshellReload() { reloadAfterFinish = true; }', owner)
        finish = owner.split("function finishApply()", 1)[1].split("function closeFinishedApply()", 1)[0]
        self.assertIn('if (actions.keepSuccessfulChanges || actions.retryFailedTargets.length || actions.abandonSuperseded === true) return;', finish)
        self.assertIn('if (journalReleased) { closeFinishedApply(); return; }', finish)
        self.assertIn('request("finish");', finish)
        response = owner.split('if (operation === "finish" || operation === "abandon")', 1)[1].split('if (operation === "recover"', 1)[0]
        self.assertLess(response.index("if (!response.ok)"), response.index("journalReleased = true;"))
        self.assertLess(response.index("journalReleased = true;"), response.index("closeFinishedApply();"))
        self.assertIn('/scripts/restart_settings_shell.py', owner)
























    def test_cli_normalises_typographic_option_dashes(self) -> None:
        self.assertEqual(["setup", "cursor", "--yes"], cli.normalise_option_dashes(["setup", "cursor", "—-yes"]))
        self.assertEqual(["setup", "cursor", "--yes"], cli.normalise_option_dashes(["setup", "cursor", "——yes"]))
        with mock.patch.object(cli, "run", return_value=(cli.envelope("setup"), 0)) as run, mock.patch.object(cli, "emit"):
            self.assertEqual(0, cli.main(["setup", "cursor", "—-yes", "--json"]))
        parsed = run.call_args.args[0]
        self.assertEqual("cursor", parsed.feature)
        self.assertTrue(parsed.yes)

    def test_settings_desktop_entries_are_discoverable(self) -> None:
        applications = REPOSITORY / "applications/.local/share/applications"
        icons = REPOSITORY / "applications/.local/share/icons/hicolor/scalable/apps"
        launchers = sorted(path for path in applications.glob("blox-*.desktop") if path.name != "blox-restart-shell.desktop")
        self.assertEqual(["blox-settings.desktop", "blox-theme-from-wallpaper.desktop"], [path.name for path in launchers])
        expected_icons = {
            "blox-theme-from-wallpaper.desktop": "blox-theme-from-wallpaper",
            "blox-settings.desktop": "blox-settings",
        }
        for launcher in launchers:
            text = launcher.read_text(encoding="utf-8")
            self.assertIn("Type=Application", text)
            endpoint = "settingsUi open" if launcher.name == "blox-settings.desktop" else "settingsUi createFromWallpaper"
            self.assertIn(f"Exec=blox-settings-ipc {endpoint}", text)
            icon = expected_icons[launcher.name]
            self.assertIn(f"Icon={icon}", text)
            self.assertTrue((icons / f"{icon}.svg").is_file())

        ipc_helper = (REPOSITORY / "shell/scripts/ipc.sh").read_text(encoding="utf-8")
        self.assertIn('exec quickshell ipc --pid "$main_pid" call "$@"', ipc_helper)
        self.assertNotIn("quickshell ipc -c", ipc_helper)

    def test_launcher_theme_preview_pluralises_widget_count(self) -> None:
        launcher = (PICKER_MODULES / "LauncherMainSurface.qml").read_text(encoding="utf-8")
        self.assertIn('widgetCount === 1 ? " widget" : " widgets"', launcher)


if __name__ == "__main__":
    unittest.main()
