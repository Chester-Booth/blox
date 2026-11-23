import QtQuick
import QtQuick.Window
import QtTest
import qs.modules as Modules
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "SettingsSearchTargets"
    when: windowShown

    readonly property var semanticKeys: ["background", "surface", "surface_alt", "foreground", "muted", "accent",
        "danger", "success", "warning", "info", "mauve", "teal", "selection_background", "selection_foreground", "border"]
    readonly property var ansiKeys: Array.from({length: 16}, (_, index) => "color" + index)
    readonly property var barItems: ["power", "notes", "workspaces", "clock", "active-window-title", "battery",
        "tray", "notifications", "wifi", "sound", "privacy", "awake", "display", "bt", "updates", "fan",
        "gpu", "application-tray", "touchpad"].map((id, index) => ({id, region: "start", order: index, enabled: true}))
    readonly property var defaultSettings: ({
        bar: {items: barItems, layout: {position: "top"}, style: {}},
        widgets: {schemaVersion: 1, widgets: []}, targets: {gtk: {overrides: {}}, hyprlock: {overrides: {}}}
    })

    QtObject {
        id: settingsController
        property var settings: testCase.defaultSettings
    }

    QtObject {
        id: compositionController
        property string status: "ready"
        property string errorMessage: ""
        property var provenance: ({
            generation: {themeId: "search-fixture"},
            ledgerRevision: 1,
            observedAt: "fixture",
            targets: [{target: "quickshell", files: [
                {name: "shell.conf", relativePath: "shell.conf", path: "/fixture/shell.conf", digest: "a"},
                {name: "bar.conf", relativePath: "bar.conf", path: "/fixture/bar.conf", digest: "b"}
            ]}]
        })
    }

    QtObject {
        id: applyFlow
        property string applyState: "ready"
        property string guideTarget: ""
        property string generatedFilesTitle: "Generated files"
        property string generatedFilesDetail: "Fixture files"
        property string selectedThemeName: "Search fixture"
        property string applyMessage: ""
        property string failureMessage: ""
        property string failureSummary: ""
        property string guidePath: "/fixture/guide"
        property int applyProgress: 0
        property int reviewTargetCount: 2
        property bool dirty: true
        property bool canRetryApply: false
        property bool recoveryAvailable: false
        property var applyTargets: []
        property var applyStages: []
        property var actions: ({rollBack: false, retryFailedTargets: [], keepSuccessfulChanges: false})
        function startApply() {}
        function discardEdits() {}
        function finishApply() {}
        function completeQuickshellReload() {}
        function copyApplyError() {}
        function retryFailedTargets() {}
        function retryApply() {}
        function rollBackApply() {}
        function keepSuccessfulChanges() {}
        function openApplyGuide(target) {}
        function copyGuidePath() {}
    }

    QtObject {
        id: themeController
        property var candidate: null
        property bool themeControlsEnabled: false
        property bool busy: false
        property string selectedId: "search-fixture"
        property string wallpaperFilter: "All"
        property bool browserTargetsLoaded: true
        property var browserTargetInfoByKey: ({
            helium: {available: true, reason: "", label: "Helium"},
            chromium: {available: true, reason: "", label: "Chromium"}
        })
        property var semanticKeys: testCase.semanticKeys
        property var ansiKeys: testCase.ansiKeys
        property var fontFamilies: ["Sans", "Mono"]
        property var previewData: ({ansi: ({})})
        property var iconThemeNames: ["Papirus", "Adwaita"]
        property var iconThemeOptions: [{id: "Papirus"}, {id: "Adwaita"}]
        property var iconSampleKeys: ["house", "gear"]
        readonly property var targetKeys: ["quickshell", "widgets", "gtk", "helium", "chromium", "cursor", "wallpaper",
            "kitty", "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "t3code", "zed",
            "stylus", "obsidian", "powerlevel10k", "sddm", "grub"]
        function effectiveWindowGap() { return 5; }
        function filteredWallpapers() { return []; }
        function wallpaperItemSelected(item) { return false; }
        function localFileUrl(path) { return ""; }
        function targetAvailable(key) {
            if (key === "helium" || key === "chromium")
                return browserTargetsLoaded && browserTargetInfoByKey[key] && browserTargetInfoByKey[key].available === true;
            return key !== "sddm" && key !== "grub";
        }
        function browserTargetInfo(key) { return browserTargetInfoByKey[key] || null; }
        function targetApplyMode(key) { return key === "stylus" ? "manual" : "automatic"; }
        function targetLabel(key) { return key === "t3code" ? "T3Code" : key === "zed" ? "Zed" : key; }
        function targetModeLabel(key) { return "Automatic"; }
        function swatchText(colour) { return "#ffffff"; }
    }

    QtObject {
        id: regularOwner
        property var settingsController: settingsController
        property var themeEditorController: null
        property var compositionProviderController: compositionController
        property bool mutationProtected: false
        property bool settingsMutationPending: false
        property bool hasUnappliedChanges: false
        function settingsValue(path, fallback) { return fallback; }
        function writeSettingsValue(path, value) {}
        function openSettingsSection(category, section) {}
        function clearTargetOverride(target, colour) {}
        function openStylusGuide() {}
        function downloadGeneratedArchive(target) {}
        function downloadGeneratedFile(target, path) {}
        function downloadGuideFile(target) {}
    }

    QtObject {
        id: widgetController
        property var widgetCatalogue: null
        property var widgetSchema: null
        property string widgetDraftError: ""
        property bool widgetControlsEnabled: true
        function widgetItems() { return settingsController.settings.widgets.widgets; }
    }
    QtObject {
        id: widgetOwner
        property var settingsController: settingsController
        property var themeEditorController: widgetController
        property bool mutationProtected: false
        property string widgetMetadataError: ""
        function beginWidgetEditMode() {}
    }

    QtObject {
        id: colourOwner
        property var settingsController: settingsController
        property var themeEditorController: themeController
        property var compositionProviderController: compositionController
        property bool mutationProtected: false
        function settingsValue(path, fallback) { return fallback; }
        function writeSettingsValue(path, value) {}
        function openSettingsColourPicker(key, target, anchor, fallback, callback) {}
    }

    QtObject {
        id: targetOwner
        property var settingsController: settingsController
        property var themeEditorController: themeController
        property var compositionProviderController: compositionController
        property bool mutationProtected: false
        function settingsValue(path, fallback) { return fallback; }
        function writeSettingsValue(path, value) {}
        function clearTargetOverride(target, colour) {}
        function openStylusGuide() {}
        function downloadGeneratedArchive(target) {}
        function downloadGeneratedFile(target, path) {}
    }

    Services.SettingsShellState { id: state }

    Component { id: themePage; Modules.SettingsThemePage { windowOwner: regularOwner; width: 960; height: implicitHeight } }
    Component { id: themeAdvancedPage; Modules.SettingsThemeAdvancedPage { windowOwner: regularOwner; width: 960; height: implicitHeight } }
    Component { id: barPage; Modules.SettingsBarPage { windowOwner: regularOwner; width: 960; height: implicitHeight } }
    Component { id: barAdvancedPage; Modules.SettingsBarAdvancedPage { windowOwner: regularOwner; width: 960; height: implicitHeight } }
    Component { id: barItemsPage; Modules.SettingsBarItemsPage { windowOwner: regularOwner; width: 960; height: implicitHeight } }
    Component { id: coloursPage; Modules.SettingsColoursPage { windowOwner: colourOwner; width: 960; height: implicitHeight } }
    Component { id: windowsPage; Modules.SettingsWindowsPage { windowOwner: regularOwner; width: 960; height: implicitHeight } }
    Component { id: widgetsPage; Modules.SettingsWidgetsPage { windowOwner: widgetOwner; width: 960; height: implicitHeight } }
    Component { id: targetsPage; Modules.SettingsTargetsPage { windowOwner: targetOwner; width: 960; height: implicitHeight } }
    Component { id: reviewPage; Modules.SettingsApplyReviewPage { windowOwner: regularOwner; flowState: applyFlow; width: 960; height: implicitHeight } }

    Window {
        id: testWindow
        width: 1000
        height: 1000
        visible: true

        Item {
            anchors.fill: parent
            Loader { id: themeLoader; anchors.fill: parent; sourceComponent: themePage }
            Loader { id: themeAdvancedLoader; anchors.fill: parent; sourceComponent: themeAdvancedPage }
            Loader { id: barLoader; anchors.fill: parent; sourceComponent: barPage }
            Loader { id: barAdvancedLoader; anchors.fill: parent; sourceComponent: barAdvancedPage }
            Loader { id: barItemsLoader; anchors.fill: parent; sourceComponent: barItemsPage }
            Loader { id: coloursLoader; anchors.fill: parent; sourceComponent: coloursPage }
            Loader { id: windowsLoader; anchors.fill: parent; sourceComponent: windowsPage }
            Loader { id: widgetsLoader; anchors.fill: parent; sourceComponent: widgetsPage }
            Loader { id: targetsLoader; anchors.fill: parent; sourceComponent: targetsPage }
            Loader { id: reviewLoader; anchors.fill: parent; sourceComponent: reviewPage }
        }
    }

    function routePage(category, page) {
        const key = category + "/" + page;
        const routes = {
            "theme/landing": themeLoader,
            "theme/advanced": themeAdvancedLoader,
            "bar/landing": barLoader,
            "bar/advanced": barAdvancedLoader,
            "bar-items/landing": barItemsLoader,
            "colours/landing": coloursLoader,
            "windows/landing": windowsLoader,
            "widgets/landing": widgetsLoader,
            "targets/landing": targetsLoader,
            "review/landing": reviewLoader
        };
        return routes[key] || null;
    }

    function waitForPages() {
        [themeLoader, themeAdvancedLoader, barLoader, barAdvancedLoader, barItemsLoader, coloursLoader,
            windowsLoader, widgetsLoader, targetsLoader].forEach(loader => {
            tryCompare(loader, "status", Loader.Ready);
        });
        tryCompare(reviewLoader, "status", Loader.Ready);
    }

    function checkResult(result) {
        const loader = routePage(result.category, result.page);
        verify(loader, "missing page route for " + result.category + "/" + result.page + " " + result.label);
        const page = loader.item;
        verify(page, "page did not load for " + result.label);
        const section = page.sectionFor(result.section);
        verify(section && section.item, "missing section " + result.section + " for " + result.label);
        const target = page.targetFor(result.section, result.label);
        verify(target, "missing named target for " + result.category + "/" + result.section + ": " + result.label);
        verify(target !== section.item, "search fell back to its whole section for " + result.label);
        verify(target.objectName.length > 0, "target has no stable objectName for " + result.label);
        verify(target.visible, "target is not visible for " + result.label);
        verify(page.jumpToTarget(result.section, result.label, result.kind), "jump failed for " + result.label);
        compare(page.flashItem, target);
        verify(page.flashWidth > 0 && page.flashHeight > 0, "target flash has no bounds for " + result.label);
    }

    function initTestCase() {
        function json(path) {
            const request = new XMLHttpRequest();
            request.open("GET", Qt.resolvedUrl(path), false);
            request.send();
            return JSON.parse(request.responseText);
        }
        widgetController.widgetCatalogue = json("../../widgets/catalogue.json");
        widgetController.widgetSchema = json("../../widgets/schema/profile.schema.json");
        waitForPages();
    }

    function test_apply_actions_follow_edits_and_result_content() {
        const page = reviewLoader.item;
        applyFlow.applyState = "ready";
        regularOwner.hasUnappliedChanges = false;
        const discard = page.findObjectName(page, "apply-discard-edits");
        verify(discard.visible);
        verify(!discard.enabled);
        regularOwner.hasUnappliedChanges = true;
        verify(discard.enabled);
        regularOwner.hasUnappliedChanges = false;
        applyFlow.applyState = "failure-activate-restored";
        applyFlow.canRetryApply = true;
        applyFlow.failureMessage = "Obsidian failed";
        applyFlow.applyStages = ["Prepare", "Cursor assets", "Activate", "Applications"].map(name => ({name, state: "done", message: ""}));
        wait(0);
        const retry = page.findObjectName(page, "apply-retry");
        const done = page.findObjectName(page, "apply-complete");
        verify(retry.visible);
        verify(done.visible);
        verify(done.mapToItem(page, 0, 0).y < 430);
        applyFlow.applyState = "ready";
        applyFlow.canRetryApply = false;
        applyFlow.failureMessage = "";
        applyFlow.applyStages = [];
    }

    function test_unavailable_browser_target_shows_compact_probe_reason() {
        const cases = [
            {reason: "Helium is not installed", label: "Not installed"},
            {reason: "Helium executable is not executable", label: "Not executable"},
            {reason: "stale or unsupported Helium desktop entry; no executable browser matched", label: "Stale desktop entry"},
            {reason: "ambiguous browser installation: more than one Helium executable matched", label: "Multiple installs"}
        ];
        themeController.browserTargetInfoByKey = {
            helium: {available: false, reason: cases[0].reason, label: "Helium"},
            chromium: {available: true, reason: "", label: "Chromium"}
        };
        wait(0);
        const page = targetsLoader.item;
        const helium = page.findObjectName(page, "theme-target-control-helium");
        const heliumStatus = page.findObjectName(page, "theme-target-status-helium");
        verify(helium);
        verify(heliumStatus);
        verify(!helium.enabled);
        for (const entry of cases) {
            themeController.browserTargetInfoByKey = {
                helium: {available: false, reason: entry.reason, label: "Helium"},
                chromium: {available: true, reason: "", label: "Chromium"}
            };
            wait(0);
            compare(heliumStatus.text, entry.label);
        }

        const chromiumStatus = page.findObjectName(page, "theme-target-status-chromium");
        verify(chromiumStatus);
        compare(chromiumStatus.text, "Automatic");
    }

    function test_every_indexed_setting_result_resolves_to_a_rendered_control() {
        const entries = state.searchIndex.filter(entry => entry.section.length > 0);
        compare(entries.length, state.searchIndex.length);
        for (const entry of entries) {
            state.settingsSearch = entry.label;
            const result = state.searchResults().find(current => current.category === entry.category
                && current.page === entry.page && current.section === entry.section && current.label === entry.label);
            verify(result, "index entry did not produce a result: " + entry.label);
            state.openSearchResult(result);
            compare(state.category, entry.category);
            compare(state.page, entry.page);
            compare(state.section, entry.section);
            compare(state.selectedSearchLabel, entry.label);
            checkResult(result);
        }
    }

    function test_category_page_results_use_their_mapped_first_control() {
        for (const category of state.categories) {
            state.settingsSearch = category.label;
            const result = state.searchResults().find(entry => entry.category === category.id && entry.kind === "Page");
            if (!result)
                continue;
            state.openSearchResult(result);
            checkResult(result);
        }
    }
}
