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


def qml_source(name: str) -> str:
    return (PICKER_MODULES / f"ThemePicker{name}.qml").read_text(encoding="utf-8")


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

    def test_inline_preview_is_side_effect_free_and_inline_apply_is_rejected(self) -> None:
        candidate = copy.deepcopy(self.source)
        for target in candidate["targets"]:
            candidate["targets"][target] = target == "quickshell"
        inline = json.dumps(candidate)

        with mock.patch("blox_theme.cli.apply_theme") as apply_theme:
            response, code = self.invoke("preview", inline, "--json")
            self.assertEqual(0, code, response)
            self.assertTrue(response["ok"])
            apply_theme.assert_not_called()

            response, code = self.invoke("apply", inline, "--json")
            self.assertEqual(3, code)
            self.assertIn("saved source theme", response["errors"][0])
            apply_theme.assert_not_called()

    def test_mutations_reject_a_non_object_source(self) -> None:
        path = self.user_library / "themes/broken.json"
        path.write_text("[]", encoding="utf-8")
        response, code = self.invoke("rename", "broken", "Still Broken", "--json")
        self.assertEqual(3, code)
        self.assertIn("JSON object", response["errors"][0])
        self.assertEqual([], json.loads(path.read_text(encoding="utf-8")))

    def test_generated_target_files_can_be_exported_without_path_escape(self) -> None:
        state = self.root / "state"
        generated = state / "current/code/themes/blox-dark-2026.json"
        generated.parent.mkdir(parents=True)
        generated.write_text('{"name":"Blox"}', encoding="utf-8")
        output = self.root / "downloads/blox-dark-2026.json"
        with mock.patch("blox_theme.cli.state_dir", return_value=state):
            response, code = self.invoke("export-target", "code", "--file", "code/themes/blox-dark-2026.json", "--output", str(output), "--json")
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
            "code/themes/blox-dark-2026.json": "theme",
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


class PickerIntegrationSourceTests(unittest.TestCase):
    def test_selected_theme_wallpaper_uses_the_resolved_library_preview(self) -> None:
        controller = qml_source("WidgetController")
        overview = qml_source("Overview")
        resolver = controller.split("function localFileUrl(path)", 1)[1].split(
            "function previewCommand", 1
        )[0]

        self.assertIn("source.wallpaper.path === value", resolver)
        self.assertIn("theme.id === host.selectedId", resolver)
        self.assertIn("return localFileUrl(theme.preview.wallpaper);", resolver)
        self.assertIn("return Theme.wallpaperUrl(value);", resolver)
        self.assertIn('url.startsWith("file://") ? url.slice(7) : url', resolver)
        self.assertIn("controller.wallpaperDisplayPath(controller.candidate.wallpaper.path)", overview)
        self.assertIn("controller.setWallpaperDisplayPath(text);", overview)

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

    def test_picker_refreshes_sources_each_time_it_opens(self) -> None:
        controller = qml_source("Controller")
        open_picker = controller.split("function openPicker()", 1)[1].split(
            "function requestClose()", 1
        )[0]

        self.assertIn("refreshThemes(false);", open_picker)
        self.assertNotIn("if (themes.length === 0)", open_picker)

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

    def test_widget_style_selector_preserves_widget_items(self) -> None:
        controller = qml_source("Controller")
        widgets = qml_source("Widgets")
        setter = controller.split("function setWidgetProfile(value)", 1)[1].split(
            "function setTarget", 1
        )[0]

        self.assertIn('text: "Style"', widgets)
        self.assertIn('["minimal", "compact", "comfortable"]', widgets)
        self.assertIn("next.widgets.profile = value", setter)
        self.assertNotIn('next.widgets = {\n            "profile": value', setter)

    def test_bar_item_drag_uses_a_moving_proxy(self) -> None:
        main = qml_source("")
        advanced = qml_source("Advanced")
        controller = qml_source("Controller")
        self.assertIn("id: barDragProxy", main)
        self.assertGreaterEqual(advanced.count("target: null"), 2)
        self.assertIn("Drag.source: barDragProxy", main)
        self.assertNotIn("Drag.source: barItemRow", advanced)
        drag_section = advanced.split('model: ["start", "centre", "end", "hidden"]', 1)[1].split('text: "Bar"', 1)[0]
        self.assertIn("onPositionChanged:", drag_section)
        self.assertIn("controller.finishBarDrag()", drag_section)
        self.assertIn("controller.setBarDropTarget", drag_section)
        self.assertIn('color: Theme.blue', drag_section)
        self.assertIn("z: 1000", main)
        self.assertEqual(1, main.count("id: barDragProxy"))
        self.assertIn("function beginBarDrag(row, itemId)", controller)

    def test_picker_uses_json_api_and_has_confirmation_paths(self) -> None:
        qml = "\n".join(path.read_text(encoding="utf-8") for path in sorted(PICKER_MODULES.glob("ThemePicker*.qml")))
        for action in ("list", "show", "preview", "generate", "save", "apply", "duplicate", "rename", "delete"):
            self.assertIn(f'"{action}"', qml)
        self.assertIn("FloatingWindow {", qml)
        self.assertNotIn("PanelWindow {", qml)
        self.assertIn("parentWindow: root._backingWindow", qml)
        self.assertIn("visible: pickerController.open && !pickerController.widgetEditModePending", qml)
        self.assertIn("hideTimer.stop()", qml)
        self.assertIn("Theme.widgetEditModeCancelRequested()", qml)
        self.assertIn("hl.dsp.focus({ workspace = \\\"previous\\\" })", qml)
        self.assertIn("function recoverPickerWorkspace(returnWorkspace)", qml)
        self.assertIn("hl.dsp.window.move({ workspace =", qml)
        self.assertIn('window = \\\\\\\"title:^Blox Theme Picker$\\\\\\\"', qml)
        self.assertNotIn("hyprctl dispatch movetoworkspacesilent", qml)
        self.assertIn('recoverPickerWorkspace("");', qml)
        self.assertIn("recoverPickerWorkspace(returnWorkspace);", qml)
        self.assertIn("host._backingWindow.requestActivate()", qml)
        self.assertIn("root.contentItem.QsWindow.window.startSystemMove()", qml)
        # Window rules for the picker live in the user's Hyprland config, not
        # in this repository; the QML side supplies the matching title above.
        for control in ("BloxButton", "BloxTextField", "BloxComboBox", "BloxCheckBox", "BloxFontPicker"):
            self.assertIn(control, qml)
        for native_control in ("Button", "TextField", "ComboBox", "CheckBox"):
            self.assertNotRegex(qml, rf"(?m)^\s*{native_control}\s*\{{")
        self.assertIn('"UNSAVED"', qml)
        self.assertIn("colourPickerOpen", qml)
        self.assertIn("openColourPicker", qml)
        self.assertIn('iconName: "plus"', qml)
        self.assertIn('text: "New theme"', qml)
        self.assertIn("function openNewTheme(wallpaperPage)", qml)
        self.assertIn('runApi("new-template", ["show", "catppuccin-mocha"])', qml)
        self.assertIn('text: "From blank"', qml)
        self.assertIn('text: "From wallpaper"', qml)
        self.assertIn("Layout.rightMargin: Theme.scaledSpacing(10)", qml)
        self.assertIn('text: "Wallpaper"', qml)
        self.assertNotIn('text: "Generate"', qml)
        self.assertIn("acceptedButtons: Qt.LeftButton | Qt.RightButton", qml)
        self.assertIn("id: themeActions", qml)
        self.assertIn("id: modalInputBlocker", qml)
        self.assertIn("id: colourInputBlocker", qml)
        self.assertIn("id: modalCardInputBlocker", qml)
        self.assertIn("id: colourCardInputBlocker", qml)
        self.assertIn("id: pickerContent", qml)
        self.assertIn('pickerController.action === "preview-edit"', qml)
        self.assertIn("function duplicateIdForName(name)", qml)
        self.assertNotIn('placeholderText: "New stable ID"', qml)
        self.assertIn("id: duplicateIdFooter", qml)
        self.assertIn('controller.modalKind === "new" ? controller.newThemeId : controller.duplicateId', qml)
        self.assertIn('color: "transparent"', qml)
        self.assertIn("anchors.margins: Theme.scaledSpacing(1)", qml)
        self.assertIn("radius: Theme.scaledRadius(8)", qml)
        self.assertNotIn('"Internal ID', qml)
        self.assertIn("id: modalDismissTimer", qml)
        self.assertIn("id: colourDismissTimer", qml)
        self.assertIn('showModal("navigate")', qml)
        self.assertIn('showModal("delete")', qml)
        self.assertIn("onClicked: themeActions.open()", qml)
        self.assertNotIn("onClicked: {\n                                                if (modelData.id !== root.selectedId)\n                                                    root.requestSelection", qml)
        self.assertIn("function select(value: string)", qml)
        self.assertIn("Theme.cancelPreview()", qml)
        self.assertNotIn("bash -c", qml)

    def test_picker_rejects_stale_requests_and_keeps_applied_identity_separate(self) -> None:
        picker = qml_source("Controller")
        api = qml_source("ApiController")
        generation = qml_source("GenerationController")
        theme = (REPOSITORY / "shell/shared/Theme.qml").read_text(encoding="utf-8")
        self.assertIn("property var activeRequest: null", api)
        self.assertIn('"candidateRevision": host.candidateRevision', api)
        self.assertIn('"candidateJson": host.candidate === null ? "" : JSON.stringify(host.candidate)', api)
        self.assertIn("request.sessionRevision !== host.sessionRevision", api)
        self.assertIn("request.candidateRevision !== host.candidateRevision", api)
        self.assertIn("function applyValidatedPreview(source)", picker)
        self.assertIn("if (!dirty && selectedId === Theme.activeThemeId)", picker)
        self.assertIn("Theme.cancelPreview()", picker)
        self.assertIn("Theme.previewSource(source)", picker)
        self.assertIn("setPreviewWallpaper(data);", theme)
        self.assertIn("wallpaperSource = activeWallpaperSource;", theme)
        self.assertIn("id: wallpaperFile", theme)
        self.assertNotIn("wallpaperProcess", theme)
        self.assertIn("host.applyValidatedPreview(JSON.parse(request.candidateJson))", api)
        self.assertIn("host.validationPending = host.candidate !== null", api)
        self.assertIn("host.continueQueuedGeneration()", api)
        self.assertIn('host.runApi("show-generate-current", ["show", Theme.activeThemeId])', generation)
        self.assertIn('if (busy && action !== "preview-edit")', picker)
        self.assertIn('return "busy"', picker)
        self.assertIn("return root.requestClose()", picker)
        self.assertNotIn("candidate.wallpaper.path);\n            }\n            return \"open-generating\"", picker)
        self.assertIn('property string activeThemeId: ""', theme)
        self.assertIn('property string themeId: ""', theme)
        document = (REPOSITORY / "shell/shared/ThemeDocumentController.qml").read_text(encoding="utf-8")
        self.assertIn("theme.activeThemeId = data.id", document)
        preview = document.split("function previewSource", 1)[1]
        self.assertNotIn("theme.activeThemeId =", preview)
        self.assertIn("root.loadActiveIdentity(text())", theme)

    def test_unavailable_targets_are_visible_but_not_editable(self) -> None:
        controller = qml_source("Controller")
        advanced = qml_source("Advanced")
        self.assertIn('readonly property var unavailableTargetKeys: ["sddm", "grub"]', controller)
        self.assertIn("function targetAvailable(key)", controller)
        self.assertNotIn('text: "Widget profile"', advanced)
        self.assertIn('return key + " · unavailable"', controller)
        self.assertIn("if (!targetAvailable(key))", controller)
        self.assertIn("enabled: controller.targetAvailable(modelData)", advanced)
        self.assertIn('readonly property var coreTargetKeys:', controller)
        self.assertIn('readonly property var applicationTargetKeys:', controller)
        self.assertIn('text: "Core"', advanced)
        self.assertIn('text: "Applications"', advanced)

    def test_creation_and_application_flows_expose_progress_and_apply_modes(self) -> None:
        controller = qml_source("Controller")
        creation = qml_source("CreationFlow")
        progress = qml_source("ProgressFlow")
        overview = qml_source("Overview")
        advanced = qml_source("Advanced")
        main = qml_source("")
        api = qml_source("ApiController")
        generation = qml_source("GenerationController")
        qml = "\n".join((controller, api, generation, creation, progress, overview, advanced, main))
        for label in ("Name", "File Path", "Browse", "Generated Colour Palettes", "Matugen", "Pywal"):
            self.assertIn(f'"{label}"', qml)
        self.assertIn('host.runApi("palette", ["palette", path])', qml)
        self.assertIn('"--mode", selectedVariant', qml)
        self.assertIn('property string newVariant: "dark"', qml)
        self.assertIn('model: ["dark", "light"]', creation)
        self.assertIn('controller.newVariant = modelData.mode', creation)
        self.assertIn("columns: 2", creation)
        self.assertIn("Layout.preferredHeight: 132", creation)
        self.assertIn('source: "file://" + controller.newWallpaper.trim()', creation)
        self.assertIn("activeFocusOnTab: modelData.available", creation)
        self.assertIn("Keys.onSpacePressed: choose()", creation)
        self.assertIn("palettePill.forceActiveFocus()", creation)
        self.assertIn("width: parent.width * 0.49", creation)
        self.assertIn("radius: Theme.scaledRadius(0)", creation)
        self.assertIn("modelData.colours.surface_alt", creation)
        self.assertIn('modelData.colours.selection_background', creation)
        self.assertIn('"selection_background", "selection_foreground", "teal"', creation)
        self.assertIn('"warning", "border", "info"', creation)
        self.assertIn('"wallpaper": wallpaper', qml)
        self.assertIn('"backend": selectedBackend', qml)
        self.assertIn("request.inputs", qml)
        self.assertIn("request.inputs.paletteSerial !== host.paletteRequestSerial", qml)
        self.assertIn("request.inputs.wallpaper !== host.newWallpaper.trim()", qml)
        self.assertIn('showModal("progress")', qml)
        self.assertIn('text: "Guide"', qml)
        self.assertIn('if (key === "stylus" || key === "obsidian")', qml)
        self.assertIn('return "manual"', qml)
        self.assertIn('key === "code" || key === "cursor_editor" ? "Reload Window"', qml)
        self.assertIn('source: "../assets/stylus-import.png"', qml)
        self.assertIn('text: "Generated Files"', qml)
        self.assertIn("function generatedFiles()", qml)
        self.assertIn('const order = ["stylus"]', qml)
        self.assertIn("function generatedFileGroups()", qml)
        self.assertIn('text: "Download all (.zip)"', qml)
        self.assertIn("controller.downloadGeneratedArchive(modelData.target)", advanced)
        self.assertIn("controller.downloadGeneratedFile(modelData.target, modelData.file)", advanced)
        self.assertIn("Install and select the Minimal theme", qml)
        self.assertIn("generated style-settings.json", qml)
        self.assertIn('text: "Simple"', qml)
        self.assertNotIn('text: "Target impact"', overview)
        self.assertNotIn('text: "Dependency and compatibility notes"', overview)
        self.assertIn("editorScroll.contentY - delta * 4", qml)
        self.assertIn('text: "Bar / OSD / Notifications"', qml)
        self.assertIn('visible: controller.editorMode === "overview"', overview)
        self.assertIn('Theme.osdPositionPreviewRequested()', qml)
        self.assertIn('Theme.notificationPositionPreviewRequested()', qml)

    def test_widget_position_canvas_supports_drag_resize_snap_and_numeric_geometry(self) -> None:
        widgets = qml_source("Widgets")
        widget_controller = qml_source("WidgetController")
        for expected in (
            'id: widgetCanvas',
            'text: "Position"',
            'drag.target: widgetPreview',
            'cursorShape: Qt.SizeFDiagCursor',
            'controller.commitWidgetPreview(',
            'model: ["offset_x", "offset_y", "width", "height"]',
            'controller.updateWidgetGeometry(',
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, widgets)
        self.assertIn('anchor = (bottom ? "bottom-" : "top-") + (right ? "right" : "left")', widget_controller)

    def test_advanced_picker_can_toggle_place_and_reorder_every_bar_item(self) -> None:
        controller = qml_source("Controller")
        bar_model = qml_source("BarModel")
        advanced = qml_source("Advanced")
        main = qml_source("")
        for function_name in (
            "barItems",
            "trayOpensForward",
            "applicationTrayAtStart",
            "normaliseBarItemOrders",
            "setBarItemEnabled",
            "setBarItemDisplay",
            "setBarItemVisibility",
            "setBarItemTitleLength",
            "setBarItemRegion",
            "moveBarItem",
            "moveBarItemTo",
        ):
            self.assertIn(f"function {function_name}(", controller)
        self.assertIn('model: ["start", "centre", "end", "hidden"]', advanced)
        self.assertIn('"Tray"', advanced)
        self.assertIn("controller.setBarItemEnabled(barItemRow.modelData.id, value)", advanced)
        self.assertIn('model: ["click to toggle", "only numeric", "only icon"]', advanced)
        self.assertIn("controller.setBarItemDisplay(barItemRow.barItemId, displayValues[index])", advanced)
        self.assertIn('visible: barItemRow.modelData.id === "battery"', advanced)
        self.assertIn('model: ["always visible", "hidden when normal"]', advanced)
        self.assertIn('visible: ["privacy", "touchpad", "fan", "gpu"].indexOf(barItemRow.modelData.id) >= 0', advanced)
        self.assertIn("Layout.preferredWidth: visible ? 172 : 0", advanced)
        self.assertIn("controller.setBarItemVisibility(barItemRow.barItemId, visibilityValues[index])", advanced)
        self.assertIn('model: ["cut off long titles", "show full title"]', advanced)
        self.assertIn('visible: barItemRow.modelData.id === "active-window-title"', advanced)
        self.assertIn("controller.setBarItemTitleLength(barItemRow.barItemId, titleLengthValues[index])", advanced)
        self.assertIn('"active-window-title": "cursor-text"', bar_model)
        self.assertIn('"touchpad": "cursor-click"', bar_model)
        self.assertIn("Drag.active: pickerController.barDragActive", main)
        self.assertEqual(2, advanced.count("target: null"))
        self.assertEqual(2, advanced.count("onTranslationChanged: controller.moveBarDragProxy"))
        self.assertIn("Drag.source: barDragProxy", main)
        self.assertIn("controller.finishBarDrag()", advanced)
        self.assertIn('iconName: "caret-up"', advanced)
        self.assertIn('iconName: "caret-down"', advanced)
        self.assertNotIn('ToolTip.text: "Move up"', advanced)
        self.assertNotIn('ToolTip.text: "Move down"', advanced)
        self.assertIn("onClicked: controller.moveBarItem(barItemRow.barItemId, -1)", advanced)
        self.assertIn("onClicked: controller.moveBarItem(barItemRow.barItemId, 1)", advanced)
        self.assertIn('barItemRow.modelData.id === "application-tray" ? ["tray"]', advanced)
        self.assertIn('barItemRow.modelData.id === "tray" ? ["start", "centre", "end"] : controller.barRegions', advanced)
        self.assertIn('if (region === "hidden")', controller)
        self.assertIn('if (region === "start")', controller)
        self.assertIn('if (region === "end")', controller)
        self.assertIn('value === "tray" ? "hidden" : value', advanced)
        normalise = bar_model.split("function normaliseOrders(", 1)[1].split("function label", 1)[0]
        self.assertIn("ordered.push(members[index])", normalise)
        self.assertIn("return ordered", normalise)
        header = advanced.index('text: regionSection.modelData === "hidden" ? "Tray"')
        first_drop_target = advanced.index('"start:" + regionSection.modelData')
        self.assertLess(header, first_drop_target)
        self.assertIn("function scrollBarDrag()", controller)
        self.assertIn("running: pickerController.barDragActive", main)
        self.assertIn("Theme.resolvedBarItems(overrides, position)", bar_model)
        self.assertIn("Theme.resolvedBarItems(overrides, value)", controller)
        self.assertIn("Theme.loadShell(next.shell)", bar_model)
        self.assertIn('if (id === "application-tray")', bar_model)
        self.assertIn("return !trayOpensForward(items)", bar_model)
        self.assertIn("Layout.preferredWidth: 92", advanced)

    def test_custom_controls_are_registered_and_font_rows_preview_their_family(self) -> None:
        shared = REPOSITORY / "shell/shared"
        qmldir = (shared / "qmldir").read_text(encoding="utf-8")
        for control in ("BloxButton", "BloxTextField", "BloxComboBox", "BloxCheckBox", "BloxFontPicker"):
            self.assertIn(f"{control} 1.0 {control}.qml", qmldir)
        button = (shared / "BloxButton.qml").read_text(encoding="utf-8")
        self.assertNotIn("Lucide", qmldir)
        self.assertIn("PhosphorIcon {", button)
        self.assertIn("iconName: buttonRoot.iconName", button)
        self.assertFalse((shared / "Lucide.qml").exists())
        self.assertFalse((REPOSITORY / "shell/assets/fonts/lucide.ttf").exists())
        font_picker = (shared / "BloxFontPicker.qml").read_text(encoding="utf-8")
        self.assertIn("TextInput {", font_picker)
        self.assertIn("font.family: modelData", font_picker)
        self.assertIn("filteredFamilies()", font_picker)
        self.assertIn("opensBelow", font_picker)
        self.assertIn("modal: true", font_picker)
        self.assertIn("property bool suppressEditingFinished: false", font_picker)
        self.assertIn("function chooseHighlighted()", font_picker)
        self.assertIn("Keys.onPressed", font_picker)
        self.assertIn("event.key === Qt.Key_Space", font_picker)
        self.assertIn("required property int index", font_picker)
        self.assertIn("Canvas {", font_picker)
        self.assertNotIn('text: popup.visible ? "▴" : "▾"', font_picker)
        combo_box = (shared / "BloxComboBox.qml").read_text(encoding="utf-8")
        self.assertIn("modal: true", combo_box)
        self.assertNotIn("modal: false", combo_box)
        self.assertIn("signal activated(int index, string text)", combo_box)
        self.assertIn("function moveHighlight(delta)", combo_box)
        self.assertIn("Keys.onPressed", combo_box)
        self.assertNotIn("root.currentIndex = index", combo_box)
        text_field = (shared / "BloxTextField.qml").read_text(encoding="utf-8")
        self.assertIn("signal accepted()", text_field)
        self.assertIn("function focusEditor(selectAllText)", text_field)
        self.assertIn("root.editingFinished();", text_field)
        self.assertIn("activeFocusOnTab: root.enabled && !root.readOnly", text_field)

    def test_blank_theme_seeds_matching_light_and_dark_palettes(self) -> None:
        qml = qml_source("GenerationController")
        blank = qml.split("function blankTheme(", 1)[1].split("function startNew(", 1)[0]
        self.assertIn('blank.variant = variant', blank)
        self.assertIn('"background": light ? "#ffffff" : "#111318"', blank)
        self.assertIn('"foreground": light ? "#000000" : "#f2f3f5"', blank)
        self.assertIn('"ansi_source": "override"', blank)
        self.assertIn('"color0": light ? "#000000" : "#111318"', blank)
        self.assertIn('"color15": light ? "#ffffff" : "#f2f3f5"', blank)
        self.assertIn('light ? "~/Pictures/wallpapers/blank-light.png" : "~/Pictures/wallpapers/blank-dark.png"', blank)
        self.assertIn("blank.targets.wallpaper = true", blank)
        self.assertNotIn('blank.fonts[role] = ""', blank)
        self.assertTrue((REPOSITORY / "wallpapers/wallpapers/blank-light.png").is_file())
        self.assertTrue((REPOSITORY / "wallpapers/wallpapers/blank-dark.png").is_file())

    def test_advanced_mode_can_edit_terminal_colours(self) -> None:
        controller = qml_source("Controller")
        advanced = qml_source("Advanced")
        terminal = advanced.split('text: "Terminal colours"', 1)[1].split('text: "Bar / OSD / Notifications"', 1)[0]
        self.assertIn("model: controller.ansiKeys", terminal)
        self.assertIn('controller.openColourPicker(modelData, "ansi")', terminal)
        self.assertIn("previewData.ansi[modelData]", terminal)
        self.assertIn('if (target === "ansi")', controller)
        self.assertIn('next.terminal.ansi_source = "override"', controller)

    def test_simple_mode_contains_font_pickers(self) -> None:
        overview = qml_source("Overview")
        self.assertIn('text: "Fonts"', overview)
        self.assertIn("BloxFontPicker {", overview)
        self.assertEqual(1, overview.count('"panel · proportional fonts recommended"'))

    def test_shape_controls_follow_the_accepted_two_view_contract(self) -> None:
        controller = qml_source("Controller")
        overview = qml_source("Overview")
        advanced = qml_source("Advanced")
        preview = (PICKER_MODULES / "ThemeShapePreview.qml").read_text(encoding="utf-8")
        slider = (REPOSITORY / "shell/shared/BloxSlider.qml").read_text(encoding="utf-8")

        for label in ("Round", "Slightly round", "Square", "Compact", "Comfortable", "Spacious"):
            self.assertIn(f'"label": "{label}"', overview)
        self.assertGreaterEqual(overview.count("ThemeShapePreview {"), 2)
        self.assertIn('label: "Style"', advanced)
        self.assertIn('label: "Density"', advanced)
        self.assertIn('text: "Automatic"', advanced)
        self.assertIn('label: "Window gap"', advanced)
        self.assertNotIn("SpinBox", advanced)
        self.assertIn('delete next.shape[key]', controller)
        self.assertIn('setShapeValue("window_gap", effectiveWindowGap())', controller)
        self.assertIn("preventStealing: true", slider)
        self.assertIn("event.accepted = true", slider)
        self.assertIn("readonly property real mainWidth", preview)
        self.assertEqual(3, preview.count("AppWindow {"))

    def test_theme_list_uses_source_colours_wallpaper_and_fonts(self) -> None:
        theme_list = qml_source("Library")
        self.assertIn("id: themeThumbnail", theme_list)
        self.assertIn("modelData.preview.wallpaper", theme_list)
        self.assertIn("modelData.preview.fonts.ui", theme_list)
        self.assertIn("controller.themePreviewColour", theme_list)
        self.assertIn("id: themeBarPreview", theme_list)
        self.assertIn("controller.themePreviewBarCount", theme_list)
        self.assertIn("fontSizeMode: themeDelegate.previewAtMinimum ? Text.Fit : Text.FixedSize", theme_list)
        self.assertNotIn('text: modelData.unsaved ? "UNSAVED  ·  " + modelData.variant : modelData.variant', theme_list)

    def test_picker_modal_keyboard_and_scroll_affordances_are_explicit(self) -> None:
        main = qml_source("")
        controller = qml_source("Controller")
        modal = qml_source("Modal")
        creation = qml_source("CreationFlow")
        action = qml_source("ActionDialog")
        colour = qml_source("ColourPicker")
        advanced = qml_source("Advanced")
        overview = qml_source("Overview")
        library = qml_source("Library")
        qml = "\n".join((main, controller, modal, creation, action, colour, advanced, overview, library))
        escape = main.split("Keys.onEscapePressed", 1)[1].split("Keys.onPressed", 1)[0]
        self.assertLess(escape.index("pickerController.dismissColourPicker()"), escape.index("pickerController.dismissModal()"))
        self.assertLess(escape.index("pickerController.dismissModal()"), escape.index("pickerController.requestClose()"))
        for identifier in ("modalFocusScope", "colourFocusScope", "newNameField", "duplicateNameField", "renameNameField", "modalCancelButton", "colourDoneButton", "colourHexField"):
            self.assertIn(f"id: {identifier}", qml)
        self.assertIn("function rememberOverlayFocus()", qml)
        self.assertIn("function restoreOverlayFocus()", qml)
        self.assertIn("function modalConfirmationEnabled()", qml)
        self.assertGreaterEqual(qml.count("ScrollBar.vertical: ScrollBar"), 2)
        self.assertIn("policy: ScrollBar.AlwaysOn", qml)
        self.assertIn("contentWidth: width", qml)
        semantic = overview.split("id: semanticSwatch", 1)[1].split("text: \"Terminal palette\"", 1)[0]
        self.assertIn("wrapMode: Text.WordWrap", semantic)
        self.assertIn("maximumLineCount: 2", semantic)
        self.assertNotIn("elide: Text.ElideRight", semantic)

    def test_picker_exposes_safe_import_and_export_workflows(self) -> None:
        api = qml_source("ApiController")
        dialogs = qml_source("FileDialogs")
        library = qml_source("Library")
        self.assertIn('controller.runApi("import", ["import", path]);', dialogs)
        self.assertIn('const args = ["export", controller.candidate.id, "--output", path];', dialogs)
        self.assertIn('args.push("--include-wallpaper");', dialogs)
        self.assertIn('host.runApi("list-after-import", ["list"]);', api)
        self.assertIn("Apply remains a separate action", api)
        self.assertIn("fileMode: FileDialog.SaveFile", dialogs)
        self.assertIn("enabled: !controller.dirty && !controller.busy", library)
        self.assertNotIn("preview.svg", dialogs)

    def test_cli_normalises_typographic_option_dashes(self) -> None:
        self.assertEqual(["setup", "cursor", "--yes"], cli.normalise_option_dashes(["setup", "cursor", "—-yes"]))
        self.assertEqual(["setup", "cursor", "--yes"], cli.normalise_option_dashes(["setup", "cursor", "——yes"]))
        with mock.patch.object(cli, "run", return_value=(cli.envelope("setup"), 0)) as run, mock.patch.object(cli, "emit"):
            self.assertEqual(0, cli.main(["setup", "cursor", "—-yes", "--json"]))
        parsed = run.call_args.args[0]
        self.assertEqual("cursor", parsed.feature)
        self.assertTrue(parsed.yes)

    def test_theme_picker_desktop_fallbacks_are_discoverable(self) -> None:
        applications = REPOSITORY / "applications/.local/share/applications"
        icons = REPOSITORY / "applications/.local/share/icons/hicolor/scalable/apps"
        launchers = sorted(applications.glob("blox-theme-*.desktop"))
        self.assertEqual(["blox-theme-from-wallpaper.desktop", "blox-theme-picker.desktop"], [path.name for path in launchers])
        expected_icons = {
            "blox-theme-from-wallpaper.desktop": "blox-theme-from-wallpaper",
            "blox-theme-picker.desktop": "blox-theme-picker",
        }
        for launcher in launchers:
            text = launcher.read_text(encoding="utf-8")
            self.assertIn("Type=Application", text)
            self.assertIn("Exec=blox-theme-ipc themePicker", text)
            icon = expected_icons[launcher.name]
            self.assertIn(f"Icon={icon}", text)
            self.assertTrue((icons / f"{icon}.svg").is_file())

        helper = (REPOSITORY / "shell/scripts/theme/picker-ipc.sh").read_text(encoding="utf-8")
        self.assertIn('exec "$script_root/ipc.sh" themePicker "$action"', helper)
        self.assertNotIn("ipc -c blox", helper)

        ipc_helper = (REPOSITORY / "shell/scripts/ipc.sh").read_text(encoding="utf-8")
        self.assertIn('exec quickshell ipc --pid "$main_pid" call "$@"', ipc_helper)
        self.assertNotIn("quickshell ipc -c", ipc_helper)

    def test_launcher_theme_preview_pluralises_widget_count(self) -> None:
        launcher = (PICKER_MODULES / "LauncherMainSurface.qml").read_text(encoding="utf-8")
        self.assertIn('widgetCount === 1 ? " widget" : " widgets"', launcher)


if __name__ == "__main__":
    unittest.main()
