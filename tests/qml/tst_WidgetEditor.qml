import qs.shared
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "WidgetEditor"
    QtObject {
        id: host
        property var candidate: ({widgets: {schemaVersion: 1, widgets: []}})
        property var widgetCatalogue: null
        property var widgetSchema: null
        property var widgetRegistry: ({})
        property var widgetProfileProvider: null
        property var widgetProfileWriter: null
        property var savedProfile: ({schemaVersion: 1, widgets: []})
        property string baselineJson: ""
        property var themes: []
        property string selectedId: "fixture"
        property var touchedPaths: []
        property var widgetDraft: testCase.editor ? testCase.editor.draft : null
        property string widgetDraftError: testCase.editor ? testCase.editor.errorMessage : ""
        property string modalKind: ""
        property bool rendered: true
        function widgetItemsChangeAllowed(items) { return true; }
        function cloneCandidate() { return JSON.parse(JSON.stringify(candidate)); }
        function markCandidate(next, path, commands) { candidate = next; touchedPaths = touchedPaths.concat([path]); }
        function showModal(kind) { modalKind = kind; }
        function dismissModal() { modalKind = ""; }
        function newWidgetDraft(kind) { return testCase.editor.newDraft(kind); }
        function updateWidgetDraft(values) { testCase.editor.updateDraft(values); }
        function updateWidgetOption(key, value) { testCase.editor.updateOption(key, value); }
    }
    SignalSpy { id: editModeRequests; target: Theme; signalName: "widgetEditModeRequested" }
    property var editor: null
    property var controls: null
    function source(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        return request.responseText;
    }
    function initTestCase() {
        failOnWarning(/.*/);
        host.widgetCatalogue = JSON.parse(source("../../widgets/catalogue.json"));
        host.widgetSchema = JSON.parse(source("../../widgets/schema/profile.schema.json"));
        editor = Qt.createQmlObject(source("../../shell/modules/SettingsWidgetController.qml").replace("required property var host", "property var host"), testCase, "WidgetEditorController");
        editor.host = host;
        const component = Qt.createComponent(Qt.resolvedUrl("../../shell/modules/SettingsWidgetEditor.qml"));
        compare(component.status, Component.Ready, component.errorString());
        controls = component.createObject(testCase, {controller: host, width: 440});
        verify(controls !== null);
    }
    function init() {
        host.touchedPaths = [];
        host.widgetRegistry = ({});
        host.widgetProfileProvider = null;
        host.widgetProfileWriter = null;
        host.savedProfile = {schemaVersion: 1, widgets: []};
        host.candidate = {widgets: {schemaVersion: 1, widgets: []}};
        editor.draft = null;
        editor.editIndex = -1;
        editor.errorMessage = "";
        editor.editModePending = false;
        host.rendered = true;
        editModeRequests.clear();
        host.modalKind = "";
    }
    function test_native_crud_preserves_settings_and_geometry() {
        editor.openEditor(-1);
        compare(editor.draft.kind, "clock");
        editor.updateOption("showSeconds", true);
        editor.updateDraft({placement: {anchor: "top-right", x: 120, y: 32, width: 280, height: 160}});
        verify(editor.saveDraft());
        compare(host.candidate.widgets.schemaVersion, 1);
        compare(host.candidate.widgets.widgets[0].settings.showSeconds, true);
        compare(host.touchedPaths[0], "widgets.widgets");
        compare(host.modalKind, "");
        editor.openEditor(0);
        editor.updateDraft({name: "Desk clock"});
        verify(editor.saveDraft());
        compare(host.candidate.widgets.widgets[0].placement.x, 120);
        compare(host.candidate.widgets.widgets[0].name, "Desk clock");
        verify(editor.setItems([]));
        compare(editor.items().length, 0);
    }
    function test_catalogue_defaults_are_independent_and_configuration_is_explicit() {
        const item = editor.newDraft("music");
        compare(item.settings.style, "card");
        item.settings.style = "compact";
        compare(editor.newDraft("music").settings.style, "card");
        editor.draft = editor.newDraft("terminal");
        verify(!editor.saveDraft());
        verify(editor.errorMessage.indexOf("command") >= 0);
        editor.updateOption("command", ["printf", "hello"]);
        verify(editor.saveDraft());
        compare(editor.items()[0].fullscreen.mode, "resize");
        verify(editor.items()[0].settings.command[1] === "hello");
    }
    function test_command_actions_recursive_feedback_and_defaults() {
        editor.draft = editor.newDraft("command");
        editor.updateOption("command", ["producer"]);
        compare(editor.draft.settings.actions.left, null);
        compare(editor.draft.settings.actions.right, null);
        const run = {kind:"run",command:["action","literal;arg"],workingDirectory:"",environment:{EXAMPLE:"value"},timeoutSeconds:5};
        editor.updateOption("actions",{left:run,right:{kind:"launch",command:["app"]}});
        verify(editor.saveDraft(), editor.errorMessage);
        editor.openEditor(0);
        const invalid = [
            {left:{kind:"run",command:["action"],workingDirectory:"",environment:{},timeoutSeconds:121},right:null},
            {left:{kind:"launch",command:["app"],environment:{}},right:null},
            {left:{kind:"run",command:["action","\u0000"],workingDirectory:"",environment:{},timeoutSeconds:5},right:null},
            {left:{kind:"run",command:["action"],workingDirectory:"",environment:{"BAD-NAME":"x"},timeoutSeconds:5},right:null},
            {left:{kind:"run",command:[],workingDirectory:"",environment:{},timeoutSeconds:5},right:null},
            {left:null}, {left:"shell string",right:null}
        ];
        for (const actions of invalid) {
            editor.updateOption("actions",actions);
            verify(!editor.saveDraft(), JSON.stringify(actions));
            verify(editor.errorMessage.length > 0);
            compare(editor.items()[0].settings.actions.left.command[1], "literal;arg");
        }
        editor.updateOption("actions",{left:{kind:"launch",command:["app", "界".repeat(4096), "界".repeat(4096)]},right:null});
        verify(!editor.saveDraft());
        verify(editor.errorMessage.indexOf("JSON budget") >= 0, editor.errorMessage);
        editor.updateOption("actions",{left:null,right:null});
        verify(editor.saveDraft(),editor.errorMessage);
    }
    function test_native_options_validate_against_shared_schema() {
        editor.draft = editor.newDraft("clock");
        editor.updateOption("style", "analogue");
        editor.updateOption("format", "12h");
        verify(editor.saveDraft());
        editor.openEditor(0);
        editor.updateOption("style", "tty-clock");
        verify(!editor.saveDraft());
        compare(editor.items()[0].settings.style, "analogue");
        compare(host.modalKind, "widget");
    }
    function test_recursive_schema_feedback_rejects_nested_values_and_collection_constraints() {
        host.widgetRegistry = {example: {layouts:["native"], providers:["clock"]}};
        editor.draft = editor.newDraft("qml");
        controls.chooseManifest("example");
        editor.updateOption("settings", {nested:{values:[null,true,12,"text",{colour:"blue"}]}});
        compare(editor.errorMessage, "");
        for (const invalid of [{number:1e13}, {text:"x".repeat(16385)}, {array:Array(257).fill(0)}, {"":true}]) {
            editor.updateOption("settings", invalid);
            verify(editor.errorMessage.length > 0, JSON.stringify(invalid).slice(0,120));
            verify(!editor.saveDraft());
        }
        let deep = {value:0};
        for (let index = 0; index < 9; ++index) deep = {child:deep};
        editor.updateOption("settings", deep);
        verify(!editor.saveDraft());
        editor.draft = editor.newDraft("network");
        editor.updateOption("interfaces", ["eth0","eth0"]);
        verify(!editor.saveDraft());
        editor.draft = editor.newDraft("shortcuts");
        editor.updateOption("items", [{id:"same",label:"One",command:["one"]},{id:"same",label:"Two",command:["two"]}]);
        verify(!editor.saveDraft());
        editor.draft = editor.newDraft("clock");
        editor.updateDraft({workspaces:{mode:"include",ids:[2,2],ranges:[]}});
        verify(!editor.saveDraft());
        editor.updateDraft({workspaces:{mode:"include",ids:[],ranges:[[4,6],[4,6]]}});
        verify(!editor.saveDraft());
        editor.draft = editor.newDraft("terminal");
        editor.updateOption("command", ["terminal"]);
        editor.updateOption("columns", 240);
        editor.updateOption("rows", 100);
        verify(!editor.saveDraft());
        verify(editor.errorMessage.indexOf("cell limit") >= 0);
        editor.draft = editor.newDraft("command");
        editor.updateOption("command", ["producer"]);
        editor.updateOption("environment", {BLOX_WIDGET_ACTION_CONTEXT:"reserved"});
        verify(!editor.saveDraft());
        editor.updateOption("environment", {});
        editor.updateOption("actions", {left:{kind:"run",command:["action"],workingDirectory:"",environment:{BLOX_WIDGET_ACTION_CONTEXT:"reserved"},timeoutSeconds:5},right:null});
        verify(!editor.saveDraft());
    }
    function test_weather_requires_explicit_coordinates() {
        editor.openEditor(-1);
        controls.changeKind("weather");
        verify(editor.draft.settings.latitude === undefined);
        verify(editor.draft.settings.longitude === undefined);
        verify(!editor.saveDraft());
        editor.updateOption("latitude", 51.5);
        editor.updateOption("longitude", -0.1);
        verify(editor.saveDraft());
        compare(editor.items()[0].settings.latitude, 51.5);
    }
    function test_trusted_manifest_controls_use_registered_layouts_and_providers() {
        host.widgetRegistry = {"desk-clock": {layouts: ["native", "fit"], providers: ["clock"]}};
        editor.openEditor(-1);
        controls.changeKind("qml");
        verify(!editor.saveDraft());
        controls.chooseManifest("desk-clock");
        compare(editor.draft.settings.manifest, "desk-clock");
        compare(editor.draft.settings.providers[0], "clock");
        compare(editor.draft.settings.layouts[1], "fit");
        editor.updateDraft({fullscreen: {enabled: true, mode: "fit"}});
        verify(editor.saveDraft());
        editor.openEditor(0);
        editor.updateDraft({fullscreen: {enabled: true, mode: "scroll"}});
        verify(!editor.saveDraft());
        compare(editor.items()[0].fullscreen.mode, "fit");
    }
    function test_geometry_rejects_invalid_sizes_without_changing_placement() {
        verify(editor.setItems([editor.newDraft("system")]));
        editor.openEditor(0);
        editor.updateDraft({placement: {anchor: "bottom-right", x: 12, y: 34, width: 500, height: 260}});
        verify(editor.saveDraft());
        compare(editor.items()[0].placement.x, 12);
        compare(editor.items()[0].placement.anchor, "bottom-right");
        editor.openEditor(0);
        editor.updateDraft({placement: {anchor: "bottom-right", x: 12, y: 34, width: 0, height: 260}});
        verify(!editor.saveDraft());
        compare(editor.items()[0].placement.width, 500);
        editor.updateDraft({placement: {anchor: "bottom-right", x: NaN, y: 34, width: 500, height: 260}});
        verify(!editor.saveDraft());
        compare(editor.items()[0].placement.x, 12);
    }
    function test_workspace_ids_and_ranges_are_exact_and_checked() {
        editor.draft = editor.newDraft("notes");
        editor.updateDraft({workspaces: {mode: "include", ids: [2, "special:notes", "2"], ranges: [[4, 6], [-5, -1]]}});
        verify(editor.saveDraft());
        compare(editor.items()[0].workspaces.ids[0], 2);
        compare(editor.items()[0].workspaces.ids[2], "2");
        editor.openEditor(0);
        editor.updateDraft({workspaces: {mode: "include", ids: [], ranges: [[6, 4]]}});
        verify(!editor.saveDraft());
        verify(editor.errorMessage.indexOf("ascending") >= 0);
        compare(editor.items()[0].workspaces.ranges[0][0], 4);
        editor.updateDraft({workspaces: {mode: "include", ids: [1.5], ranges: []}});
        verify(!editor.saveDraft());
        editor.updateDraft({workspaces: {mode: "include", ids: [], ranges: []}});
        verify(editor.saveDraft());
        compare(editor.items()[0].workspaces.mode, "include");
        compare(editor.items()[0].workspaces.ids.length, 0);
    }
    function test_background_opacity_and_fullscreen_are_per_widget() {
        editor.draft = editor.newDraft("music");
        editor.updateDraft({appearance: {backgroundOpacity: 0, scrollbars: "hide"}, fullscreen: {enabled: true, mode: "native"}});
        verify(editor.saveDraft());
        compare(editor.items()[0].appearance.backgroundOpacity, 0);
        editor.openEditor(0);
        editor.updateDraft({fullscreen: {enabled: true, mode: "fit"}});
        verify(!editor.saveDraft());
        compare(editor.items()[0].fullscreen.mode, "native");
    }
    function test_editor_changes_kind_and_parses_workspace_controls() {
        editor.openEditor(-1);
        controls.changeKind("music");
        compare(editor.draft.kind, "music");
        compare(editor.draft.settings.style, "card");
        verify(editor.draft.settings.showSeconds === undefined);
        controls.changeKind("terminal");
        compare(editor.draft.fullscreen.mode, "resize");
        controls.editWorkspaceIds('2, "2", special:notes');
        compare(editor.draft.workspaces.ids[0], 2);
        compare(editor.draft.workspaces.ids[1], "2");
        compare(editor.draft.workspaces.ids[2], "special:notes");
        controls.editWorkspaceRanges("4-6, -5--1");
        compare(editor.draft.workspaces.ranges[1][0], -5);
        controls.editWorkspaceRanges("6-4");
        compare(typeof editor.draft.workspaces.ranges, "string");
        verify(!editor.saveDraft());
    }
    function test_unsupported_profile_is_rejected_without_conversion() {
        host.candidate = {widgets: {profile: "minimal", items: []}};
        editor.openEditor(-1);
        compare(host.modalKind, "");
        verify(editor.errorMessage.indexOf("Unsupported widget profile") >= 0);
        verify(!editor.setItems([]));
        verify(host.candidate.widgets.schemaVersion === undefined);
        verify(host.candidate.widgets.profile === "minimal");
    }
    function test_settings_callbacks_leave_theme_source_untouched() {
        host.widgetProfileProvider = function() { return host.savedProfile; };
        host.widgetProfileWriter = function(profile) { host.savedProfile = profile; };
        const source = JSON.stringify(host.candidate);
        editor.openEditor(-1);
        editor.updateDraft({name: "My clock"});
        verify(editor.saveDraft());
        compare(host.savedProfile.widgets[0].name, "My clock");
        compare(editor.items()[0].name, "My clock");
        compare(JSON.stringify(host.candidate), source);
        compare(host.touchedPaths.length, 0);
        verify(editor.setItems([]));
        compare(host.savedProfile.widgets.length, 0);
    }
    function test_edit_mode_receives_authoritative_settings_items() {
        host.savedProfile = {schemaVersion: 1, widgets: [editor.newDraft("notes")]};
        host.widgetProfileProvider = function() { return host.savedProfile; };
        host.candidate = {widgets: {schemaVersion: 1, widgets: [editor.newDraft("clock")]}};
        editor.openEditMode();
        compare(editModeRequests.count, 1);
        compare(editModeRequests.signalArguments[0][0][0].kind, "notes");
        compare(host.rendered, false);
        editor.openEditMode();
        compare(editModeRequests.count, 1);
    }
    function test_failed_settings_staging_keeps_modal_and_draft() {
        host.widgetProfileProvider = function() { return host.savedProfile; };
        host.widgetProfileWriter = function(profile) { return false; };
        editor.openEditor(-1);
        editor.updateDraft({name: "Unsaved clock"});
        verify(!editor.saveDraft());
        compare(host.modalKind, "widget");
        compare(editor.draft.name, "Unsaved clock");
        compare(host.savedProfile.widgets.length, 0);
        compare(host.touchedPaths.length, 0);
        verify(editor.errorMessage.indexOf("Could not stage") >= 0);
    }
    function test_unique_identifiers_do_not_collide_after_deletion() {
        const item = editor.newDraft("clock");
        item.id = "widget-2";
        verify(editor.setItems([item]));
        compare(editor.newDraft("clock").id, "widget-1");
        const duplicate = editor.newDraft("music");
        duplicate.id = item.id;
        verify(!editor.setItems([item, duplicate]));
    }
}
