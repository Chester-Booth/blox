import QtQuick
import QtTest
import qs.shared

TestCase {
    id: testCase
    name: "SettingsWidgetHydration"
    property var subject: null
    QtObject {
        id: provider
        property var settings: ({widgets: {schemaVersion: 1, widgets: []}})
        property int revision: 4
        property var submitted: null
        property var submissions: []
        property bool saveReady: false
        function begin(operation, payload) {
            submitted = JSON.parse(payload);
            submissions = submissions.concat([submitted]);
            saveReady = false;
            return JSON.stringify({code: "pending", data: {requestId: "fixture"}});
        }
        function poll(requestId) { return JSON.stringify(saveReady ? {ok: true, code: "ok"} : {code: "pending"}); }
        function completeSave() {
            settings = Object.assign({}, settings, submitted.sections);
            revision++;
            saveReady = true;
        }
    }
    QtObject {
        id: editor
        property var candidate: null
        property var sourceTheme: null
        property var touchedPaths: []
        property var themes: []
        property bool busy: false
        property bool selectedThemeBuiltin: false
        property string selectedId: "fixture"
        function widgetItems() { return candidate.widgets.widgets; }
    }
    QtObject { id: timer; property int starts: 0; function start() { starts++; } function restart() { starts++; } }
    QtObject {
        id: applyOwner
        property int calls: 0
        property bool prepared: false
        function startApply() { calls++; prepared = subject.prepareSettingsForApply(); }
        function abortPreparation(message) { testCase.fail(message); }
    }
    function productionFunction(source, name) {
        const start = source.indexOf("    function " + name + "(");
        let index = source.indexOf("{", start), depth = 1;
        while (depth && ++index < source.length) {
            if (source[index] === "{") depth++;
            if (source[index] === "}") depth--;
        }
        return source.slice(start, index + 1);
    }
    function initTestCase() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/modules/SettingsWindow.qml"), false);
        request.send();
        subject = Qt.createQmlObject('import QtQuick; import qs.shared; QtObject { property var settingsController; property var themeEditorController; property var activeWidgetsAtOpen: []; property var draftSettingsWrites: ({}); property var draftUserWrites: ({}); property bool draftUserEdited: false; property bool applyingSettingsDraft: false; property bool settingsMutationPending: false; property bool pendingSettingsRead: false; property bool widgetEditorReadReady: true; property var pendingSettingsWrites: ({}); property var activeSettingsWrite: ({}); property bool windowOpen: true; property bool importedSourceReloadPending: false; property string stagedThemeTargetsId: ""; property string settingsFeedback: ""; property string pendingSettingsRequestId: ""; property string pendingSettingsOperation: ""; property var settingsReadTimer; property var applyOwner; function startSettingsRead() {} function startNextSettingsWrite() {} '
            + productionFunction(request.responseText, "resolvedSettings") + productionFunction(request.responseText, "prepareEditorSource") + productionFunction(request.responseText, "prepareSettingsForApply") + productionFunction(request.responseText, "stageThemeTargets")
            + productionFunction(request.responseText, "pollSettingsRead").replace(/SettingsApplyController/g, "applyOwner") + '}', testCase, "SettingsWidgetFunctions");
        subject.settingsController = provider;
        subject.themeEditorController = editor;
        subject.settingsReadTimer = timer;
        subject.applyOwner = applyOwner;
    }
    function widgetProfile() {
        return {schemaVersion: 1, widgets: [{id: "clock", name: "Clock", kind: "clock", enabled: true,
            placement: {anchor: "top-right", x: 24, y: 32, width: 280, height: 160},
            workspaces: {mode: "include", ids: [2, "special:desk"], ranges: [[4, 6]]}, visibility: "always",
            appearance: {backgroundOpacity: 0.35, scrollbars: "hide"}, fullscreen: {enabled: true, mode: "native"},
            settings: {style: "analogue", timezone: "local", format: "24h", showSeconds: true}}]};
    }
    function init() {
        subject.activeWidgetsAtOpen = [];
        subject.draftSettingsWrites = ({});
        subject.applyingSettingsDraft = false;
        subject.draftUserEdited = false;
        subject.settingsMutationPending = false;
        subject.pendingSettingsRead = false;
        subject.pendingSettingsRequestId = "";
        subject.pendingSettingsOperation = "";
        subject.pendingSettingsWrites = ({});
        subject.activeSettingsWrite = ({});
        subject.stagedThemeTargetsId = "";
        provider.settings = {widgets: {schemaVersion: 1, widgets: []}};
        provider.submitted = null;
        provider.submissions = [];
        provider.saveReady = false;
        applyOwner.calls = 0;
        applyOwner.prepared = false;
        editor.candidate = null;
        editor.sourceTheme = null;
        editor.touchedPaths = [];
        editor.themes = [];
        editor.selectedThemeBuiltin = false;
        editor.selectedId = "fixture";
        subject.importedSourceReloadPending = false;
    }
    function test_apply_stages_the_whole_profile_without_field_translation() {
        editor.candidate = {id: editor.selectedId, widgets: widgetProfile()};
        editor.sourceTheme = {widgets: {schemaVersion: 1, widgets: []}};
        subject.stageThemeTargets();
        compare(subject.stagedThemeTargetsId, editor.selectedId);
        verify(!subject.prepareSettingsForApply());
        compare(provider.submitted.sections.widgets.schemaVersion, 1);
        const saved = provider.submitted.sections.widgets.widgets[0];
        compare(saved.kind, "clock");
        compare(saved.settings.showSeconds, true);
        compare(saved.placement.x, 24);
        compare(saved.workspaces.ids[1], "special:desk");
        compare(saved.appearance.backgroundOpacity, 0.35);
        verify(saved.contentCommand === undefined);
        verify(saved.options === undefined);
    }
    function test_prepare_does_not_restage_an_unselected_source_profile() {
        const profile = widgetProfile();
        editor.candidate = {widgets: profile};
        editor.sourceTheme = JSON.parse(JSON.stringify(editor.candidate));
        const reordered = {};
        Object.keys(profile.widgets[0]).reverse().forEach(key => reordered[key] = profile.widgets[0][key]);
        provider.settings = {widgets: {widgets: [reordered], schemaVersion: 1}};
        verify(subject.prepareSettingsForApply());
        compare(provider.submitted, null);
    }
    function test_empty_profile_clears_saved_widgets() {
        provider.settings = {widgets: widgetProfile()};
        editor.candidate = {widgets: {schemaVersion: 1, widgets: []}};
        editor.sourceTheme = {widgets: widgetProfile()};
        subject.stageThemeTargets();
        verify(!subject.prepareSettingsForApply());
        compare(provider.submitted.sections.widgets.schemaVersion, 1);
        compare(provider.submitted.sections.widgets.widgets.length, 0);
    }
    function test_explicit_settings_draft_wins_over_selected_theme_profile() {
        const profile = widgetProfile();
        profile.widgets[0].name = "Settings clock";
        subject.draftSettingsWrites = {widgets: profile};
        editor.candidate = {widgets: {schemaVersion: 1, widgets: []}};
        verify(!subject.prepareSettingsForApply());
        compare(provider.submitted.sections.widgets.widgets[0].name, "Settings clock");
        compare(editor.touchedPaths.length, 0);
    }
    function test_inactive_theme_edit_survives_async_save_and_second_preparation() {
        editor.selectedId = "inactive-fixture";
        verify(editor.selectedId !== Theme.activeThemeId);
        editor.candidate = {id: editor.selectedId, widgets: widgetProfile(), targets: {}};
        const source = JSON.stringify(editor.candidate);
        subject.stageThemeTargets();
        compare(subject.stagedThemeTargetsId, editor.selectedId);
        const edited = JSON.parse(JSON.stringify(subject.draftSettingsWrites.widgets));
        edited.widgets[0].name = "Settings clock";
        edited.widgets[0].placement.x = 92;
        subject.draftSettingsWrites = Object.assign({}, subject.draftSettingsWrites, {widgets: edited});
        subject.draftUserEdited = true;

        verify(!subject.prepareSettingsForApply());
        compare(provider.submissions.length, 1);
        compare(provider.submitted.sections.widgets.widgets[0].name, "Settings clock");
        compare(provider.settings.widgets.widgets.length, 0);
        subject.pollSettingsRead();
        verify(subject.applyingSettingsDraft);
        compare(applyOwner.calls, 0);
        Qt.callLater(function() { provider.completeSave(); subject.pollSettingsRead(); });
        tryCompare(applyOwner, "calls", 1);
        verify(applyOwner.prepared);
        verify(!subject.applyingSettingsDraft);
        verify(!subject.draftUserEdited);
        compare(Object.keys(subject.draftSettingsWrites).length, 0);
        compare(provider.submissions.length, 1);
        compare(provider.settings.widgets.widgets[0].name, "Settings clock");
        compare(provider.settings.widgets.widgets[0].placement.x, 92);
        compare(JSON.stringify(editor.candidate), source);

        subject.stageThemeTargets();
        compare(Object.keys(subject.draftSettingsWrites).length, 0);
        verify(subject.prepareSettingsForApply());
        compare(provider.submissions.length, 1);
    }
    function test_absent_source_preserves_saved_profile_and_explicit_empty_clears() {
        provider.settings = {widgets: widgetProfile()};
        const empty = {id: "fixture", widgets: {schemaVersion: 1, widgets: []}};
        compare(subject.prepareEditorSource(empty, {id: "fixture"}).widgets.widgets.length, 1);
        compare(subject.prepareEditorSource(empty, empty).widgets.widgets.length, 0);
        compare(empty.widgets.widgets.length, 0);
    }
    function test_active_theme_keeps_saved_profile_even_when_empty() {
        const active = {id: Theme.activeThemeId, widgets: widgetProfile(), targets: {}};
        provider.settings = {widgets: {schemaVersion: 1, widgets: []}};
        compare(subject.prepareEditorSource(active, active).widgets.widgets.length, 0);
        editor.candidate = active;
        subject.stageThemeTargets();
        compare(subject.draftSettingsWrites.widgets.widgets.length, 0);
        subject.draftSettingsWrites = ({});
        verify(subject.prepareSettingsForApply());
        compare(provider.submitted, null);

        provider.settings = {widgets: widgetProfile()};
        const emptySource = {id: Theme.activeThemeId, widgets: {schemaVersion: 1, widgets: []}};
        compare(subject.prepareEditorSource(emptySource, emptySource).widgets.widgets.length, 1);
    }
    function test_changed_theme_explicit_empty_profile_clears() {
        provider.settings = {widgets: widgetProfile()};
        const emptySource = {id: "another-theme", widgets: {schemaVersion: 1, widgets: []}, targets: {}};
        compare(subject.prepareEditorSource(emptySource, emptySource).widgets.widgets.length, 0);
        editor.candidate = emptySource;
        subject.stageThemeTargets();
        compare(subject.draftSettingsWrites.widgets.widgets.length, 0);
        verify(!subject.prepareSettingsForApply());
        compare(provider.submitted.sections.widgets.widgets.length, 0);
    }
    function test_builtin_theme_empty_placeholder_preserves_saved_widgets() {
        provider.settings = {widgets: widgetProfile()};
        editor.themes = [{id: "nord", builtin: true}];
        editor.selectedId = "nord";
        editor.selectedThemeBuiltin = true;
        const builtinEmpty = {id: "nord", widgets: {schemaVersion: 1, widgets: []}, targets: {}};
        const prepared = subject.prepareEditorSource(builtinEmpty, builtinEmpty);
        compare(prepared.widgets.widgets.length, 1);
        editor.sourceTheme = builtinEmpty;
        editor.candidate = prepared;
        subject.stageThemeTargets();
        compare(subject.draftSettingsWrites.widgets.widgets.length, 1);
        compare(subject.draftSettingsWrites.widgets.widgets[0].id, "clock");
    }
    function test_theme_staging_copies_profile_as_one_value() {
        editor.candidate = {widgets: widgetProfile(), targets: {}};
        subject.stageThemeTargets();
        compare(subject.draftSettingsWrites.widgets.schemaVersion, 1);
        compare(subject.draftSettingsWrites.widgets.widgets[0].settings.style, "analogue");
        verify(subject.draftSettingsWrites["widgets.style.preset"] === undefined);
        verify(subject.draftSettingsWrites["widgets.items"] === undefined);
    }
    function test_imported_source_reload_blocks_unrelated_automatic_staging() {
        subject.importedSourceReloadPending = true;
        editor.candidate = {widgets: widgetProfile(), targets: {}};
        subject.stageThemeTargets();
        compare(Object.keys(subject.draftSettingsWrites).length, 0);
    }
}
