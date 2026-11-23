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

from blox_theme.core import DEFAULT_BAR_ITEMS, apply_theme_defaults, contrast_ratio, dependency_checks, derive_ansi, derive_shape, list_themes, load_theme, render_manifest, render_theme, resolve_wallpaper_path, resolved_bar_items, schema_errors, sparsify_theme, themes_dir, validate_theme, widget_model


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

    def test_null_window_gap_keeps_density_derived_gap(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        source["shape"]["window_gap"] = None
        self.assertEqual(5, derive_shape(source)["hyprland_gap"])

    def test_sparse_save_keeps_explicit_bar_overrides(self) -> None:
        source = json.loads((THEMES / "builtin/catppuccin-mocha.json").read_text(encoding="utf-8"))
        baseline = apply_theme_defaults(source)
        candidate = copy.deepcopy(baseline)
        candidate["shell"]["bar"].update({
            "radius_automatic": False,
            "radius_scale": 1.37,
            "density_automatic": False,
            "density_scale": 1.18,
        })

        saved = sparsify_theme(
            source,
            baseline,
            candidate,
            [
                "shell.bar.radius_automatic",
                "shell.bar.radius_scale",
                "shell.bar.density_automatic",
                "shell.bar.density_scale",
            ],
        )

        self.assertEqual({
            "radius_automatic": False,
            "radius_scale": 1.37,
            "density_automatic": False,
            "density_scale": 1.18,
        }, {
            key: saved["shell"]["bar"][key]
            for key in ("radius_automatic", "radius_scale", "density_automatic", "density_scale")
        })
        self.assertTrue(source["shell"]["bar"]["radius_automatic"])
        self.assertTrue(source["shell"]["bar"]["density_automatic"])

    def test_widget_schema_rejects_invalid_identifiers_and_unknown_fields(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        widget = widget_model().default_widget("clock", "clock")
        mutations = {
            "invalid id": lambda value: value.update(id="Invalid Widget ID"),
            "unknown field": lambda value: value.update(unknown=True),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                theme = copy.deepcopy(source)
                candidate = copy.deepcopy(widget)
                mutate(candidate)
                theme["widgets"]["widgets"] = [candidate]
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

        candidate = copy.deepcopy(theme)
        candidate["targets"]["quickshell"] = True
        self.assertTrue(any("icon theme is not installed" in error for error in dependency_checks(candidate).errors))

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

    def test_package_blank_wallpaper_reference_resolves_from_a_user_theme(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            user_source = Path(temporary) / "themes/user-theme.json"
            resolved = resolve_wallpaper_path("wallpapers/builtin/blank-light.png", user_source)
            self.assertEqual(THEMES / "wallpapers/builtin/blank-light.png", resolved)
            self.assertTrue(resolved.is_file())

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
        self.assertEqual(self.theme["icons"], quickshell["icons"])
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
            "cursor-editor/settings.json", "stylus/blox-system.user.css", "stylus/manifest.json",
            "powerlevel10k/theme.zsh",
            "widgets/profile.json",
        }
        self.assertTrue(phase7.issubset(files))
        self.assertIn("code/settings.json", files)

    def test_zed_renderer_emits_a_native_theme_family(self) -> None:
        theme = copy.deepcopy(self.theme)
        for key in theme["targets"]:
            theme["targets"][key] = key == "zed"
        files, _ = render_theme(theme)
        self.assertEqual(["zed/themes/blox-generated.json"], list(files))
        document = json.loads(files["zed/themes/blox-generated.json"])
        self.assertEqual("https://zed.dev/schema/themes/v0.2.0.json", document["$schema"])
        self.assertEqual("Blox generated", document["name"])
        self.assertEqual("Blox", document["author"])
        generated = document["themes"][0]
        self.assertEqual(f"Blox: {theme['name']}", generated["name"])
        self.assertEqual(theme["variant"], generated["appearance"])
        style = generated["style"]
        self.assertEqual(theme["colours"]["background"], style["editor.background"])
        self.assertEqual(theme["colours"]["accent"], style["border.focused"])
        self.assertEqual(theme["colours"]["info"], style["syntax"]["string"]["color"])
        self.assertEqual(derive_ansi(theme)["color1"], style["terminal.ansi.red"])

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

    def test_hyprland_window_appearance_override_is_rendered(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["hyprland"] = {"inactive_opacity": 0.62, "border_size": 7}
        derived = derive_shape(theme)
        self.assertEqual(15, derived["hyprland_rounding"])
        self.assertEqual(7, derived["hyprland_border_size"])
        self.assertEqual(0.62, derived["hyprland_inactive_opacity"])
        files, _ = render_theme(theme)
        self.assertIn("border_size = 7,", files["hyprland/theme.lua"])
        self.assertIn('active_border = "rgba(89b4faee)",', files["hyprland/theme.lua"])
        self.assertIn("rounding = 15,", files["hyprland/theme.lua"])
        self.assertIn("inactive_opacity = 0.62,", files["hyprland/theme.lua"])

    def test_obsidian_renderer_maps_light_and_square_variants(self) -> None:
        for variant, radius_scale, expected_scheme, expected_radius in (
            ("dark", 1.25, "dark", "15px"),
            ("light", 1.25, "light", "15px"),
            ("dark", 0, "dark", "0px"),
        ):
            with self.subTest(variant=variant, radius=radius_scale):
                theme = copy.deepcopy(self.theme)
                theme["variant"] = variant
                theme["shape"]["radius_scale"] = radius_scale
                files, _ = render_theme(theme)
                package = json.loads(files["obsidian/manifest.json"])
                css = files["obsidian/theme.css"]
                self.assertEqual("Blox generated", package["name"])
                self.assertIn(f"color-scheme: {expected_scheme};", css)
                self.assertIn(f"--radius-m: {expected_radius};", css)
                self.assertIn(f"--background-primary: {theme['colours']['background']};", css)
                self.assertIn('BlinkMacSystemFont, "Segoe UI", sans-serif;', css)

    def test_code_target_renders_complete_extension(self) -> None:
        self.theme["targets"]["code"] = True
        files, _ = render_theme(self.theme)
        code_settings = json.loads(files["code/settings.json"])
        self.assertEqual(self.theme["fonts"]["mono"], code_settings["editor.fontFamily"])
        self.assertEqual("blox-theme", code_settings["workbench.colorTheme"])
        self.assertTrue(code_settings["workbench.experimental.modernUI"])
        self.assertNotIn("editor.fontSize", code_settings)
        self.assertNotIn("workbench.colorCustomizations", code_settings)
        package = json.loads(files["code/package.json"])
        self.assertEqual("blox-theme", package["name"])
        self.assertEqual("^1.90.0", package["engines"]["vscode"])
        self.assertEqual("./themes/blox-generated-color-theme.json", package["contributes"]["themes"][0]["path"])
        self.assertEqual("Blox: Catppuccin Mocha", package["contributes"]["themes"][0]["label"])
        code_theme = json.loads(files["code/themes/blox-generated-color-theme.json"])
        self.assertIn("sideBarSectionHeader.background", code_theme["colors"])
        self.assertGreater(len(code_theme["colors"]), 300)
        self.assertGreater(len(code_theme["tokenColors"]), 100)
        self.assertNotIn("include", code_theme)
        self.assertTrue(code_theme["semanticHighlighting"])
        obsidian_manifest = json.loads(files["obsidian/manifest.json"])
        self.assertEqual("Blox generated", obsidian_manifest["name"])
        self.assertEqual("1.13.0", obsidian_manifest["minAppVersion"])
        obsidian_css = files["obsidian/theme.css"]
        self.assertIn(f"--background-primary: {self.theme['colours']['background']};", obsidian_css)
        self.assertIn(f"--text-accent: {self.theme['colours']['accent']};", obsidian_css)
        self.assertIn("--radius-m: 15px;", obsidian_css)
        shell = json.loads(files["quickshell/theme.json"])["shell"]
        expected_shell = self.theme.get("shell", {})
        self.assertEqual(expected_shell.get("bar", {}).get("position", "left"), shell["bar"]["position"])
        expected_bar = expected_shell.get("bar", {})
        self.assertEqual(expected_bar.get("separate_groups", False), shell["bar"]["separate_groups"])
        self.assertEqual(expected_bar.get("border", False), shell["bar"]["border"])
        self.assertEqual(expected_bar.get("edge_inset", 0), shell["bar"]["edge_inset"])
        expected_bar_items = resolved_bar_items(expected_shell.get("bar"))
        self.assertEqual(
            {item["id"]: item for item in expected_bar_items},
            {item["id"]: item for item in shell["bar"]["items"]},
        )
        self.assertEqual(expected_shell.get("osd", {}).get("position", "top-left"), shell["osd"]["position"])
        self.assertEqual(expected_shell.get("notifications", {}).get("position", "bottom-right"), shell["notifications"]["position"])
        cursor_settings = json.loads(files["cursor-editor/settings.json"])
        self.assertEqual("blox-theme", cursor_settings["workbench.colorTheme"])
        self.assertEqual(self.theme["fonts"]["mono"], cursor_settings["editor.fontFamily"])
        self.assertNotIn("workbench.experimental.modernUI", cursor_settings)
        self.assertNotIn("workbench.colorCustomizations", cursor_settings)
        self.assertIn("cursor-editor/package.json", files)
        self.assertIn("cursor-editor/themes/blox-generated-color-theme.json", files)
        self.assertEqual(files["code/themes/blox-generated-color-theme.json"], files["cursor-editor/themes/blox-generated-color-theme.json"])
        self.assertIn("@-moz-document", files["stylus/blox-system.user.css"])
        stylus_manifest = json.loads(files["stylus/manifest.json"])
        self.assertEqual("catppuccin-mocha", stylus_manifest["theme_id"])
        self.assertEqual(92, len(stylus_manifest["styles"]))
        self.assertEqual(0, len(stylus_manifest["excluded"]))
        self.assertNotIn('regexp("https?://.*")', files["stylus/blox-system.user.css"])
        self.assertIn('color-link default "#cdd6f4"', files["micro/blox-theme.micro"])
        self.assertNotIn('color-link default "#cdd6f4,#242424"', files["micro/blox-theme.micro"])
        hyprtoolkit = files["hyprland/hyprtoolkit.conf"]
        self.assertIn("background = 0xFF1E1E2E", hyprtoolkit)
        self.assertIn("accent = 0xFF89B4FA", hyprtoolkit)
        self.assertIn("icon_theme = Adwaita", hyprtoolkit)
        self.assertIn("font_family = Outfit", hyprtoolkit)

    def test_editor_package_tracks_light_variant_and_square_modern_ui(self) -> None:
        _, theme = load_theme("catppuccin-latte")
        theme["shape"]["radius_scale"] = 0
        theme["targets"]["code"] = True
        files, _ = render_theme(theme)
        settings = json.loads(files["code/settings.json"])
        package = json.loads(files["code/package.json"])
        colour_theme = json.loads(files["code/themes/blox-generated-color-theme.json"])
        self.assertFalse(settings["workbench.experimental.modernUI"])
        self.assertEqual("vs", package["contributes"]["themes"][0]["uiTheme"])
        self.assertEqual("light", colour_theme["type"])
        self.assertEqual(theme["colours"]["background"], colour_theme["colors"]["editor.background"])
        self.assertNotIn("include", colour_theme)

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
        for item_id in ("privacy", "touchpad", "fan"):
            self.assertEqual("normal", items[item_id]["visibility"])
        self.assertEqual("hybrid", items["gpu"]["visibility"])

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

    def test_gpu_bar_visibility_accepts_each_named_mode(self) -> None:
        for visibility in ("always", "dedicated", "hybrid", "integrated"):
            candidate = copy.deepcopy(self.theme)
            candidate["shell"]["bar"]["items"] = [{"id": "gpu", "enabled": True, "region": "hidden", "order": 0, "visibility": visibility}]
            with self.subTest(visibility=visibility):
                self.assertEqual([], schema_errors(candidate))

        for visibility in ("normal", "unsupported"):
            candidate = copy.deepcopy(self.theme)
            candidate["shell"]["bar"]["items"] = [{"id": "gpu", "enabled": True, "region": "hidden", "order": 0, "visibility": visibility}]
            with self.subTest(invalid_visibility=visibility):
                self.assertTrue(schema_errors(candidate))

        candidate = copy.deepcopy(self.theme)
        candidate["shell"]["bar"]["items"] = [{"id": "fan", "enabled": True, "region": "hidden", "order": 0, "visibility": "hybrid"}]
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
            "glow": "glow/style.json", "code": ["code/package.json", "code/settings.json", "code/themes/blox-generated-color-theme.json"],
            "helium": "helium/manifest.json",
            "cursor_editor": ["cursor-editor/package.json", "cursor-editor/settings.json", "cursor-editor/themes/blox-generated-color-theme.json"], "stylus": ["stylus/blox-system.user.css", "stylus/manifest.json"],
            "t3code": "t3code/theme.json",
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
        theme["targets"]["helium"] = False
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
        widgets = {"schemaVersion": 1, "widgets": [
            widget_model().default_widget('terminal', 'terminal', {'command': ['/bin/echo', 'review me']})]}
        with tempfile.TemporaryDirectory() as temporary:
            exported = Path(temporary) / "widgets.json"
            result = run_cli("widgets-export", json.dumps(widgets), "--output", str(exported), "--json")
            self.assertEqual(0, result.returncode, result.stderr)
            document = json.loads(exported.read_text(encoding="utf-8"))
            self.assertEqual(widgets, document)

            imported = run_cli("widgets-import", str(exported), "--json")
            self.assertEqual(0, imported.returncode, imported.stderr)
            safe_widgets = copy.deepcopy(widgets)
            safe_widgets['widgets'][0]['enabled'] = False
            self.assertEqual(safe_widgets, json.loads(imported.stdout)["data"])
            self.assertTrue(json.loads(imported.stdout)["warnings"])

            malformed = Path(temporary) / "not-widgets.json"
            malformed.write_text(json.dumps({"schema_version": 1, "widgets": widgets}), encoding="utf-8")
            rejected_document = run_cli("widgets-import", str(malformed), "--json")
            self.assertEqual(3, rejected_document.returncode)
            self.assertFalse(json.loads(rejected_document.stdout)["ok"])

            invalid_widgets = copy.deepcopy(widgets)
            invalid_widgets["widgets"][0]["id"] = "Invalid Widget ID"
            rejected_widget = run_cli("widgets-export", json.dumps(invalid_widgets), "--output", str(Path(temporary) / "invalid.json"), "--json")
            self.assertEqual(3, rejected_widget.returncode)
            self.assertFalse(json.loads(rejected_widget.stdout)["ok"])

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
        self.assertEqual(0, dracula["preview"]["widget_count"])
        self.assertEqual(
            str(REPOSITORY / "themes/wallpapers/showcase/solarized-dark.webp"),
            solarized["preview"]["wallpaper"],
        )

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
        self.assertEqual("Bibata-Modern-Classic", response["data"]["cursor"]["style"])
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
            state = Path(temporary) / "blox/theme"
            state.mkdir(parents=True)
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
            current = Path(temporary) / "blox/theme/current"
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
