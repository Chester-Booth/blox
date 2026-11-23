import QtQuick
import QtTest
import qs.services

TestCase {
    id: testCase
    name: "SettingsBundleController"
    QtObject {
        id: fakeSettings
        property var settings: ({targets: {kitty: {enabled: true}, gtk: {enabled: false}}})
        property string requestedAction: ""
        function begin(action, payload) { requestedAction = action; return JSON.stringify({code: "pending", data: {requestId: "fixture"}}); }
        function poll(id) { return JSON.stringify({code: "pending"}); }
    }
    QtObject {
        id: library
        property var themes: []
        property string status: "ready"
        property string selectedThemeId: "probe"
        property string appliedThemeId: "probe"
        function refresh() { status = "loading"; }
        function cardFor(id) { return {id: id, name: id}; }
    }
    QtObject {
        id: editor
        property string selectedId: "probe"
        property bool dirty: false
        property bool busy: false
        property var candidate: ({id: "probe", colours: {accent: "#112233"}})
        property int reloads: 0
    }
    QtObject {
        id: owner
        property var settingsController: fakeSettings
        property bool settingsMutationPending: false
        property var themeEditorController: editor
        property var libraryProvider: library
        property bool windowOpen: true
        property int selections: 0
        property bool forced: false
        function selectTheme(id, force) {
            if (editor.dirty) { settingsFeedback = "Apply or discard existing edits"; return false; }
            selections++; forced = force; library.selectedThemeId = id; editor.selectedId = id;
            if (force) { editor.reloads++; editor.candidate = {id: id, colours: {accent: "#445566"}}; }
            return true;
        }
        function navigateTo(category, page, section) {}
        property string settingsFeedback: ""
        function restoreFocusAfterDialog() {}
    }
    SettingsBundleController { id: bundle; windowOwner: owner }
    function init() {
        bundle.pendingImportedThemeId = "";
        library.themes = []; library.status = "ready"; library.selectedThemeId = "probe";
        editor.selectedId = "probe"; editor.dirty = false; editor.busy = false; editor.reloads = 0;
        editor.candidate = {id: "probe", colours: {accent: "#112233"}};
        owner.selections = 0; owner.windowOpen = true;
        SettingsApplyController.busy = false;
        bundle.busy = false;
        bundle.chooseBundle("standard");
        bundle.copyImportedTheme = false; bundle.replaceImportedTheme = false;
        bundle.importState = "valid"; bundle.selectedImportSections = ["appearance"];
    }
    function test_target_omission_is_custom_without_changing_saved_targets() {
        bundle.toggleExportTarget("kitty", false);
        compare(bundle.bundleLevel, "custom");
        compare(bundle.selectedExportTargets, ["gtk"]);
        verify(owner.settingsController.settings.targets.kitty.enabled);
        bundle.chooseBundle("standard");
        compare(bundle.bundleLevel, "standard");
    }
    function test_wallpaper_is_optional_and_selection_invalidates_approvals() {
        bundle.sensitiveImportFiles = [{id: "a", path: "assets/scripts/a.sh", sha256: "reviewed"}];
        bundle.approvedSensitiveFiles = ["a"];
        compare(bundle.approvals()["assets/scripts/a.sh"], "reviewed");
        bundle.toggleExportComponent("wallpaper", false);
        verify(!bundle.exportComponentSelected("wallpaper"));
        compare(bundle.bundleLevel, "custom");
        compare(bundle.approvedSensitiveFiles, []);
    }
    function test_cancel_cannot_hide_an_active_mutation() {
        bundle.dialogKind = "import-review";
        bundle.busy = true;
        bundle.closeBundleDialog();
        compare(bundle.dialogKind, "import-review");
        bundle.busy = false;
        bundle.closeBundleDialog();
        compare(bundle.dialogKind, "");
    }
    function test_import_core_appearance_is_optional() {
        bundle.selectedImportSections = ["theme-metadata", "appearance", "bar"];
        bundle.toggleImportSection("appearance", false);
        verify(bundle.selectedImportSections.indexOf("appearance") < 0);
        verify(bundle.importCanContinue());
    }
    function test_conflict_requires_replace_or_copy_choice() {
        bundle.importState = "conflict";
        verify(!bundle.importCanContinue());
        bundle.copyImportedTheme = true;
        verify(bundle.importCanContinue());
        bundle.copyImportedTheme = false;
        bundle.replaceImportedTheme = true;
        verify(bundle.importCanContinue());
    }
    function test_approval_step_is_only_shown_when_files_exist() {
        bundle.sensitiveImportFiles = [{id: "script"}];
        bundle.bundleStep = "sections";
        bundle.continueImportSections();
        compare(bundle.bundleStep, "sensitive");
        bundle.sensitiveImportFiles = [];
        bundle.selectedImportSections = ["appearance"];
        bundle.bundleStep = "sections";
        bundle.continueImportSections();
        compare(fakeSettings.requestedAction, "bundle-import");
        compare(bundle.bundleStep, "progress");
    }
    function test_open_import_waits_for_async_library_then_routes_through_window_owner() {
        library.status = "loading";
        bundle.importedCard = {id: "incoming", name: "Incoming", palette: []};
        bundle.completeBundleImport();
        compare(owner.selections, 0);
        compare(editor.selectedId, "probe");
        library.themes = [{id: "incoming", name: "Incoming"}];
        library.status = "ready";
        tryCompare(editor, "selectedId", "incoming");
        compare(library.selectedThemeId, "incoming");
        verify(owner.forced);
        compare(editor.candidate.id, "incoming");
        compare(bundle.pendingImportedThemeId, "");
    }
    function test_same_id_import_forces_source_reload() {
        library.themes = [{id: "probe", name: "Replaced"}];
        bundle.importedCard = {id: "probe", name: "Replaced", palette: []};
        bundle.completeBundleImport();
        compare(editor.reloads, 1);
        compare(editor.candidate.colours.accent, "#445566");
    }
    function test_dirty_edits_are_preserved_until_user_resolves_them() {
        library.themes = [{id: "incoming", name: "Incoming"}];
        editor.dirty = true;
        bundle.importedCard = {id: "incoming", name: "Incoming", palette: []};
        bundle.completeBundleImport();
        compare(owner.selections, 0);
        compare(editor.selectedId, "probe");
        verify(editor.dirty);
        editor.dirty = false;
        tryCompare(editor, "selectedId", "incoming");
    }
    function test_closing_cancels_deferred_import_selection() {
        library.themes = [{id: "incoming", name: "Incoming"}];
        editor.dirty = true;
        bundle.importedCard = {id: "incoming", name: "Incoming", palette: []};
        bundle.completeBundleImport();
        compare(bundle.pendingImportedThemeId, "incoming");
        owner.windowOpen = false;
        editor.dirty = false;
        wait(20);
        compare(bundle.pendingImportedThemeId, "");
        compare(editor.selectedId, "probe");
        owner.windowOpen = true;
        wait(20);
        compare(owner.selections, 0);
    }
    function test_unapproved_script_is_absent_from_request() {
        bundle.sensitiveImportFiles = [{id: "a", path: "assets/scripts/a.sh", sha256: "reviewed"}, {id: "b", path: "assets/scripts/b.sh", sha256: "other"}];
        bundle.approvedSensitiveFiles = ["a"];
        compare(Object.keys(bundle.approvals()), ["assets/scripts/a.sh"]);
    }
}
