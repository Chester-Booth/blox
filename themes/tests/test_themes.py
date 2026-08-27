from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import DEFAULT_BAR_ITEMS, contrast_ratio, dependency_checks, derive_ansi, derive_shape, list_themes, load_theme, render_manifest, render_theme, resolve_wallpaper_path, resolved_bar_items, schema_errors, themes_dir, validate_theme


def run_cli(*arguments: str, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(THEMES / "bin/themectl"), *arguments], cwd=REPOSITORY, env=environment, capture_output=True, text=True, check=False)


class ThemeSchemaTests(unittest.TestCase):
    def test_canonical_theme_is_valid(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        # Machine assets (personal GTK base theme, icons, cursor base) are
        # warnings outside an apply; canonical validity must not depend on
        # the machine running the tests.
        result = validate_theme(theme, dependency_gate=False)
        self.assertEqual([], result.errors)

    def test_source_themes_use_proportional_nerd_fonts_for_panels(self) -> None:
        for path in sorted((THEMES / "builtin").glob("*.json")):
            with self.subTest(theme=path.stem):
                theme = json.loads(path.read_text(encoding="utf-8"))
                self.assertTrue(
                    theme["fonts"]["panel"].endswith("Nerd Font Propo"),
                    theme["fonts"]["panel"],
                )

    def test_builtin_library_contains_only_the_showcase_themes(self) -> None:
        ids = {path.stem for path in (THEMES / "builtin").glob("*.json")}
        self.assertEqual({
            "catppuccin-frappe", "catppuccin-latte", "catppuccin-macchiato", "catppuccin-mocha",
            "dracula", "gruvbox-dark", "gruvbox-light", "kanagawa", "nord",
            "solarized-dark", "solarized-light", "tokyo-night",
        }, ids)

    def test_configured_application_data_root_takes_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            schema = root / "schema/theme.schema.json"
            schema.parent.mkdir(parents=True)
            schema.write_text("{}", encoding="utf-8")
            with mock.patch.dict(os.environ, {"BLOX_DATA_DIR": str(root)}):
                self.assertEqual(root, themes_dir())

    def test_invalid_fixtures_fail_schema_validation(self) -> None:
        fixtures = THEMES / "tests/fixtures"
        for fixture in (fixtures / "invalid-colour.json", fixtures / "unknown-field.json"):
            with self.subTest(fixture=fixture.name):
                theme = json.loads(fixture.read_text(encoding="utf-8"))
                self.assertTrue(schema_errors(theme))

    def test_invalid_fixtures_have_documented_exit_code(self) -> None:
        fixtures = THEMES / "tests/fixtures"
        for fixture in (fixtures / "invalid-colour.json", fixtures / "unknown-field.json"):
            with self.subTest(fixture=fixture.name):
                completed = run_cli("validate", str(fixture), "--json")
                self.assertEqual(3, completed.returncode)
                self.assertEqual("error", json.loads(completed.stdout)["status"])

    def test_contrast_failure_is_a_warning(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["colours"]["foreground"] = theme["colours"]["background"]
        result = validate_theme(theme, check_dependencies=False)
        self.assertEqual([], result.errors)
        self.assertTrue(any("contrast" in warning for warning in result.warnings))

    def test_gtk_override_source_requires_values(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["gtk"]["colour_source"] = "override"
        result = validate_theme(theme, check_dependencies=False)
        self.assertTrue(any("overrides.gtk" in error for error in result.errors))
        theme["overrides"] = {"gtk": {"accent": "#abcdef"}}
        self.assertFalse(any("overrides.gtk" in error for error in validate_theme(theme, check_dependencies=False).errors))

    def test_low_contrast_gtk_override_is_a_warning(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["overrides"] = {"gtk": {"foreground": theme["colours"]["background"]}}
        result = validate_theme(theme, check_dependencies=False)
        self.assertEqual([], result.errors)
        self.assertTrue(any("GTK override" in warning for warning in result.warnings))

    def test_schema_boundaries_and_unknown_nested_fields(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        mutations = {
            "future schema": lambda theme: theme.update(schema_version=2),
            "invalid id": lambda theme: theme.update(id="Invalid ID"),
            "unknown target": lambda theme: theme["targets"].update(unknown=True),
            "unknown widget profile": lambda theme: theme.update(widgets={"profile": "arbitrary"}),
            "missing target": lambda theme: theme["targets"].pop("kitty"),
            "small font": lambda theme: theme["fonts"].update(terminal_size=5),
            "duplicate cursor size": lambda theme: theme["cursor"].update(sizes=[24, 24]),
            "large cursor": lambda theme: theme["cursor"].update(sizes=[97]),
            "unknown override": lambda theme: theme.update(overrides={"ansi": {"color16": "#ffffff"}}),
            "short generator digest": lambda theme: theme.update(generator={"backend": "test", "version": "1", "wallpaper_sha256": "abc"}),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                theme = copy.deepcopy(source)
                mutate(theme)
                self.assertTrue(schema_errors(theme))

    def test_shape_bounds_fail_closed(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        mutations = {
            "negative radius": lambda shape: shape.update(radius_scale=-0.01),
            "large radius": lambda shape: shape.update(radius_scale=2.01),
            "small density": lambda shape: shape.update(density_scale=0.74),
            "large density": lambda shape: shape.update(density_scale=1.51),
            "negative gap": lambda shape: shape.update(window_gap=-1),
            "large gap": lambda shape: shape.update(window_gap=31),
            "fractional gap": lambda shape: shape.update(window_gap=2.5),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                theme = copy.deepcopy(source)
                mutate(theme["shape"])
                self.assertTrue(schema_errors(theme))

    def test_widget_schema_rejects_invalid_identifiers_and_unknown_fields(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        widget = {
            "id": "clock",
            "name": "Clock",
            "type": "clock",
            "enabled": True,
            "content_command": "tty-clock -c",
            "left_click_command": "",
            "right_click_command": "",
            "interval_ms": 1000,
            "visibility": "always",
            "anchor": "top-left",
            "offset_x": 20,
            "offset_y": 20,
            "width": 0,
            "height": 0,
            "shape": "auto",
            "options": {},
        }
        mutations = {
            "invalid id": lambda value: value.update(id="Invalid Widget ID"),
            "unknown field": lambda value: value.update(unknown=True),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                theme = copy.deepcopy(source)
                candidate = copy.deepcopy(widget)
                mutate(candidate)
                theme["widgets"]["items"] = [candidate]
                self.assertTrue(schema_errors(theme))

    def test_dependency_checks_respect_target_enablement(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        theme = copy.deepcopy(source)
        for target in theme["targets"]:
            theme["targets"][target] = False
        theme["wallpaper"]["path"] = "/missing"
        theme["gtk"]["base_theme"] = "Missing-GTK"
        theme["icons"]["theme"] = "Missing-Icons"
        theme["cursor"].update(mode="installed", base="Missing-Cursor")
        with mock.patch("blox_theme.cursor.toolchain_check", return_value={"ok": False, "recovery": "themectl setup cursor --yes"}):
            result = dependency_checks(theme)
        self.assertEqual([], result.errors)
        self.assertEqual([], result.warnings)

        expected = {"wallpaper": "wallpaper", "gtk": "GTK base theme", "cursor": "cursor base"}
        for target, message in expected.items():
            with self.subTest(target=target):
                candidate = copy.deepcopy(theme)
                candidate["targets"][target] = True
                self.assertTrue(any(message in error for error in dependency_checks(candidate).errors))

    def test_builtin_data_relative_wallpaper_paths_resolve_for_checks_and_rendering(self) -> None:
        path, source = load_theme("catppuccin-mocha")
        theme = copy.deepcopy(source)
        theme["wallpaper"]["path"] = "schema/theme.schema.json"

        result = dependency_checks(theme, source_path=path)
        self.assertFalse(any("wallpaper does not exist" in error for error in result.errors))
        files, _ = render_theme(theme, path)
        wallpaper = json.loads(files["hypr/wallpaper.json"])
        self.assertEqual(str(THEMES / "schema/theme.schema.json"), wallpaper["path"])
        self.assertEqual("schema/theme.schema.json", theme["wallpaper"]["path"])

    def test_absolute_and_home_relative_wallpaper_references_are_rendered_unchanged(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        for reference in ("/tmp/wallpaper.webp", "~/Pictures/wallpaper.webp"):
            with self.subTest(reference=reference):
                theme = copy.deepcopy(source)
                theme["wallpaper"]["path"] = reference
                wallpaper = json.loads(render_theme(theme)[0]["hypr/wallpaper.json"])
                self.assertEqual(reference, wallpaper["path"])

    def test_missing_generated_cursor_is_a_warning(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["cursor"]["base"] = "Definitely-Missing-Cursor"
        with mock.patch("blox_theme.cursor.toolchain_check", return_value={"ok": False, "recovery": "themectl setup cursor --yes"}):
            result = dependency_checks(theme)
        self.assertFalse(any("cursor base" in error for error in result.errors))
        self.assertTrue(any("cursor toolchain" in warning for warning in result.warnings))

class RendererTests(unittest.TestCase):
    def setUp(self) -> None:
        self.path, self.theme = load_theme("catppuccin-mocha")

    def test_render_matches_golden_hashes(self) -> None:
        files, _ = render_theme(self.theme)
        # Repository-absolute paths are normalised so golden hashes stay
        # portable across checkouts and install prefixes.
        actual = {
            name: hashlib.sha256(content.replace(str(THEMES), "<themes>").encode()).hexdigest()
            for name, content in files.items()
        }
        expected = json.loads((THEMES / "tests/golden/catppuccin-mocha.sha256.json").read_text(encoding="utf-8"))
        self.assertEqual(expected, actual)

    def test_render_is_deterministic(self) -> None:
        first_files, first_warnings = render_theme(self.theme)
        second_files, second_warnings = render_theme(self.theme)
        self.assertEqual(first_files, second_files)
        self.assertEqual(first_warnings, second_warnings)
        self.assertEqual(render_manifest(self.path, self.theme, first_files), render_manifest(self.path, self.theme, second_files))

    def test_rendered_formats_are_valid_and_complete(self) -> None:
        files, _ = render_theme(self.theme)
        quickshell = json.loads(files["quickshell/theme.json"])
        self.assertEqual(self.theme["colours"], quickshell["colours"])
        self.assertEqual(self.theme["terminal"], quickshell["terminal"])
        self.assertEqual(self.theme["shape"], quickshell["shape"])
        self.assertEqual(derive_ansi(self.theme), quickshell["ansi"])
        wallpaper = json.loads(files["hypr/wallpaper.json"])
        self.assertEqual(str(resolve_wallpaper_path(self.theme["wallpaper"]["path"], self.path)), wallpaper["path"])
        self.assertEqual(self.theme["wallpaper"]["fit"], wallpaper["fit"])
        for name, colour in derive_ansi(self.theme).items():
            self.assertIn(f"{name} {colour}", files["kitty/theme.conf"])
        self.assertIn(f"inactive_tab_background {self.theme['colours']['background']}", files["kitty/theme.conf"])
        self.assertIn("tab_bar_background none", files["kitty/theme.conf"])
        phase7 = {
            "hyprland/theme.lua", "hyprland/hyprtoolkit.conf", "hyprlock/theme.conf", "btop/theme.theme",
            "micro/blox-theme.micro", "glow/style.json",
            "cursor-editor/settings.json", "stylus/blox-system.user.css",
            "powerlevel10k/theme.zsh",
            "widgets/profile.json",
        }
        self.assertTrue(phase7.issubset(files))
        self.assertIn("code/settings.json", files)

    def test_shape_derivation_drives_quickshell_hyprland_and_gtk(self) -> None:
        cases = (
            (0, 0.75, None, 0, 0),
            (0.65, 1.0, None, 8, 5),
            (1.25, 1.5, None, 15, 15),
            (2, 1.0, 30, 24, 30),
        )
        for radius_scale, density_scale, window_gap, expected_radius, expected_gap in cases:
            with self.subTest(radius=radius_scale, density=density_scale, gap=window_gap):
                theme = copy.deepcopy(self.theme)
                theme["shape"] = {"radius_scale": radius_scale, "density_scale": density_scale}
                if window_gap is not None:
                    theme["shape"]["window_gap"] = window_gap

                derived = derive_shape(theme)
                self.assertEqual(expected_radius, derived["hyprland_rounding"])
                self.assertEqual(expected_radius, derived["gtk_radius"])
                self.assertEqual(expected_gap, derived["hyprland_gap"])

                files, _ = render_theme(theme)
                self.assertEqual(theme["shape"], json.loads(files["quickshell/theme.json"])["shape"])
                self.assertIn(f"gaps_in = {expected_gap},", files["hyprland/theme.lua"])
                self.assertIn(f"gaps_out = {expected_gap},", files["hyprland/theme.lua"])
                self.assertIn(f"rounding = {expected_radius},", files["hyprland/theme.lua"])
                self.assertIn(f"border-radius: {expected_radius}px;", files["gtk/gtk-3.0/gtk.css"])
                self.assertIn(f"border-radius: {expected_radius}px;", files["gtk/gtk-4.0/gtk.css"])

    def test_code_target_renders_complete_extension(self) -> None:
        self.theme["targets"]["code"] = True
        files, _ = render_theme(self.theme)
        code_settings = json.loads(files["code/settings.json"])
        self.assertEqual(self.theme["fonts"]["mono"], code_settings["editor.fontFamily"])
        self.assertEqual("Blox Dark 2026", code_settings["workbench.colorTheme"])
        self.assertNotIn("workbench.colorCustomizations", code_settings)
        package = json.loads(files["code/package.json"])
        self.assertEqual("./themes/blox-dark-2026.json", package["contributes"]["themes"][0]["path"])
        code_theme = json.loads(files["code/themes/blox-dark-2026.json"])
        self.assertIn("sideBarSectionHeader.background", code_theme["colors"])
        self.assertTrue(code_theme["semanticHighlighting"])
        obsidian = json.loads(files["obsidian/style-settings.json"])
        self.assertEqual(self.theme["colours"]["background"], obsidian["minimal-style@@bg1@@dark"])
        self.assertEqual(self.theme["colours"]["accent"], obsidian["minimal-style@@ax1@@dark"])
        shell = json.loads(files["quickshell/theme.json"])["shell"]
        expected_shell = self.theme.get("shell", {})
        self.assertEqual(expected_shell.get("bar", {}).get("position", "left"), shell["bar"]["position"])
        expected_bar_items = resolved_bar_items(expected_shell.get("bar"))
        self.assertEqual(
            {item["id"]: item for item in expected_bar_items},
            {item["id"]: item for item in shell["bar"]["items"]},
        )
        self.assertEqual(expected_shell.get("osd", {}).get("position", "top-left"), shell["osd"]["position"])
        self.assertEqual(expected_shell.get("notifications", {}).get("position", "bottom-right"), shell["notifications"]["position"])
        self.assertIn("workbench.colorCustomizations", json.loads(files["cursor-editor/settings.json"]))
        self.assertIn("@-moz-document", files["stylus/blox-system.user.css"])
        self.assertIn('color-link default "#cdd6f4"', files["micro/blox-theme.micro"])
        self.assertNotIn('color-link default "#cdd6f4,#242424"', files["micro/blox-theme.micro"])
        hyprtoolkit = files["hyprland/hyprtoolkit.conf"]
        self.assertIn("background = 0xFF1E1E2E", hyprtoolkit)
        self.assertIn("accent = 0xFF89B4FA", hyprtoolkit)
        self.assertIn("icon_theme = Adwaita", hyprtoolkit)
        self.assertIn("font_family = Outfit", hyprtoolkit)

    def test_bar_item_overrides_are_rendered_with_complete_registry(self) -> None:
        self.theme["shell"] = {
            "bar": {"position": "bottom", "items": [
                {"id": "clock", "enabled": False, "region": "end", "order": 7},
                {"id": "wifi", "enabled": True, "region": "start", "order": 0},
            ]},
            "osd": {"position": "centre-bottom", "offset_x": 0, "offset_y": 0},
            "notifications": {"position": "top-right", "offset_x": 0, "offset_y": 0},
        }
        self.assertEqual([], schema_errors(self.theme))
        shell = json.loads(render_theme(self.theme)[0]["quickshell/theme.json"])["shell"]
        items = {item["id"]: item for item in shell["bar"]["items"]}
        self.assertEqual(len(DEFAULT_BAR_ITEMS), len(items))
        self.assertEqual("end", items["clock"]["region"])
        self.assertFalse(items["clock"]["enabled"])
        end_items = sorted(
            (item for item in items.values() if item["region"] == "end"),
            key=lambda item: item["order"],
        )
        self.assertEqual("tray", end_items[0]["id"])
        self.assertEqual("start", items["wifi"]["region"])
        self.assertTrue(items["power"]["enabled"])
        self.assertEqual("toggle", items["battery"]["display"])
        self.assertEqual("hidden", items["touchpad"]["region"])
        for item_id in ("privacy", "touchpad", "fan", "gpu"):
            self.assertEqual("normal", items[item_id]["visibility"])

    def test_bar_item_schema_rejects_unknown_items_and_regions(self) -> None:
        base_shell = {
            "bar": {"position": "left", "items": []},
            "osd": {"position": "top-left", "offset_x": 0, "offset_y": 0},
            "notifications": {"position": "bottom-right", "offset_x": 0, "offset_y": 0},
        }
        for item in (
            {"id": "unknown", "enabled": True, "region": "start", "order": 0},
            {"id": "power", "enabled": True, "region": "middle", "order": 0},
        ):
            candidate = copy.deepcopy(self.theme)
            candidate["shell"] = copy.deepcopy(base_shell)
            candidate["shell"]["bar"]["items"] = [item]
            self.assertTrue(schema_errors(candidate))

    def test_battery_display_mode_is_validated_and_rendered(self) -> None:
        self.theme["shell"] = {
            "bar": {"position": "left", "items": [
                {"id": "battery", "enabled": True, "region": "end", "order": 0, "display": "numeric"},
            ]},
            "osd": {"position": "top-left", "offset_x": 0, "offset_y": 0},
            "notifications": {"position": "bottom-right", "offset_x": 0, "offset_y": 0},
        }
        self.assertEqual([], schema_errors(self.theme))
        shell = json.loads(render_theme(self.theme)[0]["quickshell/theme.json"])["shell"]
        items = {item["id"]: item for item in shell["bar"]["items"]}
        self.assertEqual("numeric", items["battery"]["display"])

        self.theme["shell"]["bar"]["items"][0]["display"] = "both"
        self.assertTrue(schema_errors(self.theme))

    def test_runtime_item_visibility_is_validated_and_rendered(self) -> None:
        self.theme["shell"] = {
            "bar": {"position": "left", "items": [
                {"id": "touchpad", "enabled": True, "region": "end", "order": 0, "visibility": "always"},
            ]},
            "osd": {"position": "top-left", "offset_x": 0, "offset_y": 0},
            "notifications": {"position": "bottom-right", "offset_x": 0, "offset_y": 0},
        }
        self.assertEqual([], schema_errors(self.theme))
        shell = json.loads(render_theme(self.theme)[0]["quickshell/theme.json"])["shell"]
        items = {item["id"]: item for item in shell["bar"]["items"]}
        self.assertEqual("always", items["touchpad"]["visibility"])

        self.theme["shell"]["bar"]["items"][0]["visibility"] = "sometimes"
        self.assertTrue(schema_errors(self.theme))

    def test_legacy_tray_override_migrates_to_application_tray(self) -> None:
        self.theme["shell"] = {
            "bar": {"position": "left", "items": [
                {"id": "tray", "enabled": False, "region": "hidden", "order": 9},
            ]},
            "osd": {"position": "top-left", "offset_x": 0, "offset_y": 0},
            "notifications": {"position": "bottom-right", "offset_x": 0, "offset_y": 0},
        }
        shell = json.loads(render_theme(self.theme)[0]["quickshell/theme.json"])["shell"]
        items = {item["id"]: item for item in shell["bar"]["items"]}
        self.assertTrue(items["tray"]["enabled"])
        self.assertEqual("end", items["tray"]["region"])
        self.assertFalse(items["application-tray"]["enabled"])
        self.assertEqual(
            min(item["order"] for item in items.values() if item["region"] == "hidden"),
            items["application-tray"]["order"],
        )

    def test_application_tray_is_pinned_furthest_from_the_tray_arrow(self) -> None:
        for tray_region, tray_order, expected_boundary in (
            ("start", 99, "last"),
            ("end", 0, "first"),
            ("centre", -1, "first"),
            ("centre", 99, "last"),
        ):
            with self.subTest(tray_region=tray_region, tray_order=tray_order):
                items = resolved_bar_items({
                    "position": "top",
                    "items": [
                        {"id": "tray", "enabled": True, "region": tray_region, "order": tray_order},
                        {"id": "application-tray", "enabled": True, "region": "start", "order": 2},
                    ],
                })
                application_tray = next(item for item in items if item["id"] == "application-tray")
                hidden_ids = [
                    item["id"]
                    for item in sorted(
                        (item for item in items if item["region"] == "hidden"),
                        key=lambda item: item["order"],
                    )
                ]
                self.assertEqual("hidden", application_tray["region"])
                self.assertEqual(
                    "application-tray",
                    hidden_ids[0] if expected_boundary == "first" else hidden_ids[-1],
                )

    def test_shell_offsets_are_not_artificially_limited(self) -> None:
        self.theme["shell"] = {
            "bar": {"position": "left", "items": []},
            "osd": {"position": "top-left", "offset_x": 12000, "offset_y": -12000},
            "notifications": {"position": "bottom-right", "offset_x": -12000, "offset_y": 12000},
        }
        self.assertEqual([], schema_errors(self.theme))

    def test_bar_item_validation_rejects_duplicate_ids(self) -> None:
        self.theme["shell"] = {
            "bar": {"position": "left", "items": [
                {"id": "power", "enabled": True, "region": "start", "order": 0},
                {"id": "power", "enabled": False, "region": "end", "order": 1},
            ]},
            "osd": {"position": "top-left", "offset_x": 0, "offset_y": 0},
            "notifications": {"position": "bottom-right", "offset_x": 0, "offset_y": 0},
        }
        result = validate_theme(self.theme, check_dependencies=False)
        self.assertTrue(any("duplicate item ids" in error for error in result.errors))

    def test_phase7_targets_are_isolated(self) -> None:
        target_files = {
            "hyprland": ["hyprland/hyprtoolkit.conf", "hyprland/theme.lua"],
            "hyprlock": "hyprlock/theme.conf",
            "btop": "btop/theme.theme", "micro": "micro/blox-theme.micro",
            "glow": "glow/style.json", "code": ["code/package.json", "code/settings.json", "code/themes/blox-dark-2026.json"],
            "helium": "helium/manifest.json",
            "cursor_editor": "cursor-editor/settings.json", "stylus": "stylus/blox-system.user.css",
            "powerlevel10k": "powerlevel10k/theme.zsh",
            "widgets": "widgets/profile.json",
            "chromium": "chromium/manifest.json",
        }
        for target, expected in target_files.items():
            with self.subTest(target=target):
                theme = copy.deepcopy(self.theme)
                for key in theme["targets"]:
                    theme["targets"][key] = key == target
                files, _ = render_theme(theme)
                self.assertEqual(expected if isinstance(expected, list) else [expected], list(files))

    def test_ansi_override_is_target_local(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["overrides"] = {"ansi": {"color1": "#010203"}}
        files, _ = render_theme(theme)
        self.assertEqual("#010203", json.loads(files["quickshell/theme.json"])["ansi"]["color1"])
        self.assertIn("color1 #010203", files["kitty/theme.conf"])
        self.assertEqual(self.theme["colours"], theme["colours"])

    def test_generated_gtk_outputs_settings_css_and_limitations(self) -> None:
        files, _ = render_theme(self.theme)
        metadata = json.loads(files["gtk/metadata.json"])
        gtk4 = files["gtk/gtk-4.0/gtk.css"]
        self.assertTrue(metadata["generated_css"])
        self.assertEqual("partial-user-css", metadata["libadwaita_support"])
        self.assertIn("gtk-theme-name=Graphite-Dark-compact", files["gtk/gtk-3.0/settings.ini"])
        self.assertIn("gtk-font-name=Outfit 11", files["gtk/gtk-4.0/settings.ini"])
        self.assertIn("@define-color blox_accent #89b4fa;", files["gtk/gtk-3.0/gtk.css"])
        self.assertIn("switch:checked", gtk4)
        self.assertIn("\nwindow {\n", gtk4)
        self.assertNotIn("\n.background {\n", gtk4)

    def test_gtk_target_keeps_helium_tabs_distinct(self) -> None:
        for path in sorted((THEMES / "builtin").glob("*.json")):
            with self.subTest(theme=path.stem):
                _, theme = load_theme(path.stem)
                theme["targets"]["gtk"] = False
                theme["targets"]["helium"] = True
                files, _ = render_theme(theme)
                manifest = json.loads(files["helium/manifest.json"])
                colours = manifest["theme"]["colors"]
                self.assertEqual(3, manifest["manifest_version"])
                self.assertRegex(manifest["key"], r"^[A-Za-z0-9+/]+=*$")
                self.assertNotEqual(colours["frame"], colours["toolbar"])
                self.assertEqual(colours["frame"], colours["frame_inactive"])
                self.assertEqual(colours["toolbar"], [int(theme["colours"]["background"][index:index + 2], 16) for index in (1, 3, 5)])
                for frame in (colours["frame"], colours["toolbar"]):
                    value = "#" + "".join(f"{channel:02x}" for channel in frame)
                    self.assertGreaterEqual(contrast_ratio(value, theme["colours"]["foreground"]), 4.5)

    def test_helium_inactive_tabs_use_surface_alt(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["targets"]["gtk"] = False
        theme["targets"]["helium"] = True
        manifest = json.loads(render_theme(theme)[0]["helium/manifest.json"])
        inactive = manifest["theme"]["colors"]["frame"]
        expected = [int(theme["colours"]["surface_alt"][index:index + 2], 16) for index in (1, 3, 5)]
        self.assertEqual(expected, inactive)

    def test_helium_does_not_consume_gtk_overrides(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["targets"]["gtk"] = False
        theme["targets"]["helium"] = True
        theme["overrides"] = {"gtk": {"background": "#010203", "accent": "#abcdef"}}
        manifest = json.loads(render_theme(theme)[0]["helium/manifest.json"])
        self.assertEqual([30, 30, 46], manifest["theme"]["colors"]["toolbar"])
        self.assertEqual([137, 180, 250], manifest["theme"]["colors"]["button_background"])

    def test_chromium_uses_a_separate_manifest_with_the_shared_mapping(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["targets"]["helium"] = False
        theme["targets"]["chromium"] = True
        files, _ = render_theme(theme)
        self.assertNotIn("helium/manifest.json", files)
        manifest = json.loads(files["chromium/manifest.json"])
        self.assertEqual("Blox Chromium theme", manifest["name"])
        self.assertEqual(3, manifest["manifest_version"])
        self.assertNotEqual(manifest["theme"]["colors"]["frame"], manifest["theme"]["colors"]["toolbar"])

    def test_installed_gtk_mode_emits_no_generated_css(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["gtk"].update(mode="installed", base_theme="Adwaita")
        files, _ = render_theme(theme)
        self.assertNotIn("gtk/gtk-3.0/gtk.css", files)
        self.assertNotIn("gtk/gtk-4.0/gtk.css", files)
        self.assertNotIn("helium/manifest.json", files)
        self.assertIn("gtk-theme-name=Adwaita", files["gtk/gtk-3.0/settings.ini"])
        self.assertFalse(json.loads(files["gtk/metadata.json"])["generated_css"])

    def test_light_gtk_mode_emits_light_preference(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["variant"] = "light"
        files, _ = render_theme(theme)
        self.assertIn("gtk-application-prefer-dark-theme=0", files["gtk/gtk-3.0/settings.ini"])

    def test_gtk_override_does_not_feed_back_into_other_targets(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["overrides"] = {"gtk": {"background": "#010203", "accent": "#abcdef"}}
        files, _ = render_theme(theme)
        self.assertIn("@define-color blox_bg #010203;", files["gtk/gtk-3.0/gtk.css"])
        self.assertIn("@define-color blox_accent #abcdef;", files["gtk/gtk-4.0/gtk.css"])
        self.assertEqual(self.theme["colours"], json.loads(files["quickshell/theme.json"])["colours"])

    def test_generated_gtk_css_parses_in_both_toolkits(self) -> None:
        files, _ = render_theme(self.theme)
        with tempfile.TemporaryDirectory() as temporary:
            for toolkit, name in (("gtk3", "gtk/gtk-3.0/gtk.css"), ("gtk4", "gtk/gtk-4.0/gtk.css")):
                with self.subTest(toolkit=toolkit):
                    path = Path(temporary) / f"{toolkit}.css"
                    path.write_text(files[name], encoding="utf-8")
                    completed = subprocess.run([sys.executable, str(THEMES / "tests/helpers/gtk_probe.py"), toolkit, "--css", str(path)], cwd=REPOSITORY, capture_output=True, text=True, check=False)
                    self.assertEqual(0, completed.returncode, completed.stderr)
                    self.assertEqual([], json.loads(completed.stdout)["errors"])

    def test_disabled_targets_are_not_rendered(self) -> None:
        theme = copy.deepcopy(self.theme)
        for target in theme["targets"]:
            theme["targets"][target] = False
        files, warnings = render_theme(theme)
        self.assertEqual({}, files)
        self.assertEqual([], warnings)

    def test_in_memory_commands_do_not_create_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["XDG_STATE_HOME"] = temporary
            for command in ("render", "preview", "diff", "doctor"):
                completed = run_cli(command, *([] if command == "doctor" else ["catppuccin-mocha"]), "--json", environment=environment)
                # Doctor reports the live machine and may exit non-zero when
                # its checks fail; the contract here is a parseable envelope
                # and no state written, on any machine.
                json.loads(completed.stdout)
            self.assertEqual([], list(Path(temporary).iterdir()))

    def test_explicit_output_contains_only_rendered_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "render"
            completed = run_cli("render", "catppuccin-mocha", "--output", str(output), "--json")
            self.assertEqual(0, completed.returncode, completed.stderr or completed.stdout)
            files = sorted(str(path.relative_to(output)) for path in output.rglob("*") if path.is_file())
            expected = sorted([*render_theme(self.theme)[0], "manifest.json"])
            self.assertEqual(expected, files)


class CliContractTests(unittest.TestCase):
    def test_detached_widgets_export_import_round_trip_and_validation(self) -> None:
        widgets = {
            "profile": "compact",
            "items": [{
                "id": "clock",
                "name": "Clock",
                "type": "clock",
                "enabled": True,
                "content_command": "tty-clock -c",
                "left_click_command": "",
                "right_click_command": "",
                "interval_ms": 1000,
                "visibility": "always",
                "anchor": "top-right",
                "offset_x": 24,
                "offset_y": 32,
                "width": 320,
                "height": 180,
                "shape": "rounded",
                "options": {"seconds": True},
            }],
        }
        with tempfile.TemporaryDirectory() as temporary:
            exported = Path(temporary) / "widgets.json"
            result = run_cli("widgets-export", json.dumps(widgets), "--output", str(exported), "--json")
            self.assertEqual(0, result.returncode, result.stderr)
            document = json.loads(exported.read_text(encoding="utf-8"))
            self.assertEqual({"schema_version": 1, "kind": "blox-widgets", "widgets": widgets}, document)

            imported = run_cli("widgets-import", str(exported), "--json")
            self.assertEqual(0, imported.returncode, imported.stderr)
            safe_widgets = copy.deepcopy(widgets)
            for field in ("content_command", "left_click_command", "right_click_command"):
                safe_widgets["items"][0][field] = ""
            self.assertEqual(safe_widgets, json.loads(imported.stdout)["data"])
            self.assertTrue(json.loads(imported.stdout)["warnings"])

            malformed = Path(temporary) / "not-widgets.json"
            malformed.write_text(json.dumps({"schema_version": 1, "widgets": widgets}), encoding="utf-8")
            rejected_document = run_cli("widgets-import", str(malformed), "--json")
            self.assertEqual(3, rejected_document.returncode)
            self.assertFalse(json.loads(rejected_document.stdout)["ok"])

            invalid_widgets = copy.deepcopy(widgets)
            invalid_widgets["items"][0]["id"] = "Invalid Widget ID"
            rejected_widget = run_cli("widgets-export", json.dumps(invalid_widgets), "--output", str(Path(temporary) / "invalid.json"), "--json")
            self.assertEqual(3, rejected_widget.returncode)
            self.assertFalse(json.loads(rejected_widget.stdout)["ok"])

    def test_theme_picker_exposes_widget_tab_editor_and_detached_io(self) -> None:
        modules = REPOSITORY / "shell/modules"
        widgets = (modules / "ThemePickerWidgets.qml").read_text(encoding="utf-8")
        modal = (modules / "ThemePickerModal.qml").read_text(encoding="utf-8")
        dialogs = (modules / "ThemePickerFileDialogs.qml").read_text(encoding="utf-8")
        for source, expected in (
            (widgets, 'text: "Widgets"'),
            (widgets, 'text: "New Widget"'),
            (widgets, 'Import"'),
            (widgets, 'Export"'),
            (modal, 'text: "Save widget"'),
            (dialogs, 'id: widgetImportDialog'),
            (dialogs, 'id: widgetExportDialog'),
            (dialogs, 'controller.runApi("widgets-import"'),
            (dialogs, 'controller.runApi("widgets-export"'),
            (widgets, 'controller.openWidgetEditor(-1)'),
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, source)

    def test_bar_consumes_configured_regions_and_positions(self) -> None:
        source = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        theme = (REPOSITORY / "shell/shared/Theme.qml").read_text(encoding="utf-8")
        controller = (REPOSITORY / "shell/services/BarSurfaceController.qml").read_text(encoding="utf-8")
        delegate = (REPOSITORY / "shell/shared/BarItemDelegate.qml").read_text(encoding="utf-8")
        status_item = (REPOSITORY / "shell/shared/BarStatusItem.qml").read_text(encoding="utf-8")
        clock_item = (REPOSITORY / "shell/shared/BarClockItem.qml").read_text(encoding="utf-8")
        region = (REPOSITORY / "shell/shared/BarRegion.qml").read_text(encoding="utf-8")
        for expected in (
            'regionItems: Theme.barStartItems',
            'regionItems: Theme.barCentreItems',
            'regionItems: Theme.barEndItems',
            'Theme.barPosition === "left"',
            'Theme.barPosition === "right"',
            'Theme.barPosition === "top"',
            'Theme.barPosition === "bottom"',
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, source)
        self.assertIn('model: Theme.barHiddenItems.filter', source)
        for item_id in ("power", "notes", "workspaces", "clock", "battery", "notifications", "wifi", "sound", "privacy", "awake", "display", "bt", "updates", "fan", "gpu", "touchpad", "tray", "application-tray"):
            with self.subTest(item_id=item_id):
                self.assertIn(f'"{item_id}"', delegate)
        edge_trigger = source.split("MouseArea {", 1)[1].split("Rectangle {", 1)[0]
        self.assertIn("readonly property int triggerLength", edge_trigger)
        self.assertIn("width: barSurfaceController.horizontalBar ? triggerLength : 1", edge_trigger)
        self.assertIn("height: barSurfaceController.horizontalBar ? 1 : triggerLength", edge_trigger)
        self.assertIn("parent.width - width", edge_trigger)
        self.assertIn(": parent.height - height", edge_trigger)
        self.assertIn("barSurfaceController.enterEdgeTrigger()", edge_trigger)
        self.assertIn("barSurfaceController.leaveEdgeTrigger()", edge_trigger)
        self.assertIn('Theme.barPosition === "bottom"', edge_trigger)
        self.assertIn('Theme.barPosition === "right"', edge_trigger)
        self.assertIn("Hyprland.activeToplevel.lastIpcObject", controller)
        self.assertIn("Hyprland.refreshToplevels()", controller)
        self.assertIn("ToplevelManager.activeToplevel", controller)
        self.assertIn("activeWaylandToplevel.fullscreen", controller)
        self.assertIn("readonly property bool fullscreenActive", controller)
        self.assertIn("readonly property bool barPinnedOpen: barOpen && !fullscreenActive", controller)
        self.assertIn("exclusiveZone: barSurfaceController.barPinnedOpen", source)
        self.assertIn("visible: Theme.ready", source)
        self.assertIn("property bool ready: false", theme)
        self.assertIn("root.ready = defaults.ready", theme)
        self.assertIn("ThemeDefaults {", theme)
        self.assertEqual(6, source.count("BarRegion {"))
        self.assertIn("BarItemDelegate {", region)
        self.assertIn("Row {", region)
        self.assertIn("Column {", region)
        self.assertIn("root.regionItems.length - 1", region)
        self.assertIn("root.trayHost.registerTrayToggle(this, root.horizontal, root.region)", region)
        self.assertIn("root.trayHost.unregisterTrayToggle(this, root.horizontal)", region)
        self.assertIn("function publishNotificationPosition()", delegate)
        self.assertIn("anchors.fill: parent", delegate)
        self.assertIn("horizontal !== surfaceController.horizontalBar", delegate)
        self.assertIn("notificationController.panelY = mappedCentre", delegate)
        self.assertIn("onHorizontalChanged: publishNotificationPosition()", delegate)
        self.assertIn("function onHorizontalBarChanged()", delegate)
        self.assertIn('return content.network.json.icon || "󰤩"', status_item)
        self.assertNotIn('return content.network.json.icon || "󰔩"', status_item)
        self.assertIn("text: root.context.contentController.railClockText(root.context.horizontal)", clock_item)
        self.assertNotIn("text: root.context.contentController.railClockText()", clock_item)

    def test_bar_uses_explicit_domain_controllers(self) -> None:
        bar = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        surface = (REPOSITORY / "shell/services/BarSurfaceController.qml").read_text(encoding="utf-8")
        shell = (REPOSITORY / "shell/shell.qml").read_text(encoding="utf-8")
        delegate = (REPOSITORY / "shell/shared/BarItemDelegate.qml").read_text(encoding="utf-8")
        content = (REPOSITORY / "shell/services/BarContentController.qml").read_text(encoding="utf-8")

        for controller in (
            "BarContentController {",
            "WorkspaceController {",
            "NotificationController {",
            "BarSurfaceController {",
        ):
            with self.subTest(controller=controller):
                self.assertIn(controller, bar)

        for controller_property in (
            "required property BarContentController contentController",
            "required property WorkspaceController workspaceController",
            "required property NotificationController notificationController",
        ):
            with self.subTest(controller_property=controller_property):
                self.assertIn(controller_property, delegate)

        self.assertIn("BarStatus {", content)
        self.assertIn("BarActions {", content)
        self.assertIn("BarContent {", content)
        self.assertIn("required property BarSurfaceController surfaceController", delegate)
        self.assertIn("readonly property alias controller: barSurfaceController", bar)
        self.assertIn("target: bar.controller", shell)
        self.assertIn("function closePanel()", surface)
        self.assertNotIn("function closePanel()", bar)
        for relative_path in (
            "shared/BarItemContext.qml",
            "shared/BarItemDelegate.qml",
            "shared/BarRegion.qml",
            "popouts/BarBasicSurface.qml",
            "popouts/BarCalendarSurface.qml",
            "popouts/BarNotificationSurface.qml",
            "popouts/BarNotesSurface.qml",
            "popouts/BarPopouts.qml",
            "popouts/BarSystemSurfaces.qml",
            "popouts/BarTrayMenuSurface.qml",
        ):
            consumer = (
                REPOSITORY
                / "shell"
                / relative_path
            ).read_text(encoding="utf-8")
            with self.subTest(typed_surface_consumer=relative_path):
                self.assertIn(
                    "required property BarSurfaceController surfaceController",
                    consumer,
                )
                self.assertNotIn(
                    "required property var surfaceController",
                    consumer,
                )
        for stale_forwarder in (
            "property alias battery:",
            "function workspaceItems()",
            "function notificationStatus()",
            "function run(command)",
            "function railClockText(horizontal)",
        ):
            with self.subTest(stale_forwarder=stale_forwarder):
                self.assertNotIn(stale_forwarder, bar)

    def test_bar_items_and_popouts_use_domain_components(self) -> None:
        bar = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        shared = REPOSITORY / "shell/shared"
        delegate = (shared / "BarItemDelegate.qml").read_text(encoding="utf-8")
        rail_button = (shared / "RailButton.qml").read_text(encoding="utf-8")
        popouts = (REPOSITORY / "shell/popouts/BarPopouts.qml").read_text(encoding="utf-8")

        for component in (
            "BarLauncherItem {",
            "BarWorkspaceItem {",
            "BarClockItem {",
            "BarBatteryItem {",
            "BarNotificationItem {",
            "BarStatusItem {",
            "BarTrayItem {",
        ):
            with self.subTest(item_component=component):
                self.assertIn(component, delegate)

        for wrapper in (
            "BarLauncherItem.qml",
            "BarStatusItem.qml",
            "BarTrayItem.qml",
        ):
            source = (shared / wrapper).read_text(encoding="utf-8")
            with self.subTest(sized_wrapper=wrapper):
                self.assertIn("loader.item ? loader.item.implicitWidth : 0", source)
                self.assertIn("loader.item ? loader.item.implicitHeight : 0", source)
                self.assertNotIn("loader.item.width", source)
                self.assertNotIn("loader.item.height", source)

        for component in (
            "BarNotesSurface {",
            "BarTrayMenuSurface {",
            "BarCalendarSurface {",
            "BarSystemSurfaces {",
            "BarNotificationSurface {",
            "BarBasicSurface {",
        ):
            with self.subTest(popout_component=component):
                self.assertIn(component, popouts)

        for controller_property in (
            "required property BarSurfaceController surfaceController",
            "required property BarContentController contentController",
            "required property NotificationController notificationController",
            "required property UiState persistentState",
        ):
            with self.subTest(controller_property=controller_property):
                self.assertIn(controller_property, popouts)

        for stale_forwarder in (
            "property string openPanel:",
            "property var todoStatus",
            "property string systemTitle:",
            "property var notificationsModel:",
            "signal previousTodo()",
            "signal systemAction(",
            "signal basicAction(",
        ):
            with self.subTest(stale_forwarder=stale_forwarder):
                self.assertNotIn(stale_forwarder, popouts)

        self.assertNotIn("PanelRailButton {", delegate)
        self.assertNotIn("HoverPopupWindow {", popouts)
        self.assertIn("anchors.fill: parent", delegate)
        self.assertIn("implicitWidth: Theme.buttonSize", rail_button)
        self.assertIn("implicitHeight: visible ? Theme.buttonSize : 0", rail_button)
        self.assertIn("BarNotificationToastSurface {", bar)
        self.assertNotIn("NotificationToastStack {", bar)

    def test_active_window_title_is_registered_and_uses_hyprland_focus(self) -> None:
        shared = REPOSITORY / "shell/shared"
        qmldir = (shared / "qmldir").read_text(encoding="utf-8")
        item = (shared / "BarActiveWindowTitleItem.qml").read_text(encoding="utf-8")
        picker_model = (REPOSITORY / "shell/modules/ThemePickerBarModel.qml").read_text(encoding="utf-8")
        picker = (REPOSITORY / "shell/modules/ThemePickerAdvanced.qml").read_text(encoding="utf-8")
        self.assertIn("BarActiveWindowTitleItem 1.0 BarActiveWindowTitleItem.qml", qmldir)
        self.assertIn("activeWindow.workspace.id === Hyprland.focusedWorkspace.id", item)
        self.assertIn("activeWindowIsHere ? activeWindow.title", item)
        self.assertIn('titleOrientation === "inward"', item)
        self.assertIn('Theme.barPosition === "right"', item)
        self.assertIn('.replace(/ /g, "\\n\\n")', item)
        self.assertIn('root.staysHorizontal ? Text.WrapAnywhere : Text.NoWrap', item)
        self.assertIn('lineHeight: root.staysHorizontal ? 0.75 : 1', item)
        self.assertIn('clip: staysHorizontal', item)
        self.assertIn('itemConfig.titleLength === "full"', item)
        self.assertIn('showFullTitle ? preferredTitleExtent', item)
        self.assertIn('Math.min(configuredTitleExtent, root.context.maximumExtent)', item)
        region = (shared / "BarRegion.qml").read_text(encoding="utf-8")
        self.assertIn('modelData.id === "active-window-title" ? root.itemMaximumExtent(index)', region)
        self.assertIn('item.itemId === "active-window-title" ? Theme.buttonSize', region)
        self.assertIn('onVisibleChanged: root.extentsRevision++', region)
        self.assertIn('maximumExtent: root.maximumExtent', (shared / "BarItemDelegate.qml").read_text(encoding="utf-8"))
        bar = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        self.assertIn('configuredRail.horizontalContentEnd - configuredRail.horizontalContentStart', bar)
        self.assertIn('horizontalExpandedTray.x', bar)
        self.assertIn('barSurfaceController.trayOpen && horizontalTrayRegion === "end"', bar)
        self.assertIn('"active-window-title": "Active window title"', picker_model)
        self.assertIn('["inward", "outward", "horizontal"]', picker)
        self.assertIn('["left", "right"].indexOf(barPosition) >= 0', picker)
        self.assertIn('["flip inward", "flip outward", "stay horizontal"]', picker)

    def test_configured_battery_uses_live_status_without_cross_axis_jump(self) -> None:
        delegate = (REPOSITORY / "shell/shared/BarItemDelegate.qml").read_text(encoding="utf-8")
        battery = (REPOSITORY / "shell/shared/BarBatteryItem.qml").read_text(encoding="utf-8")
        clock = (REPOSITORY / "shell/shared/BarClockItem.qml").read_text(encoding="utf-8")
        self.assertEqual(2, battery.count("status: root.context.contentController.battery.json"))
        self.assertIn("implicitWidth: !contentVisible ? 0 : root.horizontal", delegate)
        self.assertIn("implicitHeight: !contentVisible ? 0 : !root.horizontal", delegate)
        self.assertNotIn("trayToggleItem = root", battery)
        self.assertIn("Math.ceil(horizontalClock.implicitWidth) + 16", clock)
        self.assertIn("id: horizontalClock", clock)
        self.assertIn("anchors.centerIn: parent", clock)
        vertical_clock = clock.split("id: verticalClock", 1)[1].split("Text {", 1)[0]
        self.assertIn("anchors.horizontalCenter: parent.horizontalCenter", vertical_clock)
        bar = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        self.assertIn("property var verticalTrayToggleItem", bar)
        self.assertIn("property var horizontalTrayToggleItem", bar)
        self.assertIn("readonly property point horizontalTrayPoint", bar)
        self.assertIn("while (ancestor && ancestor !== configuredRail)", bar)
        self.assertIn("ancestor = ancestor.parent", bar)

    def test_configured_battery_supports_display_modes(self) -> None:
        delegate = (REPOSITORY / "shell/shared/BarItemDelegate.qml").read_text(encoding="utf-8")
        battery = (REPOSITORY / "shell/shared/BarBatteryItem.qml").read_text(encoding="utf-8")
        self.assertIn('readonly property string batteryDisplay: itemConfig.display || "toggle"', delegate)
        self.assertIn('context.batteryDisplay !== "numeric"', battery)
        self.assertIn('context.batteryDisplay === "numeric"', battery)
        self.assertIn('root.context.batteryDisplay !== "toggle"', battery)
        self.assertIn('collapsible: root.context.batteryDisplay === "toggle"', battery)

    def test_configured_touchpad_toggles_and_refreshes_live_status(self) -> None:
        status_item = (REPOSITORY / "shell/shared/BarStatusItem.qml").read_text(encoding="utf-8")
        status = (REPOSITORY / "shell/services/BarStatus.qml").read_text(encoding="utf-8")
        touchpad = status_item.split("id: touchpadComponent", 1)[1]
        self.assertIn("root.context.contentController.touchpad.json.icon", touchpad)
        self.assertIn('"/osd/control.sh touchpad-toggle"', touchpad)
        self.assertIn("onHovered: root.context.surfaceController.trayEntered()", touchpad)
        self.assertIn("onExited: root.context.surfaceController.trayExited()", touchpad)
        self.assertIn('"/quickshell-touchpad-enabled"', status)
        self.assertIn("watchChanges: true", status)
        self.assertIn("onFileChanged: touchpad.refresh()", status)

    def test_runtime_application_tray_order_uses_the_tray_opening_direction(self) -> None:
        document = (REPOSITORY / "shell/shared/ThemeDocumentController.qml").read_text(encoding="utf-8")
        defaults = (REPOSITORY / "shell/shared/ThemeDefaults.qml").read_text(encoding="utf-8")
        self.assertIn("defaults.resolvedBarItems(data.bar && data.bar.items ? data.bar.items : [])", document)
        resolver = defaults.split("function resolvedBarItems(overrides)", 1)[1].split("function barItemsForRegion", 1)[0]
        self.assertIn("if (trayOpensForward(items))", resolver)
        self.assertIn("hidden.unshift(applicationTray)", resolver)
        self.assertIn("hidden.push(applicationTray)", resolver)

    def test_horizontal_popouts_use_screen_geometry_and_do_not_overlap(self) -> None:
        notifications = (REPOSITORY / "shell/popouts/BarNotificationSurface.qml").read_text(encoding="utf-8")
        geometry = (REPOSITORY / "shell/popouts/BarPopoutGeometry.qml").read_text(encoding="utf-8")
        system = (REPOSITORY / "shell/popouts/BarSystemSurfaces.qml").read_text(encoding="utf-8")
        self.assertIn("maxPopoutHeight: Math.min(720, Math.max(240, root.geometry.screenHeight - 16))", notifications)
        self.assertIn("function adjacentPopupX", geometry)
        self.assertIn("root.geometry.adjacentPopupX(mediaPlayer.implicitWidth, systemWindow.anchorX, systemPopout.width)", system)

        tray = (REPOSITORY / "shell/shared/BarTrayItem.qml").read_text(encoding="utf-8")
        application_tray = tray.split("id: applicationTrayComponent", 1)[1]
        self.assertIn("flow: root.context.horizontal ? Flow.LeftToRight : Flow.TopToBottom", application_tray)
        self.assertIn("trayCount * Theme.buttonSize", application_tray)
        self.assertIn("anchors.fill: parent", application_tray)
        self.assertIn("HoverHandler {", application_tray)
        self.assertIn("root.context.surfaceController.trayEntered()", application_tray)
        self.assertIn("root.context.surfaceController.trayExited()", application_tray)
        tray_item = application_tray.split("TrayRailItem {", 1)[1]
        self.assertNotIn("onExited:", tray_item)

    def test_notes_header_keeps_actions_together_and_swaps_only_on_the_right(self) -> None:
        notes = (
            REPOSITORY
            / "shell/popouts/NotesPopout.qml"
        ).read_text(encoding="utf-8")
        notes_surface = (
            REPOSITORY
            / "shell/popouts/BarNotesSurface.qml"
        ).read_text(encoding="utf-8")
        self.assertIn("property bool headerActionsOnRight: false", notes)
        self.assertIn('headerActionsOnRight: Theme.barPosition === "right"', notes_surface)
        self.assertIn("root.geometry.openPanelX > root.geometry.screenWidth / 2", notes_surface)
        self.assertIn(
            "layoutDirection: root.headerActionsOnRight ? Qt.RightToLeft : Qt.LeftToRight",
            notes,
        )
        self.assertIn("horizontalAlignment: root.headerActionsOnRight ? Text.AlignLeft : Text.AlignRight", notes)

    def test_media_popout_is_hidden_without_a_player(self) -> None:
        system = (REPOSITORY / "shell/popouts/BarSystemSurfaces.qml").read_text(encoding="utf-8")
        self.assertIn('root.surfaceController.openPanel === "audio" && mediaPlayer.hasPlayers', system)

    def test_system_popout_splits_state_and_mode_sections(self) -> None:
        popouts = REPOSITORY / "shell/popouts"
        system = (popouts / "SystemPopout.qml").read_text(encoding="utf-8")
        controller = (popouts / "SystemPopoutController.qml").read_text(encoding="utf-8")
        audio = (popouts / "SystemAudioSection.qml").read_text(encoding="utf-8")
        connectivity = (popouts / "SystemConnectivitySection.qml").read_text(encoding="utf-8")
        display = (popouts / "SystemDisplaySection.qml").read_text(encoding="utf-8")

        for component in (
            "SystemPopoutController {",
            "SystemAudioSection {",
            "SystemConnectivitySection {",
            "SystemDisplaySection {",
        ):
            with self.subTest(component=component):
                self.assertIn(component, system)

        self.assertNotIn("component LevelSlider:", system)
        self.assertNotIn("component SectionButton:", system)
        self.assertIn("function queueAudio(value)", controller)
        self.assertIn("function queueBrightness(value)", controller)
        self.assertIn("audio-set-silent", controller)
        self.assertIn("brightness-set-silent", controller)
        self.assertIn('"/control.sh mic " + id', audio)
        self.assertIn('"/control.sh wifi " + id', connectivity)
        self.assertIn('"/control.sh bluetooth " + id', connectivity)
        self.assertIn('"/display/blue-light-mode.sh " + id', display)

    def test_fan_and_gpu_are_configurable_runtime_items(self) -> None:
        delegate = (REPOSITORY / "shell/shared/BarItemDelegate.qml").read_text(encoding="utf-8")
        status_item = (REPOSITORY / "shell/shared/BarStatusItem.qml").read_text(encoding="utf-8")
        for item_id in ("fan", "gpu"):
            with self.subTest(item_id=item_id):
                self.assertIn(f'"{item_id}"', delegate)
        self.assertIn('profile === "Performance" ? "󱑬"', status_item)
        self.assertIn('content.systemInfo.json.profile === "Quiet"', status_item)
        self.assertIn('gpuMode === "gaming" ? "󰪫"', status_item)
        self.assertIn('content.systemInfo.json.gpuMode === "eco"', status_item)
        self.assertIn("visible: contentVisible", delegate)
        self.assertIn("readonly property bool runtimeSuppressed", delegate)
        self.assertIn("contentLoader.item !== null && !runtimeSuppressed", delegate)
        self.assertNotIn("contentLoader.item !== null && contentLoader.item.visible", delegate)

    def test_numeric_battery_hover_opens_the_system_popout(self) -> None:
        battery = (REPOSITORY / "shell/shared/BarBatteryItem.qml").read_text(encoding="utf-8")
        self.assertIn("BatteryCapacityTile {", battery)
        self.assertIn('hoverButtonEntered("system"', battery)
        self.assertIn('hoverButtonExited("battery")', battery)

    def test_runtime_item_visibility_can_bypass_normal_state_suppression(self) -> None:
        delegate = (REPOSITORY / "shell/shared/BarItemDelegate.qml").read_text(encoding="utf-8")
        self.assertIn('readonly property string itemVisibility: itemConfig.visibility || "normal"', delegate)
        self.assertIn('itemVisibility === "always" ? false', delegate)
        self.assertIn('itemId === "privacy" ? contentController.privacy.json.active !== true', delegate)
        self.assertIn('itemId === "touchpad" ? contentController.touchpad.json.enabled !== false', delegate)
        self.assertIn('profile === undefined || contentController.systemInfo.json.profile === "Quiet"', delegate)
        self.assertIn('gpuMode === undefined || contentController.systemInfo.json.gpuMode === "eco"', delegate)
        status_item = (REPOSITORY / "shell/shared/BarStatusItem.qml").read_text(encoding="utf-8")
        self.assertNotIn("visible:", status_item)

    def test_application_tray_uses_the_repeater_count(self) -> None:
        tray = (REPOSITORY / "shell/shared/BarTrayItem.qml").read_text(encoding="utf-8")
        application_tray = tray.split("id: applicationTrayComponent", 1)[1]
        self.assertIn("id: trayRepeater", application_tray)
        self.assertIn("readonly property int trayCount: trayRepeater.count", application_tray)
        self.assertIn("width: implicitWidth", application_tray)
        self.assertIn("height: implicitHeight", application_tray)
        self.assertNotIn("SystemTray.items.length", application_tray)
        bar = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        hidden_drawers = bar.split("model: Theme.barHiddenItems", 1)[0].rsplit("Column {", 1)[1]
        self.assertIn("z: 100", hidden_drawers)

    def test_theme_list_exposes_visual_preview_data(self) -> None:
        entries = list_themes()
        self.assertTrue(entries)
        preview = entries[0]["preview"]
        self.assertIn("colours", preview)
        self.assertIn("wallpaper", preview)
        self.assertEqual(0, preview["widget_count"])
        self.assertEqual({"ui", "mono", "panel"}, set(preview["fonts"]))
        self.assertIn(preview["bar"]["position"], {"left", "right", "top", "bottom"})
        self.assertTrue(preview["bar"]["items"])
        solarized = next(entry for entry in entries if entry["id"] == "solarized-dark")
        self.assertTrue(solarized["builtin"])
        dracula = next(entry for entry in entries if entry["id"] == "dracula")
        self.assertEqual(1, dracula["preview"]["widget_count"])
        self.assertEqual(
            str(REPOSITORY / "themes/wallpapers/showcase/solarized-dark.webp"),
            solarized["preview"]["wallpaper"],
        )

    def test_tray_toggle_points_towards_its_placement_dependent_drawer(self) -> None:
        toggle = (REPOSITORY / "shell/shared/TrayToggleButton.qml").read_text(encoding="utf-8")
        self.assertIn('icon: horizontal ? "󰅂" : "󰅀"', toggle)
        self.assertIn("property bool opensForward: false", toggle)
        self.assertIn("iconRotation: active === opensForward ? 180 : 0", toggle)

    def test_all_commands_support_human_and_json_output(self) -> None:
        commands = (("list",), ("targets",), ("show", "catppuccin-mocha"), ("validate", "catppuccin-mocha"), ("render", "catppuccin-mocha"), ("preview", "catppuccin-mocha"), ("diff", "catppuccin-mocha"), ("doctor",))
        for arguments in commands:
            with self.subTest(command=arguments[0], output="human"):
                completed = run_cli(*arguments)
                if arguments[0] == "doctor":
                    # Doctor reports the live machine; failed checks are typed
                    # output, not a CLI failure. Both modes must still run.
                    self.assertTrue(completed.stdout or completed.stderr)
                else:
                    self.assertEqual(0, completed.returncode, completed.stderr)
                    self.assertTrue(completed.stdout)
            with self.subTest(command=arguments[0], output="json"):
                completed = run_cli(*arguments, "--json")
                if arguments[0] == "doctor":
                    response = json.loads(completed.stdout)
                else:
                    self.assertEqual(0, completed.returncode, completed.stderr)
                    response = json.loads(completed.stdout)
                expected_keys = {"api_version", "command", "ok", "status", "data", "warnings", "errors"}
                if arguments[0] == "show":
                    expected_keys.update(("source", "inherited_paths"))
                self.assertEqual(expected_keys, set(response))
                self.assertEqual(arguments[0], response["command"])

    def test_osd_position_uses_window_edge_flags(self) -> None:
        source = (REPOSITORY / "shell/modules/OsdSurface.qml").read_text(encoding="utf-8")
        self.assertIn("id: osdWindow", source)
        for edge in ("onLeft", "onRight", "onTop", "onBottom"):
            self.assertIn(f"readonly property bool {edge}", source)
            self.assertNotIn(f"parent.{edge}", source)
        for edge in ("left", "right", "top", "bottom"):
            self.assertIn(f"{edge}: on{edge.title()}", source)

    def test_osd_animation_translates_from_its_configured_screen_edge(self) -> None:
        source = (REPOSITORY / "shell/modules/OsdSurface.qml").read_text(encoding="utf-8")
        self.assertIn("transform: Translate", source)
        self.assertIn("osdWindow.onTop ? -osdCard.height - osdWindow.restingGap : osdWindow.height", source)
        self.assertNotIn("y: root.showing ? (osdWindow.onTop", source)

    def test_missing_theme_and_malformed_json_exit_codes(self) -> None:
        missing = run_cli("show", "definitely-missing", "--json")
        self.assertEqual(4, missing.returncode)
        self.assertFalse(json.loads(missing.stdout)["ok"])
        with tempfile.TemporaryDirectory() as temporary:
            malformed_path = Path(temporary) / "malformed.json"
            malformed_path.write_text("{", encoding="utf-8")
            malformed = run_cli("show", str(malformed_path), "--json")
            self.assertEqual(3, malformed.returncode)
            self.assertFalse(json.loads(malformed.stdout)["ok"])

    def test_preview_reports_gtk_restart_and_libadwaita_boundaries(self) -> None:
        completed = run_cli("preview", "catppuccin-mocha", "--json")
        self.assertEqual(0, completed.returncode)
        response = json.loads(completed.stdout)
        self.assertTrue(response["data"]["gtk"]["restart_required"])
        self.assertEqual("partial-user-css", response["data"]["gtk"]["libadwaita_support"])
        self.assertTrue(any("Libadwaita" in warning for warning in response["warnings"]))
        self.assertEqual([22, 24], response["data"]["cursor"]["sizes"])
        self.assertIn("wait", response["data"]["cursor"]["states"])
        self.assertTrue(response["data"]["cursor"]["updates_live"])
        self.assertNotIn("restart_required_for_existing_processes", response["data"]["cursor"])
        self.assertFalse(any("existing applications may retain" in warning for warning in response["warnings"]))

    def test_repository_does_not_force_gtk_theme_environment(self) -> None:
        # Environment wiring is user policy. The product ships no GTK_THEME
        # export and no portal override drop-in.
        shipped = list((REPOSITORY / "packaging/units").glob("*")) + [REPOSITORY / "shell/env.example"]
        for source in shipped:
            if source.is_file():
                self.assertNotIn("GTK_THEME", source.read_text(encoding="utf-8"), source)
        self.assertFalse((REPOSITORY / "packaging/systemd-user/xdg-desktop-portal-gtk.service.d").exists())

    def test_usage_errors_exit_with_two(self) -> None:
        self.assertEqual(2, run_cli().returncode)
        self.assertEqual(2, run_cli("unknown-command").returncode)
        self.assertEqual(2, run_cli("show").returncode)

    def test_render_refuses_non_empty_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "render"
            output.mkdir()
            (output / "owned.txt").write_text("keep", encoding="utf-8")
            completed = run_cli("render", "catppuccin-mocha", "--output", str(output), "--json")
            self.assertEqual(5, completed.returncode)
            self.assertEqual("keep", (output / "owned.txt").read_text(encoding="utf-8"))
            self.assertEqual(["owned.txt"], [path.name for path in output.iterdir()])

    def test_render_refuses_live_state_and_symlink_to_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["XDG_STATE_HOME"] = temporary
            state = Path(temporary) / "blox-theme"
            state.mkdir()
            link = Path(temporary) / "state-link"
            link.symlink_to(state, target_is_directory=True)
            for output in (state, state / "candidate", link / "candidate"):
                with self.subTest(output=output):
                    completed = run_cli("render", "catppuccin-mocha", "--output", str(output), "--json", environment=environment)
                    self.assertEqual(5, completed.returncode)
            self.assertEqual([], list(state.iterdir()))

    def test_diff_reports_add_modify_and_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["XDG_STATE_HOME"] = temporary
            current = Path(temporary) / "blox-theme/current"
            files, _ = render_theme(load_theme("catppuccin-mocha")[1])
            for name, content in files.items():
                path = current / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            (current / "kitty/theme.conf").write_text("changed\n", encoding="utf-8")
            completed = run_cli("diff", "catppuccin-mocha", "--json", environment=environment)
            self.assertEqual(0, completed.returncode)
            changes = {item["path"]: item["change"] for item in json.loads(completed.stdout)["data"]["changes"]}
            self.assertEqual("modify", changes["kitty/theme.conf"])
            self.assertEqual("unchanged", changes["quickshell/theme.json"])


if __name__ == "__main__":
    unittest.main()
