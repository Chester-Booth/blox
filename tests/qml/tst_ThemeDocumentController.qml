import "../../shell/shared" as Shared
import "../../shell/shared/Shape.js" as Shape
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "ThemeDocumentController"

    function generatedTheme(id, canvas) {
        return JSON.stringify({
            "schema_version": 1,
            "id": id,
            "variant": "dark",
            "colours": {
                "background": "#111111", "surface": "#222222", "surface_alt": "#333333",
                "foreground": "#eeeeee", "muted": "#aaaaaa", "accent": "#9999ff",
                "selection_foreground": "#111111", "border": "#555555"
            },
            "compatibility": {
                "red": "#ff0000", "green": "#00ff00", "yellow": "#ffff00",
                "blue": "#0000ff", "mauve": "#ff00ff", "teal": "#00ffff"
            },
            "fonts": {"panel": "Panel", "mono": "Mono", "ui": "UI"},
            "shape": {"radius_scale": 1.25, "density_scale": 1.0},
            "terminal": {"canvas": canvas, "chrome_background": "#222222", "ansi_source": "derived"}
        });
    }

    function sourceTheme(id, canvas) {
        const data = JSON.parse(generatedTheme(id, canvas));
        data.colours.danger = data.compatibility.red;
        data.colours.success = data.compatibility.green;
        data.colours.warning = data.compatibility.yellow;
        data.colours.info = data.compatibility.blue;
        data.colours.mauve = data.compatibility.mauve;
        data.colours.teal = data.compatibility.teal;
        delete data.compatibility;
        return data;
    }

    function init() {
        defaults.document = readJson("../../themes/defaults/v1.json");
        defaults.ready = true;
        target.terminalCanvas = "transparent";
    }

    function readJson(relativePath) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(relativePath), false);
        request.send();
        verify(request.status === 0 || request.status === 200);
        return JSON.parse(request.responseText);
    }

    function stable(value) {
        if (Array.isArray(value))
            return value.map(item => stable(item));
        if (value && typeof value === "object") {
            const result = { };
            for (const key of Object.keys(value).sort())
                result[key] = stable(value[key]);
            return result;
        }
        return value;
    }

    function test_sparse_fixture_matches_python_resolution() {
        const source = readJson("fixtures/sparse-theme.json");
        const expected = readJson("fixtures/resolved-sparse-theme.json");
        compare(JSON.stringify(stable(controller.resolvedSource(source))), JSON.stringify(stable(expected)));
    }

    function test_reset_uses_the_canonical_terminal_canvas() {
        compare(controller.reset(), "catppuccin-frappe");
        compare(target.terminalCanvas, "#303446");
    }

    function test_generated_and_preview_themes_switch_terminal_canvas() {
        verify(controller.loadJson(generatedTheme("first", "#123456")));
        compare(target.terminalCanvas, "#123456");

        verify(controller.previewSource(sourceTheme("second", "#654321")));
        compare(target.terminalCanvas, "#654321");
    }

    function test_shape_derivation_matches_python_cases() {
        const cases = [
            {"radius": 0, "density": 0.75, "gap": undefined, "derivedRadius": 0, "derivedGap": 0},
            {"radius": 0.65, "density": 1.0, "gap": undefined, "derivedRadius": 8, "derivedGap": 5},
            {"radius": 1.25, "density": 1.5, "gap": undefined, "derivedRadius": 15, "derivedGap": 15},
            {"radius": 2, "density": 1.0, "gap": 30, "derivedRadius": 24, "derivedGap": 30}
        ];
        for (const entry of cases) {
            const shape = {"radius_scale": entry.radius, "density_scale": entry.density};
            if (entry.gap !== undefined)
                shape.window_gap = entry.gap;
            compare(Shape.roundScaled(Shape.HYPRLAND_RADIUS_BASE, entry.radius), entry.derivedRadius);
            compare(Shape.roundScaled(Shape.GTK_RADIUS_BASE, entry.radius), entry.derivedRadius);
            compare(Shape.effectiveWindowGap(shape), entry.derivedGap);
        }
    }

    Shared.ThemeDefaults {
        id: defaults
    }

    QtObject {
        id: target

        property var previewActive: false
        property var previewThemeId: ""
        property var themeId: ""
        property var activeThemeId: ""
        property var activeIconTheme: ""
        property var variant: ""
        property var background
        property var surface
        property var surfaceAlt
        property var foreground
        property var muted
        property var red
        property var green
        property var yellow
        property var accent
        property var blue
        property var mauve
        property var teal
        property var selectionForeground
        property var border
        property var terminalCanvas
        property var radiusScale
        property var densityScale
        property var windowGap
        property var fontFamily
        property var monoFontFamily
        property var bodyFontFamily
        property var barPosition
        property var barItems: []
        property var osdPosition
        property var osdOffsetX
        property var osdOffsetY
        property var notificationPosition
        property var notificationOffsetX
        property var notificationOffsetY
        property var widgetProfile
        property var widgetOpacity
        property var widgetPadding
        property var widgetRadius
        property var widgetBasePadding
        property var widgetBaseRadius
        property var widgetFontSize
        property var widgetItems: []

        function builtinBarItems() {
            return [];
        }
    }

    Shared.ThemeDocumentController {
        id: controller
        theme: target
        defaults: defaults
    }
}
