import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    name: "SettingsShellState"

    Services.SettingsShellState {
        id: state
    }

    function init() {
        state.category = "review";
        state.page = "landing";
        state.section = "";
        state.settingsSearch = "";
        state.searchResultsOpen = false;
        state.activeSearchCategory = "all";
        state.suggestionIndex = 0;
        state.selectedSearchLabel = "";
        state.selectedSearchKind = "";
    }

    function test_starts_on_apply_review_without_home() {
        compare(state.category, "review");
        compare(state.categoryLabel(state.category), "Apply & review");
        verify(!state.categories.some(entry => entry.id === "home"));
    }

    function test_command_output_search_routes_to_widget_label() {
        state.settingsSearch = "command output";
        const result = state.searchResults().find(entry => entry.label === "Command output widget");
        verify(result);
        state.openSearchResult(result);
        compare(state.category, "widgets");
        compare(state.section, "widgets");
        compare(state.selectedSearchLabel, "Command output widget");
    }

    function test_search_suggestion_routes_apply_to_review() {
        state.settingsSearch = "appl";
        const suggestions = state.suggestionResults();
        verify(suggestions.length > 0);
        compare(suggestions[0].category, "review");
        state.openSearchResult(suggestions[0]);
        compare(state.category, "review");
        compare(state.page, "landing");
        compare(state.section, "apply-review");
        compare(state.selectedSearchLabel, "Apply & review");
        verify(!state.searchResultsOpen);
    }

    function test_search_result_routes_to_theme_wallpaper() {
        state.settingsSearch = "wallpaper";
        const result = state.searchResults().find(entry => entry.section === "wallpaper");
        verify(result);
        state.openSearchResult(result);
        compare(state.category, "theme");
        compare(state.section, "wallpaper");
    }

    function test_search_result_retains_exact_highlight_label() {
        state.settingsSearch = "icon theme";
        const result = state.searchResults().find(entry => entry.label === "Icon theme");
        verify(result);
        state.openSearchResult(result);
        compare(state.category, "colours");
        compare(state.section, "icons");
        compare(state.selectedSearchLabel, "Icon theme");
        compare(state.selectedSearchKind, "Setting");
    }

    function test_search_keeps_distinct_controls_within_one_section() {
        state.settingsSearch = "round";
        const results = state.searchResults().filter(entry => entry.category === "theme" && entry.section === "style");
        verify(results.some(entry => entry.label === "Theme roundness"));
        verify(results.some(entry => entry.label === "Slightly round corners"));
        const exact = results.find(entry => entry.label === "Slightly round corners");
        state.openSearchResult(exact);
        compare(state.selectedSearchLabel, "Slightly round corners");
        compare(state.selectedSearchKind, "Setting");
        compare(state.section, "style");
    }

    function test_numeric_palette_search_does_not_match_larger_indices() {
        state.settingsSearch = "color 1";
        const terminalResults = state.searchResults().filter(entry => entry.section === "terminal");
        verify(terminalResults.some(entry => entry.label === "Terminal colour 1"));
        verify(!terminalResults.some(entry => entry.label === "Terminal colour 10"));
    }

    function test_search_keeps_all_categories_visible_and_filters_sections() {
        state.settingsSearch = "th";
        const visibleIds = state.visibleCategories().map(entry => entry.id);
        compare(visibleIds.length, state.categories.length);
        verify(visibleIds.includes("widgets"));
        verify(visibleIds.includes("review"));

        state.settingsSearch = "wallpaper";
        const themeSections = state.filteredSectionsFor("theme");
        compare(themeSections.length, 1);
        compare(themeSections[0].id, "wallpaper");
    }
}
