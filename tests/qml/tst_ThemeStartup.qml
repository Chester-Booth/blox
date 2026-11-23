import "../../shell/shared" as Runtime
import QtQuick
import QtTest

TestCase {
    name: "ThemeStartup"

    function readJson(relativePath) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(relativePath), false);
        request.send();
        verify(request.status === 0 || request.status === 200);
        return JSON.parse(request.responseText);
    }

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

    function sourceTheme(id) {
        const data = JSON.parse(generatedTheme(id, "#123456"));
        data.colours.danger = data.compatibility.red;
        data.colours.success = data.compatibility.green;
        data.colours.warning = data.compatibility.yellow;
        data.colours.info = data.compatibility.blue;
        data.colours.mauve = data.compatibility.mauve;
        data.colours.teal = data.compatibility.teal;
        delete data.compatibility;
        return data;
    }

    function test_fresh_missing_or_invalid_theme_uses_validated_defaults() {
        const theme = Runtime.Theme;
        const defaults = theme.data[0];
        const defaultsFile = defaults.defaultsFile;
        const themeFile = theme.data.find((part) => part.path && part.path.endsWith("/current/quickshell/theme.json"));
        const defaultsText = JSON.stringify(readJson("../../themes/defaults/v1.json"));

        verify(themeFile !== undefined);

        defaultsFile.fixtureText = "{}";
        defaultsFile.loaded();
        verify(!defaults.ready);
        theme.ready = false;
        themeFile.loadFailed("generated theme is missing");
        verify(!theme.ready);

        defaultsFile.fixtureText = defaultsText;
        defaultsFile.loaded();
        verify(defaults.ready);

        theme.ready = false;
        theme.previewActive = false;
        theme.themeId = "";
        themeFile.fixtureText = "";
        themeFile.loadFailed("generated theme is missing");

        verify(theme.ready);
        compare(theme.themeId, defaults.themeDocument().id);
        verify(theme.barItems.length > 0);

        theme.ready = false;
        theme.themeId = "";
        themeFile.fixtureText = "{}";
        themeFile.loaded();
        verify(theme.ready);
        compare(theme.themeId, defaults.themeDocument().id);

        themeFile.fixtureText = generatedTheme("generated-theme", "#654321");
        themeFile.loaded();
        verify(theme.ready);
        compare(theme.themeId, "generated-theme");

        verify(theme.previewSource(sourceTheme("preview-theme")));
        themeFile.loadFailed("generated theme disappeared during preview");
        verify(theme.previewActive);
        compare(theme.themeId, "preview-theme");

        theme.cancelPreview();
        compare(theme.themeId, "generated-theme");
        themeFile.loadFailed("generated theme disappeared after loading");
        verify(theme.ready);
        compare(theme.themeId, "generated-theme");
    }
    function test_registry_scan_survives_eligibility_changes_and_ignores_newer_result() {
        const theme = Runtime.Theme;
        theme.widgetRegistryLoaded = false;
        theme.widgetRegistry = ({});
        theme.widgetItems = [{id: "registered", kind: "qml", enabled: true}];
        verify(theme.widgetRegistryProcess.running);
        theme.widgetItems = [];
        verify(theme.widgetRegistryProcess.running);
        theme.widgetRegistry = {newer: {name: "Settings result"}};
        theme.widgetRegistryLoaded = true;
        theme.widgetRegistryProcess.stdout.text = "";
        theme.widgetRegistryProcess.stdout.streamFinished();
        compare(theme.widgetRegistry.newer.name, "Settings result");
        theme.widgetRegistryProcess.finish(0, 0);
        theme.widgetRegistryLoaded = false;
        theme.widgetItems = [{id: "registered", kind: "qml", enabled: true}];
        verify(theme.widgetRegistryProcess.running);
        theme.widgetRegistryProcess.stdout.text = JSON.stringify({ok: true, registry: {valid: {name: "Runtime result"}}});
        theme.widgetRegistryProcess.stdout.streamFinished();
        verify(theme.widgetRegistryLoaded);
        compare(theme.widgetRegistry.valid.name, "Runtime result");
        theme.widgetRegistryProcess.finish(0, 0);
        theme.widgetItems = [];
    }

    function test_missing_widget_profile_clears_previous_runtime_items() {
        const theme = Runtime.Theme;
        const file = theme.data.find(part => part.path && part.path.endsWith("/current/widgets/profile.json"));
        verify(file !== undefined);
        theme.previewActive = false;
        theme.widgetItems = [{id: "notes", kind: "notes", enabled: true}];
        file.loadFailed("missing fixture");
        compare(theme.widgetItems.length, 0);
        verify(theme.widgetError.length > 0);
    }

}
