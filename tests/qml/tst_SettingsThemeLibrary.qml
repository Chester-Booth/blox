import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    name: "SettingsThemeLibrary"

    Services.SettingsThemeLibrary {
        id: library
    }

    function init() {
        library.themes = [
            {id: "blox-panel", name: "Default", builtin: true, preview: {}},
            {id: "custom-night", name: "Custom Night", builtin: false, preview: {
                colours: {background: "#111111", surface: "#222222", accent: "#80aaff"},
                bar: {position: "bottom", items: []}, fonts: {ui: "sans-serif"}
            }}
        ];
        library.selectedThemeId = "blox-panel";
    }

    function test_selecting_theme_changes_only_the_shelf_selection() {
        const result = library.selectTheme("custom-night");
        verify(result.ok);
        compare(result.code, "ok");
        compare(result.data.selectedThemeId, "custom-night");
        compare(result.data.appliedThemeId, "blox-panel");
        verify(result.data.changed);
        verify(library.dirty);
        compare(library.appliedThemeId, "blox-panel");
    }

    function test_card_data_uses_read_theme_preview_fields() {
        const card = library.cardFor("custom-night");
        compare(card.name, "Custom Night");
        compare(card.preview.background, "#111111");
        compare(card.barPosition, "bottom");
        compare(card.builtin, false);
    }
}
