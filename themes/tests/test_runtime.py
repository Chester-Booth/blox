from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import editor_colours, load_theme, render_theme, repository_root, resolve_wallpaper_path
from blox_theme.editor import read_settings_values, restore_settings
from blox_theme.obsidian import ObsidianVault, publish as publish_obsidian_theme, safe_paths, _select_theme
from blox_theme.runtime import ApplicationLock, EDITOR_EXTENSION_DIR, EDITOR_LEGACY_EXTENSION_DIR, LockContended, RuntimeFailure, TARGET_FILES, TARGET_NAMES, T3CODE_THEME_ID, apply_theme, current_generation, cursor_icon_link, editor_settings_integration_path, hyprtoolkit_theme_link, kitty_theme_link, phase7_loader_specs, reconcile, reset_target, rollback, setup_gtk, t3code_integration_path, t3code_paths, validate_generation, zed_integration_path, zed_paths

PHASE2_TARGETS = ("quickshell", "kitty", "wallpaper")


class FakeCommands:
    def __init__(self, returncode: int = 0, fail_obsidian: bool = False) -> None:
        self.returncode = returncode
        self.fail_obsidian = fail_obsidian
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(command)
        command_returncode = self.returncode if self.fail_obsidian or not command or command[0] != "obsidian" else 0
        if command_returncode == 0 and command and command[0] == "obsidian" and "theme:set" in command:
            vault_id = next(part[6:] for part in command if part.startswith("vault="))
            theme_name = next(part[5:] for part in command if part.startswith("name="))
            config_home = Path(os.environ["XDG_CONFIG_HOME"])
            registry = json.loads((config_home / "obsidian/obsidian.json").read_text(encoding="utf-8"))
            vault = registry["vaults"][vault_id]
            appearance = Path(vault["path"]) / ".obsidian/appearance.json"
            current = json.loads(appearance.read_text(encoding="utf-8")) if appearance.exists() else {}
            current["cssTheme"] = theme_name
            appearance.write_text(json.dumps(current) + "\n", encoding="utf-8")
        return subprocess.CompletedProcess(command, command_returncode, "", "failed" if command_returncode else "")


def fake_cursor_builder(metadata: dict, root: Path) -> tuple[Path, bool]:
    theme = root / f"cursors/{metadata['cache_key']}/theme"
    (theme / "cursors").mkdir(parents=True, exist_ok=True)
    (theme / "index.theme").write_text("[Icon Theme]\nName=blox-generated\n", encoding="utf-8")
    (theme / "cursors/left_ptr").write_bytes(b"Xcur-test")
    return theme, False


class RuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = mock.patch.dict(os.environ, {
            "BLOX_SHELL_DIR": str(self.root / "config" / "quickshell" / "blox"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "VSCODE_EXTENSIONS": str(self.root / "vscode-extensions"),
            "CURSOR_EXTENSIONS": str(self.root / "cursor-extensions"),
            "T3CODE_HOME": str(self.root / "t3code"),
        })
        self.environment.start()
        self.browser_probe = mock.patch(
            "blox_theme.runtime.detect_browser_target",
            return_value={"available": True, "label": "Helium", "reason": ""},
        )
        self.browser_probe.start()
        quickshell_loader = self.root / "config/quickshell/blox/shared/Theme.qml"
        quickshell_loader.parent.mkdir(parents=True)
        quickshell_loader.write_text("watchChanges: true\nfunction loadJson() {}\n", encoding="utf-8")
        kitty_config = self.root / "config/kitty/kitty.conf"
        kitty_config.parent.mkdir(parents=True)
        kitty_config.write_text("globinclude blox-theme.conf\n", encoding="utf-8")
        self.obsidian_vault = self.root / "obsidian-vault"
        (self.obsidian_vault / ".obsidian").mkdir(parents=True)
        (self.obsidian_vault / ".obsidian/appearance.json").write_text(
            '{"cssTheme": "Minimal", "otherSetting": true}\n', encoding="utf-8"
        )
        obsidian_config = self.root / "config/obsidian/obsidian.json"
        obsidian_config.parent.mkdir(parents=True)
        obsidian_config.write_text(json.dumps({
            "vaults": {
                "test-vault": {"path": str(self.obsidian_vault), "open": True},
            },
            "cli": True,
        }) + "\n", encoding="utf-8")
        self.canonical_path, self.canonical = load_theme("catppuccin-mocha")
        for target in TARGET_NAMES:
            self.canonical["targets"][target] = True
        self.alternate_path = THEMES / "tests/fixtures/phase2-alternate.json"
        self.alternate = json.loads(self.alternate_path.read_text(encoding="utf-8"))

    def tearDown(self) -> None:
        self.browser_probe.stop()
        self.environment.stop()
        self.temporary.cleanup()

    @property
    def state(self) -> Path:
        return Path(os.environ["XDG_STATE_HOME"]) / "blox/theme"

    def apply_canonical(self, runner: FakeCommands | None = None) -> tuple[dict, list[str]]:
        return apply_theme(self.canonical_path, self.canonical, TARGET_NAMES, run_command=runner or FakeCommands(), cursor_builder=fake_cursor_builder)

    def test_initial_apply_creates_valid_atomic_layout_and_loaders(self) -> None:
        runner = FakeCommands()
        with mock.patch("blox_theme.runtime._kitty_sockets", return_value=[Path("/tmp/kitty-test")]):
            manifest, warnings = self.apply_canonical(runner)
        self.assertTrue(any("Stylus" in warning for warning in warnings))
        self.assertTrue(any("Obsidian native theme selected" in warning for warning in warnings))
        self.assertTrue((self.state / "current").is_symlink())
        self.assertEqual("current/manifest.json", os.readlink(self.state / "active.json"))
        generation, checked = current_generation(self.state)
        self.assertEqual(manifest, checked)
        self.assertEqual(set(TARGET_NAMES), set(manifest["enabled_targets"]))
        self.assertTrue((self.root / "config/kitty/blox-theme.conf").is_symlink())
        self.assertTrue(cursor_icon_link().is_symlink())
        for target, (link, expected) in phase7_loader_specs(self.state).items():
            self.assertTrue(link.is_symlink(), target)
            self.assertEqual(str(expected), os.readlink(link))
        self.assertTrue(hyprtoolkit_theme_link().is_symlink())
        self.assertEqual(
            str(self.state / "current/hyprland/hyprtoolkit.conf"),
            os.readlink(hyprtoolkit_theme_link()),
        )
        self.assertEqual(self.state / f"cursors/{json.loads((generation / 'cursor/metadata.json').read_text())['cache_key']}/theme", Path(os.readlink(cursor_icon_link())))
        for version in ("3", "4"):
            config = self.root / f"config/gtk-{version}.0"
            self.assertEqual(self.state / f"current/gtk/gtk-{version}.0/settings.ini", Path(os.readlink(config / "settings.ini")))
            self.assertEqual(self.state / f"current/gtk/gtk-{version}.0/gtk.css", Path(os.readlink(config / "blox-theme.css")))
        self.assertEqual([], list((self.state / "generations").glob(".candidate-*")))
        self.assertEqual(generation, (self.state / "current").resolve())
        flattened = [part for command in runner.commands for part in command]
        for executable in ("hyprctl", "kitty"):
            self.assertIn(executable, flattened)
        self.assertTrue(any("shell/scripts/ipc.sh" in part for part in flattened))

    def test_generation_records_reset_origin_and_target_reset_preserves_it(self) -> None:
        manifest, _ = self.apply_canonical()
        self.assertEqual(
            {"kind": "builtin", "theme_id": "catppuccin-mocha", "fallback": False},
            manifest["origin"],
        )
        reset, _ = reset_target("kitty", run_command=FakeCommands())
        self.assertEqual(manifest["origin"], reset["origin"])

    def test_obsidian_publishes_native_package_and_selects_the_open_vault(self) -> None:
        runner = FakeCommands()
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        manifest, warnings = apply_theme(
            self.canonical_path,
            self.canonical,
            ("obsidian",),
            run_command=runner,
        )
        package = self.obsidian_vault / ".obsidian/themes/Blox generated"
        self.assertEqual("Blox generated", json.loads((package / "manifest.json").read_text())["name"])
        self.assertEqual(package.name, json.loads((package / "manifest.json").read_text())["name"])
        self.assertIn("--background-primary: #1e1e2e;", (package / "theme.css").read_text())
        self.assertIn("--radius-m: 15px;", (package / "theme.css").read_text())
        appearance = json.loads((self.obsidian_vault / ".obsidian/appearance.json").read_text())
        self.assertEqual("Blox generated", appearance["cssTheme"])
        self.assertIn(["obsidian", "vault=test-vault", "theme:set", "name=Blox generated"], runner.commands)
        self.assertEqual(["obsidian"], manifest["enabled_targets"])
        self.assertEqual([], [warning for warning in warnings if "not changed" in warning])

    def test_obsidian_closed_apply_writes_native_selection_without_starting_obsidian(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        runner.commands.clear()
        with mock.patch("blox_theme.obsidian._obsidian_is_running", return_value=False):
            publish_obsidian_theme(self.state, runner, real_cli=True)
        appearance = json.loads((self.obsidian_vault / ".obsidian/appearance.json").read_text())
        self.assertEqual("Blox generated", appearance["cssTheme"])
        self.assertEqual([], runner.commands)

    def test_obsidian_live_apply_refreshes_when_the_generated_name_is_already_selected(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        paths = safe_paths(ObsidianVault("test-vault", self.obsidian_vault))
        with mock.patch("blox_theme.obsidian._obsidian_is_running", return_value=True), mock.patch(
            "blox_theme.obsidian._run_live_theme_set"
        ) as live_set:
            _select_theme(paths, "Blox generated", runner, real_cli=True)
        self.assertEqual([mock.call(paths, ""), mock.call(paths, "Blox generated")], live_set.call_args_list)

    def test_obsidian_recovers_an_interrupted_publish_before_reapplying(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        integration_path = self.state / "integration/obsidian.json"
        integration = json.loads(integration_path.read_text())
        integration["last_manifest_sha256"] = "0" * 64
        integration["last_stylesheet_sha256"] = "0" * 64
        integration_path.write_text(json.dumps(integration) + "\n", encoding="utf-8")
        (self.obsidian_vault / ".obsidian/appearance.json").write_text(
            '{"cssTheme": "Minimal", "otherSetting": true}\n', encoding="utf-8"
        )
        manifest, _ = apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        self.assertEqual(["obsidian"], manifest["enabled_targets"])
        self.assertEqual("Blox generated", json.loads((self.obsidian_vault / ".obsidian/appearance.json").read_text())["cssTheme"])
        repaired = json.loads(integration_path.read_text())
        self.assertNotEqual("0" * 64, repaired["last_manifest_sha256"])
        self.assertNotEqual("0" * 64, repaired["last_stylesheet_sha256"])

    def test_obsidian_reset_restores_previous_theme_and_removes_owned_package(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        manifest, warnings = reset_target("obsidian", run_command=runner)
        appearance = json.loads((self.obsidian_vault / ".obsidian/appearance.json").read_text())
        self.assertEqual("Minimal", appearance["cssTheme"])
        self.assertFalse((self.obsidian_vault / ".obsidian/themes/Blox generated").exists())
        self.assertNotIn("obsidian", manifest["enabled_targets"])
        self.assertEqual([], warnings)

    def test_obsidian_second_apply_replaces_only_the_owned_package(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        changed = copy.deepcopy(self.canonical)
        changed["colours"]["accent"] = "#a6e3a1"
        apply_theme(self.canonical_path, changed, ("obsidian",), run_command=runner)
        package_css = (self.obsidian_vault / ".obsidian/themes/Blox generated/theme.css").read_text()
        self.assertIn("--text-accent: #a6e3a1;", package_css)
        self.assertEqual("Blox generated", json.loads((self.obsidian_vault / ".obsidian/appearance.json").read_text())["cssTheme"])
        self.assertEqual(2, sum(command[0] == "obsidian" for command in runner.commands))

    def test_obsidian_apply_adopts_a_theme_selected_outside_blox_for_reset(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        appearance_path = self.obsidian_vault / ".obsidian/appearance.json"
        appearance = json.loads(appearance_path.read_text())
        appearance["cssTheme"] = "Minimal"
        appearance_path.write_text(json.dumps(appearance) + "\n", encoding="utf-8")
        changed = copy.deepcopy(self.canonical)
        changed["colours"]["accent"] = "#a6e3a1"
        apply_theme(self.canonical_path, changed, ("obsidian",), run_command=runner)
        integration = json.loads((self.state / "integration/obsidian.json").read_text())
        self.assertEqual({"present": True, "value": "Minimal"}, integration["previous_css_theme"])
        reset_target("obsidian", run_command=runner)
        self.assertEqual("Minimal", json.loads(appearance_path.read_text())["cssTheme"])

    def test_obsidian_migrates_the_old_slugged_package_directory(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        runner = FakeCommands()
        apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=runner)
        new_package = self.obsidian_vault / ".obsidian/themes/Blox generated"
        old_package = self.obsidian_vault / ".obsidian/themes/blox-generated"
        os.replace(new_package, old_package)
        integration_path = self.state / "integration/obsidian.json"
        integration = json.loads(integration_path.read_text())
        integration["package_path"] = str(old_package)
        integration_path.write_text(json.dumps(integration) + "\n", encoding="utf-8")
        changed = copy.deepcopy(self.canonical)
        changed["colours"]["accent"] = "#a6e3a1"
        apply_theme(self.canonical_path, changed, ("obsidian",), run_command=runner)
        manifest_path = new_package / "manifest.json"
        self.assertTrue(manifest_path.is_file())
        self.assertFalse(old_package.exists())
        self.assertEqual(new_package.name, json.loads(manifest_path.read_text())["name"])

    def test_obsidian_refuses_multiple_open_vaults_before_generation_mutation(self) -> None:
        registry_path = self.root / "config/obsidian/obsidian.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        second = self.root / "second-vault"
        (second / ".obsidian").mkdir(parents=True)
        (second / ".obsidian/appearance.json").write_text('{"cssTheme":"Minimal"}\n', encoding="utf-8")
        registry["vaults"]["second-vault"] = {"path": str(second), "open": True}
        registry_path.write_text(json.dumps(registry) + "\n", encoding="utf-8")
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        with self.assertRaisesRegex(RuntimeFailure, "multiple Obsidian vaults"):
            apply_theme(self.canonical_path, self.canonical, ("obsidian",), run_command=FakeCommands())
        self.assertFalse((self.state / "current").exists())

    def test_obsidian_cli_failure_restores_vault_and_does_not_leave_generation_active(self) -> None:
        self.canonical["targets"] = {key: key == "obsidian" for key in self.canonical["targets"]}
        with self.assertRaisesRegex(RuntimeFailure, "Obsidian theme was not changed"):
            apply_theme(
                self.canonical_path,
                self.canonical,
                ("obsidian",),
                run_command=FakeCommands(returncode=1, fail_obsidian=True),
            )
        appearance = json.loads((self.obsidian_vault / ".obsidian/appearance.json").read_text())
        self.assertEqual("Minimal", appearance["cssTheme"])
        self.assertFalse((self.obsidian_vault / ".obsidian/themes/Blox generated").exists())
        self.assertFalse((self.state / "current").exists())
        self.assertFalse((self.state / "integration/obsidian.json").exists())

    def test_helium_cache_does_not_break_generation_integrity(self) -> None:
        self.apply_canonical()
        cache = (self.state / "current/helium/Cached Theme.pak").resolve()
        cache.write_bytes(b"browser cache")
        generation, manifest = current_generation(self.state)
        self.assertIsNotNone(generation)
        self.assertIn("helium", manifest["enabled_targets"])

    def test_glow_style_uses_the_xdg_managed_loader(self) -> None:
        glow_link, _ = phase7_loader_specs(self.state)["glow"]
        self.assertEqual(self.root / "config/glow/blox-theme.json", glow_link)
        glow_config = (REPOSITORY / "glow/.config/glow/glow.yml").read_text(encoding="utf-8")
        # The GLOW_STYLE export lives in the user's environment; the product
        # contract is the XDG-aware managed path and a neutral shipped config.
        self.assertIn('style: "auto"', glow_config)
        self.assertNotIn("/home/", glow_config)

    def test_hyprtoolkit_loader_does_not_replace_an_existing_config(self) -> None:
        config = hyprtoolkit_theme_link()
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text("accent = 0xFFFFFFFF\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeFailure, "conflicting Hyprtoolkit"):
            apply_theme(
                self.canonical_path,
                self.canonical,
                ("hyprland",),
                run_command=FakeCommands(),
            )
        self.assertEqual("accent = 0xFFFFFFFF\n", config.read_text(encoding="utf-8"))
        self.assertFalse((self.state / "current").exists())

    def test_installed_cursor_bypasses_builder_and_removes_generated_link(self) -> None:
        self.apply_canonical()
        installed = copy.deepcopy(self.canonical)
        installed["cursor"].update(mode="installed", base="Bibata-Modern-Ice", sizes=[24])

        def forbidden_builder(metadata: dict, root: Path) -> tuple[Path, bool]:
            raise AssertionError("installed cursor must bypass generation")

        runner = FakeCommands()
        manifest, warnings = apply_theme(self.canonical_path, installed, ("cursor",), run_command=runner, cursor_builder=forbidden_builder)
        self.assertEqual([], warnings)
        self.assertFalse(cursor_icon_link().exists())
        metadata = json.loads((self.state / "current/cursor/metadata.json").read_text(encoding="utf-8"))
        self.assertEqual("installed", metadata["mode"])
        self.assertIn(["hyprctl", "setcursor", "Bibata-Modern-Ice", "24"], runner.commands)
        self.assertIn("cursor", manifest["enabled_targets"])

    def test_cursor_reset_restores_captured_selection(self) -> None:
        self.apply_canonical()
        runner = FakeCommands()
        manifest, warnings = reset_target("cursor", run_command=runner)
        self.assertEqual([], warnings)
        self.assertNotIn("cursor", manifest["enabled_targets"])
        self.assertFalse(cursor_icon_link().exists())
        fallback = json.loads((self.state / "integration/cursor.json").read_text(encoding="utf-8"))["fallback"]
        self.assertIn(["hyprctl", "setcursor", fallback["theme_name"], str(fallback["size"])], runner.commands)

    def test_cursor_link_conflict_rolls_back_activation(self) -> None:
        link = cursor_icon_link()
        link.parent.mkdir(parents=True)
        link.mkdir()
        with self.assertRaisesRegex(RuntimeFailure, "conflicting cursor"):
            self.apply_canonical()
        self.assertFalse((self.state / "current").exists())
        self.assertTrue(link.is_dir())

    def test_cursor_rollback_restores_previous_cache_link(self) -> None:
        first, _ = self.apply_canonical()
        first_target = os.readlink(cursor_icon_link())
        changed = copy.deepcopy(self.canonical)
        changed["cursor"].update(base_colour="#a6e3a1", outline_colour="#1e1e1e")
        apply_theme(self.canonical_path, changed, ("cursor",), run_command=FakeCommands(), cursor_builder=fake_cursor_builder)
        self.assertNotEqual(first_target, os.readlink(cursor_icon_link()))
        rollback(first["generation_id"], run_command=FakeCommands())
        self.assertEqual(first_target, os.readlink(cursor_icon_link()))

    def test_cursor_apply_reports_live_switch_without_restart_warning(self) -> None:
        runner = FakeCommands()
        _, warnings = apply_theme(
            self.canonical_path,
            self.canonical,
            ("cursor",),
            run_command=runner,
            cursor_builder=fake_cursor_builder,
        )
        self.assertEqual([], warnings)
        self.assertIn(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", "blox-generated"], runner.commands)
        self.assertIn(["gsettings", "set", "org.gnome.desktop.interface", "cursor-size", "22"], runner.commands)
        fallback_metadata = json.loads((self.state / "integration/cursor.json").read_text(encoding="utf-8"))["fallback"]
        fallback = ["hyprctl", "setcursor", fallback_metadata["theme_name"], str(fallback_metadata["size"])]
        generated = ["hyprctl", "setcursor", "blox-generated", "22"]
        self.assertIn(generated, runner.commands)
        if fallback != generated:
            self.assertIn(fallback, runner.commands)
            self.assertLess(runner.commands.index(fallback), runner.commands.index(generated))
        self.assertIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reloadCursor"],
            runner.commands,
        )

    def test_apply_skips_unchanged_targets(self) -> None:
        self.apply_canonical()
        runner = FakeCommands()
        events: list[dict] = []
        _, warnings = apply_theme(
            self.canonical_path,
            self.canonical,
            TARGET_NAMES,
            run_command=runner,
            cursor_builder=fake_cursor_builder,
            progress=events.append,
        )
        self.assertEqual([], warnings)
        target_events = [event for event in events if event["kind"] == "target"]
        self.assertEqual(list(TARGET_NAMES), [event["target"] for event in target_events])
        self.assertEqual(["unchanged"] * len(TARGET_NAMES), [event["state"] for event in target_events])
        self.assertNotIn(["hyprctl", "reload"], runner.commands)
        self.assertNotIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reloadCursor"],
            runner.commands,
        )

    def test_cursor_apply_can_defer_the_quickshell_restart(self) -> None:
        self.apply_canonical()
        changed = copy.deepcopy(self.canonical)
        changed["cursor"].update(base_colour="#a6e3a1", outline_colour="#1e1e1e")
        runner = FakeCommands()
        events: list[dict] = []
        _, warnings = apply_theme(
            self.canonical_path,
            changed,
            ("cursor",),
            run_command=runner,
            cursor_builder=fake_cursor_builder,
            progress=events.append,
            defer_quickshell_restart=True,
        )
        self.assertEqual([], warnings)
        self.assertIn(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", "blox-generated"], runner.commands)
        self.assertIn(["hyprctl", "setcursor", "blox-generated", "22"], runner.commands)
        self.assertNotIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reloadCursor"],
            runner.commands,
        )
        cursor_events = [event for event in events if event["kind"] == "target" and event["target"] == "cursor"]
        self.assertEqual(["active", "restart"], [event["state"] for event in cursor_events])
        self.assertEqual("Complete to reload Blox surfaces", cursor_events[-1]["message"])

    def test_icon_theme_apply_can_defer_the_quickshell_restart(self) -> None:
        self.apply_canonical()
        changed = copy.deepcopy(self.canonical)
        changed["icons"]["theme"] = "Breeze"
        runner = FakeCommands()
        events: list[dict] = []
        manifest, warnings = apply_theme(
            self.canonical_path,
            changed,
            ("quickshell",),
            run_command=runner,
            progress=events.append,
            defer_quickshell_restart=True,
        )
        self.assertEqual([], warnings)
        application_event = next(event for event in events if event["kind"] == "stage" and event["stage"] == "applications")
        self.assertEqual(["quickshell"], application_event["pending_reloads"])
        self.assertIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reload"],
            runner.commands,
        )
        self.assertNotIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reloadCursor"],
            runner.commands,
        )
        quickshell_events = [event for event in events if event["kind"] == "target" and event["target"] == "quickshell"]
        self.assertEqual(["active", "restart"], [event["state"] for event in quickshell_events])
        self.assertEqual("Complete to reload Blox surfaces", quickshell_events[-1]["message"])

    def test_icon_theme_apply_recreates_quickshell_without_defer(self) -> None:
        self.apply_canonical()
        changed = copy.deepcopy(self.canonical)
        changed["icons"]["theme"] = "Breeze"
        runner = FakeCommands()
        _, warnings = apply_theme(
            self.canonical_path,
            changed,
            ("quickshell",),
            run_command=runner,
        )
        self.assertEqual([], warnings)
        self.assertIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reloadCursor"],
            runner.commands,
        )
        self.assertNotIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reload"],
            runner.commands,
        )

    def test_cursor_apply_reports_when_blox_shell_cannot_reload(self) -> None:
        runner = FakeCommands()
        runner.returncode = 1
        _, warnings = apply_theme(
            self.canonical_path,
            self.canonical,
            ("cursor",),
            run_command=runner,
            cursor_builder=fake_cursor_builder,
        )
        self.assertTrue(any("Blox shell cursor surfaces could not be reloaded" in warning for warning in warnings))

    def test_partial_apply_carries_unselected_targets_byte_for_byte(self) -> None:
        self.apply_canonical()
        before_path, before_manifest = current_generation(self.state)
        before = {name: (before_path / name).read_bytes() for name in before_manifest["files"]}
        manifest, _ = apply_theme(self.alternate_path, self.alternate, ("quickshell",), run_command=FakeCommands())
        after_path, _ = current_generation(self.state)
        self.assertNotEqual(before["quickshell/theme.json"], (after_path / "quickshell/theme.json").read_bytes())
        for name in ("kitty/theme.conf", "hypr/wallpaper.json"):
            self.assertEqual(before[name], (after_path / name).read_bytes(), name)
        for name in TARGET_FILES["gtk"]:
            self.assertEqual(before[name], (after_path / name).read_bytes(), name)
        self.assertEqual("phase2-alternate", manifest["target_sources"]["quickshell"]["theme_id"])
        self.assertEqual("catppuccin-mocha", manifest["target_sources"]["kitty"]["theme_id"])

    def test_authoritative_inline_apply_can_remove_a_builtin_target_without_saving_source(self) -> None:
        first = copy.deepcopy(self.canonical)
        apply_theme(self.canonical_path, first, ("quickshell", "kitty"), run_command=FakeCommands())

        candidate = copy.deepcopy(self.canonical)
        candidate["targets"] = {target: target == "quickshell" for target in TARGET_NAMES}
        manifest, _ = apply_theme(
            self.canonical_path,
            candidate,
            ("quickshell", "kitty"),
            run_command=FakeCommands(),
            authoritative_targets=True,
        )

        active = (self.state / "current").resolve()
        self.assertEqual(["quickshell"], manifest["enabled_targets"])
        self.assertTrue((active / "quickshell/theme.json").is_file())
        self.assertFalse((active / "kitty/theme.conf").exists())
        self.assertTrue(self.canonical_path.is_file())
        self.assertTrue(json.loads(self.canonical_path.read_text(encoding="utf-8"))["targets"]["kitty"])

    def test_partial_apply_does_not_touch_an_unselected_gtk_loader(self) -> None:
        self.apply_canonical()
        loader = self.root / "config/gtk-3.0/gtk.css"
        loader.unlink()
        loader.write_text("/* foreign GTK loader */\n", encoding="utf-8")
        alternate = copy.deepcopy(self.alternate)
        alternate["targets"]["stylus"] = True

        manifest, _ = apply_theme(
            self.alternate_path,
            alternate,
            ("stylus",),
            run_command=FakeCommands(),
        )

        self.assertIn("stylus", manifest["enabled_targets"])
        self.assertEqual("/* foreign GTK loader */\n", loader.read_text(encoding="utf-8"))

    def test_legacy_gtk_owned_helium_file_is_not_carried_forward(self) -> None:
        self.apply_canonical()
        active = (self.state / "current").resolve()
        legacy = active / "gtk/helium/manifest.json"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("{}\n", encoding="utf-8")
        manifest_path = active / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["files"]["gtk/helium/manifest.json"] = hashlib.sha256(legacy.read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        current_generation(self.state)
        apply_theme(self.canonical_path, self.canonical, ("quickshell",), run_command=FakeCommands())
        self.assertFalse(((self.state / "current").resolve() / "gtk/helium/manifest.json").exists())

    def test_alternate_theme_changes_all_phase_two_targets(self) -> None:
        self.apply_canonical()
        before_path, before_manifest = current_generation(self.state)
        before = {name: (before_path / name).read_bytes() for name in before_manifest["files"]}
        apply_theme(self.alternate_path, self.alternate, PHASE2_TARGETS, run_command=FakeCommands())
        after_path, after_manifest = current_generation(self.state)
        self.assertEqual(set(before), set(after_manifest["files"]))
        changed_files = {name for target in PHASE2_TARGETS for name in TARGET_FILES[target]}
        for name in changed_files:
            self.assertNotEqual(before[name], (after_path / name).read_bytes(), name)

    def test_shape_apply_and_rollback_switch_exact_files(self) -> None:
        first, _ = self.apply_canonical()
        first_path, _ = current_generation(self.state)
        before = {
            name: (first_path / name).read_bytes()
            for name in (
                "quickshell/theme.json",
                "hyprland/theme.lua",
                "gtk/gtk-3.0/gtk.css",
                "gtk/gtk-4.0/gtk.css",
            )
        }
        changed = copy.deepcopy(self.canonical)
        changed["shape"] = {"radius_scale": 0.65, "density_scale": 0.75}

        apply_theme(
            self.canonical_path,
            changed,
            ("quickshell", "hyprland", "gtk"),
            run_command=FakeCommands(),
        )
        active, _ = current_generation(self.state)
        self.assertEqual(changed["shape"], json.loads((active / "quickshell/theme.json").read_text())["shape"])
        self.assertIn("gaps_in = 0,", (active / "hyprland/theme.lua").read_text())
        self.assertIn("rounding = 8,", (active / "hyprland/theme.lua").read_text())
        self.assertIn("border-radius: 8px;", (active / "gtk/gtk-4.0/gtk.css").read_text())

        rollback(first["generation_id"], run_command=FakeCommands())
        restored, _ = current_generation(self.state)
        for name, content in before.items():
            self.assertEqual(content, (restored / name).read_bytes(), name)

    def test_wallpaper_apply_reloads_the_quickshell_surface(self) -> None:
        runner = FakeCommands()
        apply_theme(
            self.canonical_path,
            self.canonical,
            ("wallpaper",),
            run_command=runner,
        )

        wallpaper = json.loads((self.state / "current/hypr/wallpaper.json").read_text(encoding="utf-8"))
        self.assertEqual(str(resolve_wallpaper_path(self.canonical["wallpaper"]["path"], self.canonical_path)), wallpaper["path"])
        self.assertEqual(self.canonical["wallpaper"]["fit"], wallpaper["fit"])
        self.assertIn(
            ["bash", str(repository_root() / "shell/scripts/ipc.sh"), "theme", "reloadWallpaper"],
            runner.commands,
        )

    def test_wallpaper_apply_resolves_builtin_data_relative_source_paths(self) -> None:
        self.canonical["wallpaper"]["path"] = "schema/theme.schema.json"
        apply_theme(self.canonical_path, self.canonical, ("wallpaper",), run_command=FakeCommands())
        wallpaper = json.loads((self.state / "current/hypr/wallpaper.json").read_text(encoding="utf-8"))
        self.assertEqual(str(THEMES / "schema/theme.schema.json"), wallpaper["path"])

    def test_render_failure_cannot_expose_partial_generation(self) -> None:
        self.apply_canonical()
        before = os.readlink(self.state / "current")

        def fail_renderer(theme: dict) -> tuple[dict[str, str], list[str]]:
            raise RuntimeFailure("injected render failure")

        with self.assertRaisesRegex(RuntimeFailure, "injected"):
            apply_theme(self.alternate_path, self.alternate, TARGET_NAMES, run_command=FakeCommands(), renderer=fail_renderer)
        self.assertEqual(before, os.readlink(self.state / "current"))
        self.assertEqual([], list((self.state / "generations").glob(".candidate-*")))

    def test_unavailable_helium_fails_before_state_mutation(self) -> None:
        with mock.patch(
            "blox_theme.runtime.detect_browser_target",
            return_value={"available": False, "label": "Helium", "reason": "Helium is not installed"},
        ):
            with self.assertRaisesRegex(RuntimeFailure, "Helium target is unavailable"):
                apply_theme(self.canonical_path, self.canonical, ("helium",), run_command=FakeCommands())
        self.assertFalse(self.state.exists())

    def test_corrupt_active_generation_blocks_carry_forward(self) -> None:
        self.apply_canonical()
        active, _ = current_generation(self.state)
        (active / "kitty/theme.conf").write_text("tampered\n", encoding="utf-8")
        before = os.readlink(self.state / "current")
        with self.assertRaisesRegex(RuntimeFailure, "digest mismatch"):
            apply_theme(self.alternate_path, self.alternate, ("quickshell",), run_command=FakeCommands())
        self.assertEqual(before, os.readlink(self.state / "current"))

    def test_partial_loader_installation_is_cleaned_up(self) -> None:
        link = kitty_theme_link()
        link.write_text("owned", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeFailure, "conflicting Kitty"):
            self.apply_canonical()
        self.assertEqual("owned", link.read_text(encoding="utf-8"))
        self.assertFalse((self.state / "current").exists())

    def test_missing_tracked_loader_blocks_apply_before_state_mutation(self) -> None:
        (self.root / "config/quickshell/blox/shared/Theme.qml").unlink()
        with self.assertRaisesRegex(RuntimeFailure, "tracked theme loader"):
            apply_theme(self.canonical_path, self.canonical, ("quickshell",), run_command=FakeCommands())
        self.assertFalse(self.state.exists())

    def test_reload_failure_keeps_valid_files_active_and_returns_recovery(self) -> None:
        manifest, warnings = self.apply_canonical(FakeCommands(returncode=1))
        self.assertEqual(manifest, current_generation(self.state)[1])
        self.assertTrue(any("run:" in warning for warning in warnings))

    def test_installed_gtk_mode_bypasses_css_and_updates_settings_links(self) -> None:
        self.apply_canonical()
        installed = json.loads(json.dumps(self.canonical))
        installed["gtk"].update(mode="installed", base_theme="Adwaita")
        runner = FakeCommands()
        manifest, warnings = apply_theme(self.canonical_path, installed, ("gtk",), run_command=runner)
        self.assertEqual([], warnings)
        active = (self.state / "current").resolve()
        self.assertNotIn("gtk/gtk-3.0/gtk.css", manifest["files"])
        self.assertNotIn("gtk/gtk-4.0/gtk.css", manifest["files"])
        for version in ("3", "4"):
            config = self.root / f"config/gtk-{version}.0"
            self.assertEqual(self.state / f"current/gtk/gtk-{version}.0/settings.ini", Path(os.readlink(config / "settings.ini")))
            self.assertEqual(REPOSITORY / f"gtk/.config/gtk-{version}.0/blox-theme-empty.css", Path(os.readlink(config / "blox-theme.css")))
            self.assertFalse((active / f"gtk/gtk-{version}.0/gtk.css").exists())
        flattened = [part for command in runner.commands for part in command]
        self.assertIn("Adwaita", flattened)
        self.assertIn("prefer-dark", flattened)

    def test_gtk_loader_conflict_aborts_without_switching(self) -> None:
        self.apply_canonical()
        before = os.readlink(self.state / "current")
        loader = self.root / "config/gtk-3.0/gtk.css"
        loader.unlink()
        loader.write_text("owned", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeFailure, "conflicting GTK loader"):
            apply_theme(self.canonical_path, self.canonical, ("gtk",), run_command=FakeCommands())
        self.assertEqual(before, os.readlink(self.state / "current"))
        self.assertEqual("owned", loader.read_text(encoding="utf-8"))

    def test_gtk_loader_from_another_blox_checkout_is_adopted(self) -> None:
        self.apply_canonical()
        alternate = self.root / "other-checkout/gtk-3.0/gtk.css"
        alternate.parent.mkdir(parents=True)
        alternate.write_bytes((REPOSITORY / "gtk/.config/gtk-3.0/gtk.css").read_bytes())
        loader = self.root / "config/gtk-3.0/gtk.css"
        loader.unlink()
        loader.symlink_to(alternate)

        manifest, warnings = apply_theme(
            self.canonical_path,
            self.canonical,
            ("gtk",),
            run_command=FakeCommands(),
        )

        self.assertEqual("catppuccin-mocha", manifest["theme_id"])
        self.assertEqual([], warnings)
        self.assertEqual(REPOSITORY / "gtk/.config/gtk-3.0/gtk.css", Path(os.readlink(loader)))

    def test_explicit_gtk_setup_records_and_preserves_legacy_symlinks(self) -> None:
        legacy_light = self.root / "legacy-light.css"
        legacy_dark = self.root / "legacy-dark.css"
        legacy_light.write_text("/* light */", encoding="utf-8")
        legacy_dark.write_text("/* dark */", encoding="utf-8")
        config = self.root / "config/gtk-4.0"
        config.mkdir(parents=True)
        (config / "gtk.css").symlink_to(legacy_light)
        (config / "gtk-dark.css").symlink_to(legacy_dark)
        integration = setup_gtk()
        self.assertEqual(str(legacy_light), integration["loaders"]["4"]["gtk.css"]["target"])
        self.assertEqual(REPOSITORY / "gtk/.config/gtk-4.0/gtk.css", Path(os.readlink(config / "gtk.css")))
        self.assertEqual(legacy_light, Path(os.readlink(config / "blox-theme.css")))
        self.assertEqual(legacy_dark, Path(os.readlink(config / "blox-theme-dark.css")))
        self.assertFalse((self.state / "current").exists())
        self.apply_canonical()

    def test_gtk_setup_discards_broken_legacy_symlink_as_fallback(self) -> None:
        config = self.root / "config/gtk-4.0"
        config.mkdir(parents=True)
        broken = self.root / "missing.css"
        (config / "gtk.css").symlink_to(broken)
        integration = setup_gtk()
        self.assertEqual({"kind": "absent"}, integration["loaders"]["4"]["gtk.css"])
        self.assertEqual(REPOSITORY / "gtk/.config/gtk-4.0/blox-theme-empty.css", Path(os.readlink(config / "blox-theme.css")))

    def test_gtk_setup_refuses_regular_user_stylesheet(self) -> None:
        config = self.root / "config/gtk-3.0"
        config.mkdir(parents=True)
        stylesheet = config / "gtk.css"
        stylesheet.write_text("/* owned */", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeFailure, "regular GTK stylesheet"):
            setup_gtk()
        self.assertEqual("/* owned */", stylesheet.read_text(encoding="utf-8"))

    def test_reconcile_is_idempotent_and_does_not_render(self) -> None:
        self.apply_canonical()
        before = os.readlink(self.state / "current")
        first_runner = FakeCommands()
        second_runner = FakeCommands()
        first, first_warnings = reconcile(run_command=first_runner)
        second, second_warnings = reconcile(run_command=second_runner)
        self.assertEqual(first, second)
        self.assertEqual(first_warnings, second_warnings)
        self.assertEqual(before, os.readlink(self.state / "current"))
        self.assertEqual(first_runner.commands, second_runner.commands)

    def test_rollback_restores_files_and_runs_reload_actions(self) -> None:
        first, _ = self.apply_canonical()
        first_path = (self.state / "current").resolve()
        first_quickshell = (first_path / "quickshell/theme.json").read_bytes()
        apply_theme(self.alternate_path, self.alternate, PHASE2_TARGETS, run_command=FakeCommands())
        runner = FakeCommands()
        restored, warnings = rollback(first["generation_id"], run_command=runner)
        self.assertTrue(any("Stylus" in warning for warning in warnings))
        self.assertEqual(first["generation_id"], restored["generation_id"])
        self.assertEqual(first_quickshell, ((self.state / "current").resolve() / "quickshell/theme.json").read_bytes())
        self.assertTrue(runner.commands)

    def test_rollback_resets_targets_missing_from_destination(self) -> None:
        first, _ = apply_theme(self.canonical_path, self.canonical, PHASE2_TARGETS, run_command=FakeCommands())
        self.apply_canonical()
        runner = FakeCommands()
        restored, warnings = rollback(first["generation_id"], run_command=runner)
        self.assertEqual(sorted(PHASE2_TARGETS), restored["enabled_targets"])
        self.assertTrue(any("Hyprlock" in warning for warning in warnings))
        self.assertTrue(any(command[:2] == ["hyprctl", "reload"] for command in runner.commands))
        for target in ("hyprlock", "btop", "micro", "glow"):
            link, _ = phase7_loader_specs(self.state)[target]
            self.assertTrue(link.is_symlink(), target)
            self.assertIn("integration/phase7-fallbacks", os.readlink(link))
            self.assertTrue(link.resolve().is_file(), target)

    def test_reset_target_removes_only_that_target_and_runs_reset(self) -> None:
        self.apply_canonical()
        runner = FakeCommands()
        manifest, warnings = reset_target("quickshell", run_command=runner)
        self.assertEqual([], warnings)
        active = (self.state / "current").resolve()
        self.assertFalse((active / "quickshell/theme.json").exists())
        self.assertNotIn("quickshell", manifest["enabled_targets"])
        self.assertTrue((active / "kitty/theme.conf").is_file())
        self.assertIn("reset", runner.commands[0])

    def test_widget_reload_failure_is_recoverable(self) -> None:
        runner = FakeCommands(returncode=1)
        manifest, warnings = apply_theme(self.canonical_path, self.canonical, ("widgets",), run_command=runner)
        self.assertEqual(["widgets"], manifest["enabled_targets"])
        self.assertTrue((self.state / "current/widgets/profile.json").is_file())
        self.assertTrue(any("Widget profile reload failed" in warning for warning in warnings))
        self.assertTrue(any(command[-1] == "reloadWidgets" for command in runner.commands))

    def test_code_installs_generated_theme_extension_and_selects_it(self) -> None:
        legacy = self.root / f"vscode-extensions/{EDITOR_LEGACY_EXTENSION_DIR}"
        legacy.mkdir(parents=True)
        (legacy / "package.json").write_text(json.dumps({"name": "blox-dark-2026", "publisher": "blox"}), encoding="utf-8")
        manifest, warnings = apply_theme(self.canonical_path, self.canonical, ("code",), run_command=FakeCommands())
        extension = self.root / f"vscode-extensions/{EDITOR_EXTENSION_DIR}"
        self.assertTrue((extension / "package.json").is_file())
        self.assertTrue((extension / "themes/blox-generated-color-theme.json").is_file())
        self.assertFalse((extension / "settings.json").exists())
        settings = (self.root / "config/Code/User/settings.json").read_text(encoding="utf-8")
        self.assertIn('"workbench.colorTheme": "blox-theme"', settings)
        self.assertIn('"workbench.experimental.modernUI": true', settings)
        self.assertIn('"editor.fontFamily": "FiraCode Nerd Font Mono"', settings)
        self.assertTrue(editor_settings_integration_path(self.state).is_file())
        self.assertFalse(legacy.exists())
        self.assertNotIn("workbench.colorCustomizations", json.loads((self.state / "current/code/settings.json").read_text()))
        self.assertEqual(["code"], manifest["enabled_targets"])
        self.assertTrue(any("theme package and settings applied" in warning for warning in warnings))

    def test_cursor_installs_same_theme_package_without_modern_ui_or_customisations(self) -> None:
        manifest, warnings = apply_theme(self.canonical_path, self.canonical, ("cursor_editor",), run_command=FakeCommands())
        extension = self.root / f"cursor-extensions/{EDITOR_EXTENSION_DIR}"
        self.assertTrue((extension / "package.json").is_file())
        self.assertTrue((extension / "themes/blox-generated-color-theme.json").is_file())
        settings = json.loads((self.root / "config/Cursor/User/settings.json").read_text(encoding="utf-8"))
        self.assertEqual("blox-theme", settings["workbench.colorTheme"])
        self.assertEqual("FiraCode Nerd Font Mono", settings["editor.fontFamily"])
        self.assertNotIn("workbench.experimental.modernUI", settings)
        self.assertNotIn("workbench.colorCustomizations", settings)
        cursor_theme = (extension / "themes/blox-generated-color-theme.json").read_bytes()
        self.assertTrue(cursor_theme)
        self.assertEqual(["cursor_editor"], manifest["enabled_targets"])
        self.assertTrue(any("Cursor theme package and settings applied" in warning for warning in warnings))

    def test_t3code_publishes_supported_environment_theme_and_restores_prior_state(self) -> None:
        t3_home = self.root / "t3code"
        settings = t3_home / "userdata/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            json.dumps({"defaultTheme": "ocean", "defaultThemeSetAt": "2026-08-29T00:00:00Z", "keep": True}) + "\n",
            encoding="utf-8",
        )
        previous = t3_home / "userdata/themes/blox-theme.json"
        previous.parent.mkdir(parents=True)
        previous.write_text('{"name":"old","appearance":"dark","canvas":"#000000","accent":"#ffffff"}\n', encoding="utf-8")

        manifest, warnings = apply_theme(self.canonical_path, self.canonical, ("t3code",), run_command=FakeCommands())

        published_path, settings_path, _ = t3code_paths()
        self.assertEqual(["t3code"], manifest["enabled_targets"])
        self.assertEqual([], warnings)
        published = json.loads(published_path.read_text(encoding="utf-8"))
        self.assertEqual(self.canonical["name"], published["name"])
        self.assertEqual(self.canonical["variant"], published["appearance"])
        self.assertEqual(self.canonical["colours"]["background"], published["canvas"])
        self.assertEqual(self.canonical["colours"]["accent"], published["accent"])
        self.assertEqual(self.canonical["colours"]["surface"], published["colors"]["surface"])
        self.assertEqual(T3CODE_THEME_ID, json.loads(settings_path.read_text(encoding="utf-8"))["defaultTheme"])
        self.assertTrue(t3code_integration_path(self.state).is_file())

        reset_manifest, reset_warnings = reset_target("t3code", run_command=FakeCommands())
        self.assertNotIn("t3code", reset_manifest["enabled_targets"])
        self.assertEqual([], reset_warnings)
        self.assertEqual('{"name":"old","appearance":"dark","canvas":"#000000","accent":"#ffffff"}\n', previous.read_text(encoding="utf-8"))
        self.assertEqual(
            {"defaultTheme": "ocean", "defaultThemeSetAt": "2026-08-29T00:00:00Z", "keep": True},
            json.loads(settings_path.read_text(encoding="utf-8")),
        )
        self.assertFalse(t3code_integration_path(self.state).exists())

    def test_t3code_reset_preserves_an_external_deletion(self) -> None:
        published_path, settings_path, _ = t3code_paths()
        published_path.parent.mkdir(parents=True, exist_ok=True)
        published_path.write_text('{"name":"old"}\n', encoding="utf-8")
        apply_theme(self.canonical_path, self.canonical, ("t3code",), run_command=FakeCommands())
        published_path.unlink()
        settings_data = json.loads(settings_path.read_text(encoding="utf-8"))
        settings_data["defaultTheme"] = "user-choice"
        settings_data["defaultThemeSetAt"] = "2026-08-30T00:00:00Z"
        settings_path.write_text(json.dumps(settings_data), encoding="utf-8")

        _, warnings = reset_target("t3code", run_command=FakeCommands())

        self.assertTrue(any("published theme is missing" in warning for warning in warnings))
        self.assertTrue(any("default theme changed outside Blox" in warning for warning in warnings))
        self.assertFalse(published_path.exists())
        self.assertEqual("user-choice", json.loads(settings_path.read_text(encoding="utf-8"))["defaultTheme"])
        self.assertTrue(t3code_integration_path(self.state).is_file())

    def test_zed_publishes_native_theme_and_preserves_jsonc_settings(self) -> None:
        published, settings = zed_paths()
        settings.parent.mkdir(parents=True)
        original_settings = (
            "{\n"
            "  // keep the user's Zed settings\n"
            '  "theme": {"mode": "system", "light": "One Light", "dark": "One Dark"},\n'
            '  "theme_overrides": {"editor.background": "#010203"},\n'
            '}\n'
        )
        settings.write_text(original_settings, encoding="utf-8")
        previous = '{"name":"Blox generated","themes":[]}'
        published.parent.mkdir(parents=True)
        published.write_text(previous, encoding="utf-8")

        manifest, warnings = apply_theme(self.canonical_path, self.canonical, ("zed",), run_command=FakeCommands())

        self.assertEqual(["zed"], manifest["enabled_targets"])
        self.assertEqual([], warnings)
        generated = json.loads(published.read_text(encoding="utf-8"))
        self.assertEqual("Blox generated", generated["name"])
        self.assertEqual("Blox: Catppuccin Mocha", generated["themes"][0]["name"])
        values = read_settings_values(settings, ("theme", "theme_overrides"))
        self.assertEqual("system", values["theme"]["value"]["mode"])
        self.assertEqual("One Light", values["theme"]["value"]["light"])
        self.assertEqual("Blox: Catppuccin Mocha", values["theme"]["value"]["dark"])
        self.assertEqual({"editor.background": "#010203"}, values["theme_overrides"]["value"])
        self.assertIn("keep the user's Zed settings", settings.read_text(encoding="utf-8"))

        reset_target("zed", run_command=FakeCommands())

        self.assertEqual(previous, published.read_text(encoding="utf-8"))
        restored_values = read_settings_values(settings, ("theme", "theme_overrides"))
        self.assertEqual(
            {"mode": "system", "light": "One Light", "dark": "One Dark"},
            restored_values["theme"]["value"],
        )
        self.assertEqual({"editor.background": "#010203"}, restored_values["theme_overrides"]["value"])
        self.assertIn("keep the user's Zed settings", settings.read_text(encoding="utf-8"))
        self.assertFalse(zed_integration_path(self.state).exists())

    def test_zed_reset_restores_the_setting_before_removing_owned_theme(self) -> None:
        published, settings = zed_paths()
        settings.parent.mkdir(parents=True)
        settings.write_text('{"theme":"One Dark"}\n', encoding="utf-8")

        apply_theme(self.canonical_path, self.canonical, ("zed",), run_command=FakeCommands())

        events: list[str] = []
        original_restore = restore_settings
        original_unlink = Path.unlink

        def record_restore(*args: Any, **kwargs: Any) -> None:
            events.append("settings")
            original_restore(*args, **kwargs)

        def record_unlink(path: Path, *args: Any, **kwargs: Any) -> None:
            if path == published:
                events.append("published")
            original_unlink(path, *args, **kwargs)

        with mock.patch("blox_theme.runtime.restore_settings", side_effect=record_restore), mock.patch.object(Path, "unlink", autospec=True, side_effect=record_unlink):
            reset_target("zed", run_command=FakeCommands())

        self.assertLess(events.index("settings"), events.index("published"))

    def test_zed_string_theme_setting_is_restored(self) -> None:
        _, settings = zed_paths()
        settings.parent.mkdir(parents=True)
        settings.write_text('{"theme":"One Dark","keep":true}\n', encoding="utf-8")

        apply_theme(self.canonical_path, self.canonical, ("zed",), run_command=FakeCommands())

        values = read_settings_values(settings, ("theme",))
        self.assertEqual("Blox: Catppuccin Mocha", values["theme"]["value"])
        reset_target("zed", run_command=FakeCommands())
        self.assertEqual('{"theme":"One Dark","keep":true}\n', settings.read_text(encoding="utf-8"))

    def test_zed_second_apply_replaces_the_previous_generated_theme(self) -> None:
        _, settings = zed_paths()
        settings.parent.mkdir(parents=True)
        settings.write_text(
            '{"theme":{"mode":"system","light":"One Light","dark":"One Dark"}}\n',
            encoding="utf-8",
        )
        first = copy.deepcopy(self.canonical)
        second = copy.deepcopy(self.canonical)
        second["name"] = "Second Zed Theme"
        second["colours"]["background"] = "#101218"

        apply_theme(self.canonical_path, first, ("zed",), run_command=FakeCommands())
        apply_theme(self.canonical_path, second, ("zed",), run_command=FakeCommands())

        published, _ = zed_paths()
        generated = json.loads(published.read_text(encoding="utf-8"))
        self.assertEqual("Blox: Second Zed Theme", generated["themes"][0]["name"])
        values = read_settings_values(settings, ("theme",))
        self.assertEqual("Blox: Second Zed Theme", values["theme"]["value"]["dark"])

    def test_zed_missing_install_does_not_change_settings(self) -> None:
        _, settings = zed_paths()
        settings.parent.mkdir(parents=True)
        original = '{"theme":"One Dark"}\n'
        settings.write_text(original, encoding="utf-8")
        with mock.patch("blox_theme.runtime.shutil.which", return_value=None):
            _, warnings = apply_theme(self.canonical_path, self.canonical, ("zed",), run_command=FakeCommands())

        self.assertTrue(any("Zed is not installed" in warning for warning in warnings))
        self.assertEqual(original, settings.read_text(encoding="utf-8"))
        self.assertFalse(zed_paths()[0].exists())

    def test_zed_foreign_theme_file_is_not_replaced(self) -> None:
        published, _ = zed_paths()
        published.parent.mkdir(parents=True)
        original = '{"name":"Foreign theme"}\n'
        published.write_text(original, encoding="utf-8")

        _, warnings = apply_theme(self.canonical_path, self.canonical, ("zed",), run_command=FakeCommands())

        self.assertTrue(any("foreign Zed theme" in warning for warning in warnings))
        self.assertEqual(original, published.read_text(encoding="utf-8"))

    def test_code_apply_tracks_prior_presence_and_reset_removes_only_blox_values(self) -> None:
        settings = self.root / "config/Code/User/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            '{\n'
            "  // keep the user's settings\n"
            '  "editor.fontSize": 17,\n'
            '  "workbench.experimental.modernUI": false,\n'
            '  "editor.fontFamily": "User Font",\n'
            '}\n',
            encoding="utf-8",
        )
        self.canonical["shape"]["radius_scale"] = 0
        apply_theme(self.canonical_path, self.canonical, ("code",), run_command=FakeCommands())
        applied = read_settings_values(settings, ("workbench.colorTheme", "workbench.experimental.modernUI", "editor.fontFamily", "editor.fontSize"))
        self.assertEqual("blox-theme", applied["workbench.colorTheme"]["value"])
        self.assertFalse(applied["workbench.experimental.modernUI"]["value"])
        self.assertEqual("FiraCode Nerd Font Mono", applied["editor.fontFamily"]["value"])
        self.assertEqual(17, applied["editor.fontSize"]["value"])
        reset_target("code", run_command=FakeCommands())
        restored = read_settings_values(settings, ("workbench.colorTheme", "workbench.experimental.modernUI", "editor.fontFamily", "editor.fontSize"))
        self.assertEqual("User Font", restored["editor.fontFamily"]["value"])
        self.assertFalse(restored["workbench.experimental.modernUI"]["value"])
        self.assertEqual(17, restored["editor.fontSize"]["value"])
        self.assertFalse(restored["workbench.colorTheme"]["present"])

    def test_cursor_does_not_write_modern_ui_setting_and_reset_removes_package(self) -> None:
        settings = self.root / "config/Cursor/User/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text('{"editor.fontSize": 16}\n', encoding="utf-8")
        apply_theme(self.canonical_path, self.canonical, ("cursor_editor",), run_command=FakeCommands())
        settings_data = json.loads(settings.read_text(encoding="utf-8"))
        self.assertNotIn("workbench.experimental.modernUI", settings_data)
        self.assertEqual(16, settings_data["editor.fontSize"])
        reset_target("cursor_editor", run_command=FakeCommands())
        restored = json.loads(settings.read_text(encoding="utf-8"))
        self.assertEqual({"editor.fontSize": 16}, restored)
        self.assertFalse((self.root / f"cursor-extensions/{EDITOR_EXTENSION_DIR}").exists())

    def test_editor_reset_preserves_a_value_changed_after_apply(self) -> None:
        settings = self.root / "config/Code/User/settings.json"
        apply_theme(self.canonical_path, self.canonical, ("code",), run_command=FakeCommands())
        settings.write_text(
            settings.read_text(encoding="utf-8").replace("FiraCode Nerd Font Mono", "User Font"),
            encoding="utf-8",
        )
        _, warnings = reset_target("code", run_command=FakeCommands())
        self.assertTrue(any("preserved user-edited code setting: editor.fontFamily" in warning for warning in warnings))
        values = read_settings_values(settings, ("editor.fontFamily", "workbench.colorTheme"))
        self.assertEqual("User Font", values["editor.fontFamily"]["value"])
        self.assertFalse(values["workbench.colorTheme"]["present"])

    def test_editor_apply_migrates_only_matching_legacy_colour_customisations(self) -> None:
        settings = self.root / "config/Code/User/settings.json"
        legacy = editor_colours(self.canonical)
        legacy["user.setting"] = "keep"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"workbench.colorCustomizations": legacy}) + "\n", encoding="utf-8")
        _, warnings = self.apply_canonical()
        settings_data = json.loads(settings.read_text(encoding="utf-8"))
        self.assertEqual({"user.setting": "keep"}, settings_data["workbench.colorCustomizations"])
        self.assertTrue(any("Code legacy colour customisations migrated" in warning for warning in warnings))

    def test_every_target_reset_path_is_safe(self) -> None:
        for target in TARGET_NAMES:
            with self.subTest(target=target):
                if self.state.exists():
                    shutil.rmtree(self.state)
                if kitty_theme_link().is_symlink():
                    kitty_theme_link().unlink()
                for version in ("3", "4"):
                    shutil.rmtree(self.root / f"config/gtk-{version}.0", ignore_errors=True)
                shutil.rmtree(self.obsidian_vault / ".obsidian/themes/Blox generated", ignore_errors=True)
                shutil.rmtree(self.obsidian_vault / ".obsidian/themes/blox-generated", ignore_errors=True)
                (self.obsidian_vault / ".obsidian/appearance.json").write_text(
                    '{"cssTheme": "Minimal", "otherSetting": true}\n', encoding="utf-8"
                )
                (self.state / "integration/obsidian.json").unlink(missing_ok=True)
                self.apply_canonical()
                runner = FakeCommands()
                manifest, warnings = reset_target(target, run_command=runner)
                manual = {"helium", "chromium", "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "stylus", "powerlevel10k"}
                if target != "kitty":
                    self.assertEqual(target in manual, bool(warnings))
                active = (self.state / "current").resolve()
                for name in TARGET_FILES[target]:
                    self.assertFalse((active / name).exists())
                self.assertNotIn(target, manifest["enabled_targets"])
                if target == "kitty":
                    self.assertFalse(kitty_theme_link().exists())
                if target in {"hyprlock", "btop", "micro", "glow"}:
                    link, _ = phase7_loader_specs(self.state)[target]
                    self.assertTrue(link.is_symlink())
                    self.assertIn("integration/phase7-fallbacks", os.readlink(link))
                    self.assertTrue(link.resolve().is_file())
                if target == "hyprland":
                    self.assertFalse(hyprtoolkit_theme_link().exists())

    def test_history_retains_current_plus_five_previous_generations(self) -> None:
        for index in range(8):
            theme = self.canonical if index % 2 == 0 else self.alternate
            path = self.canonical_path if index % 2 == 0 else self.alternate_path
            targets = TARGET_NAMES if index % 2 == 0 else PHASE2_TARGETS
            apply_theme(path, theme, targets, run_command=FakeCommands(), cursor_builder=fake_cursor_builder)
        generations = [path for path in (self.state / "generations").iterdir() if path.is_dir()]
        self.assertEqual(6, len(generations))
        self.assertIn((self.state / "current").resolve(), generations)

    def test_lock_contention_is_reported_without_mutation(self) -> None:
        with ApplicationLock(self.state):
            with self.assertRaises(LockContended):
                self.apply_canonical()
        self.assertFalse((self.state / "current").exists())

    def test_manifest_tampering_and_escaping_current_link_are_rejected(self) -> None:
        self.apply_canonical()
        active, _ = current_generation(self.state)
        manifest_path = active / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["unexpected"] = True
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeFailure, "structure"):
            validate_generation(active)
        (self.state / "current").unlink()
        (self.state / "current").symlink_to(self.root)
        with self.assertRaisesRegex(RuntimeFailure, "escapes"):
            current_generation(self.state)

    def test_invalid_active_manifest_link_is_rejected(self) -> None:
        self.apply_canonical()
        (self.state / "active.json").unlink()
        (self.state / "active.json").symlink_to("wrong.json")
        with self.assertRaisesRegex(RuntimeFailure, "active manifest link"):
            current_generation(self.state)

    def test_invalid_targets_are_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeFailure, "unsupported"):
            apply_theme(self.canonical_path, self.canonical, ("unknown",), run_command=FakeCommands())
    def test_reconcile_and_rollback_reject_invalid_requests(self) -> None:
        first, _ = self.apply_canonical()
        with self.assertRaisesRegex(RuntimeFailure, "not active"):
            reconcile(("unknown",), run_command=FakeCommands())
        with self.assertRaisesRegex(RuntimeFailure, "already active"):
            rollback(first["generation_id"], run_command=FakeCommands())
        with self.assertRaisesRegex(RuntimeFailure, "invalid generation ID"):
            rollback("../escape", run_command=FakeCommands())


class RuntimeCliTests(unittest.TestCase):
    def test_cli_apply_reconcile_reset_and_rollback_envelopes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            # Every external command used by the targets in this integration
            # test must be isolated.
            for name in (
                "hyprctl",
                "kitty",
                "quickshell",
                "systemctl",
            ):
                executable = fake_bin / name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)
            environment = os.environ.copy()
            environment.update({
                "XDG_STATE_HOME": str(root / "state"),
                "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"),
                "PATH": f"{fake_bin}:{environment['PATH']}",
                "QUICKSHELL_IPC_PID": "4242",
                "BLOX_SHELL_DIR": str(root / "config" / "quickshell" / "blox"),
            })
            quickshell_loader = root / "config/quickshell/blox/shared/Theme.qml"
            quickshell_loader.parent.mkdir(parents=True)
            quickshell_loader.write_text("watchChanges: true\nfunction loadJson() {}\n", encoding="utf-8")
            kitty_config = root / "config/kitty/kitty.conf"
            kitty_config.parent.mkdir(parents=True)
            kitty_config.write_text("globinclude blox-theme.conf\n", encoding="utf-8")

            def invoke(*arguments: str) -> tuple[int, dict]:
                completed = subprocess.run([str(THEMES / "bin/themectl"), *arguments, "--json"], cwd=REPOSITORY, env=environment, check=False, capture_output=True, text=True)
                return completed.returncode, json.loads(completed.stdout)

            apply_code, applied = invoke("apply", "catppuccin-mocha", "--targets", "quickshell,wallpaper")
            if apply_code != 0:
                print("APPLY ERRORS:", applied.get("errors"))
            self.assertEqual(0, apply_code)
            self.assertTrue(applied["ok"])
            first = applied["data"]["generation"]
            streamed = subprocess.run(
                [str(THEMES / "bin/themectl"), "apply", "catppuccin-mocha", "--targets", "quickshell,wallpaper", "--progress-ndjson", "--json"],
                cwd=REPOSITORY,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, streamed.returncode)
            events = [json.loads(line) for line in streamed.stderr.splitlines()]
            self.assertTrue(events)
            self.assertTrue(all(event["type"] == "theme-progress" for event in events))
            self.assertEqual(["quickshell", "wallpaper"], events[0]["targets"])
            stage_ids = list(dict.fromkeys(event["stage"] for event in events if event["kind"] == "stage"))
            self.assertEqual(["prepare", "cursor", "activation", "applications"], stage_ids)
            target_events = [event for event in events if event["kind"] == "target"]
            self.assertEqual(["quickshell", "wallpaper"], [event["target"] for event in target_events])
            self.assertEqual(["unchanged", "unchanged"], [event["state"] for event in target_events])
            self.assertEqual([], json.loads(streamed.stdout)["data"]["changed_targets"])
            self.assertEqual(["quickshell", "wallpaper"], json.loads(streamed.stdout)["data"]["unchanged_targets"])
            self.assertEqual(events[-1]["total"], events[-1]["completed"])
            first = json.loads(streamed.stdout)["data"]["generation"]
            reconcile_code, reconciled = invoke("reconcile")
            self.assertEqual(0, reconcile_code)
            self.assertEqual(first, reconciled["data"]["generation"])
            reset_code, reset = invoke("reset-target", "quickshell")
            self.assertEqual(0, reset_code)
            self.assertNotIn("quickshell", reset["data"]["active_targets"])
            rollback_code, rolled_back = invoke("rollback", first)
            self.assertEqual(0, rollback_code)
            self.assertIn("quickshell", rolled_back["data"]["active_targets"])

    def test_cli_setup_requires_confirmation(self) -> None:
        completed = subprocess.run([str(THEMES / "bin/themectl"), "setup", "gtk", "--json"], cwd=REPOSITORY, check=False, capture_output=True, text=True)
        self.assertEqual(2, completed.returncode)
        self.assertFalse(json.loads(completed.stdout)["ok"])


if __name__ == "__main__":
    unittest.main()


class GtkLoaderAdoptionTests(unittest.TestCase):
    def test_setup_adopts_foreign_loader_and_records_prior_state(self):
        previous = tempfile.TemporaryDirectory()
        self.addCleanup(previous.cleanup)
        root = Path(previous.name)
        environment = mock.patch.dict(os.environ, {
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"),
        })
        foreign_dir = root / "foreign" / "gtk-3.0"
        foreign_dir.mkdir(parents=True)
        foreign_css = foreign_dir / "gtk.css"
        foreign_css.write_text("/* foreign checkout loader */\n", encoding="utf-8")
        with environment:
            gtk3 = Path(os.environ["XDG_CONFIG_HOME"]) / "gtk-3.0"
            gtk3.mkdir(parents=True, exist_ok=True)
            (gtk3 / "gtk.css").symlink_to(foreign_css)

            setup_gtk()

            integration = json.loads((Path(os.environ["XDG_STATE_HOME"]) / "blox/theme/integration/gtk-loaders.json").read_text(encoding="utf-8"))
            record = integration["loaders"]["3"]["gtk.css"]
            self.assertEqual(record["kind"], "symlink")
            self.assertEqual(Path(record["target"]).read_text(encoding="utf-8"), "/* foreign checkout loader */\n")
            live = os.readlink(gtk3 / "gtk.css")
            # The adopted link now targets the Blox-managed loader source,
            # whether run from a checkout or the installed tree.
            self.assertTrue(live.startswith(str(repository_root())), live)

            # A second setup snapshots the immediate prior state (the link
            # the first setup wrote), keeping the cycle stable.
            setup_gtk()
            integration = json.loads((Path(os.environ["XDG_STATE_HOME"]) / "blox/theme/integration/gtk-loaders.json").read_text(encoding="utf-8"))
            second = integration["loaders"]["3"]["gtk.css"]
            self.assertEqual(second["kind"], "symlink")
            self.assertTrue(Path(second["target"]).is_absolute())
