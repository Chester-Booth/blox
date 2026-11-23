import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/modules" as Modules

TestCase {
    id: testCase
    name: "SettingsWidgetRowEditing"
    when: windowShown
    property var fixtureWindow: null

    Component {
        id: fixture
        Window {
            id: window
            width: 900
            height: 700
            visible: true
            property var savedProfile: ({schemaVersion: 1, widgets: []})
            property var widgetCatalogue: null
            property var widgetSchema: null
            property var widgetRegistry: ({})
            property bool mutationProtected: false
            property bool applyingSettingsDraft: false
            property string widgetMetadataError: ""
            property alias themeEditorController: editor
            property alias page: page
            function focusModal() {}
            Modules.SettingsThemeEditorController {
                id: editor
                host: window
                widgetProfileProvider: function() { return JSON.parse(JSON.stringify(window.savedProfile)); }
            }
            Modules.SettingsWidgetsPage { id: page; anchors.fill: parent; windowOwner: window }
        }
    }
    function document(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        return JSON.parse(request.responseText);
    }
    function widget(kind, id) {
        const catalogue = fixtureWindow.widgetCatalogue.widgets.find(entry => entry.kind === kind);
        return {id: id, kind: kind, name: id, enabled: true,
            placement: {anchor: "top-left", x: 0, y: 0, width: 360, height: 300},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.5, scrollbars: "auto"}, fullscreen: {enabled: true, mode: "native"},
            settings: catalogue.defaultSettings};
    }
    function initTestCase() { failOnWarning(/.*/); }
    function init() {
        fixtureWindow = fixture.createObject(testCase);
        verify(fixtureWindow);
        fixtureWindow.widgetCatalogue = document("../../widgets/catalogue.json");
        fixtureWindow.widgetSchema = document("../../widgets/schema/profile.schema.json");
        fixtureWindow.themeEditorController.candidate = document("fixtures/resolved-sparse-theme.json");
        fixtureWindow.savedProfile = {schemaVersion: 1, widgets: [widget("notes", "original-note")]};
    }
    function cleanup() {
        fixtureWindow.close();
        fixtureWindow.destroy();
        fixtureWindow = null;
        wait(0);
    }
    function test_imported_note_row_edits_its_current_identity() {
        const imported = {schemaVersion: 1, widgets: [widget("clock", "clock"), widget("notes", "imported-note")]};
        imported.widgets[1].settings.text = "Imported note text";
        fixtureWindow.savedProfile = JSON.parse(JSON.stringify(imported));
        const button = findChild(fixtureWindow.page, "widget-edit-imported-note");
        verify(button);
        tryVerify(() => button.width > 0 && button.height > 0 && button.enabled);
        wait(20);
        mouseClick(button);
        const editor = fixtureWindow.themeEditorController;
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetEditIndex, 1);
        compare(editor.widgetDraft.id, "imported-note");
        compare(editor.widgetDraft.kind, "notes");
        compare(editor.widgetDraft.settings.text, "Imported note text");
    }
    function test_removed_identity_cannot_open_new_widget_editor() {
        fixtureWindow.savedProfile = {schemaVersion: 1, widgets: [widget("clock", "replacement-clock")]};
        verify(!fixtureWindow.page.editWidget("original-note"));
        const editor = fixtureWindow.themeEditorController;
        compare(editor.modalKind, "");
        compare(editor.widgetDraft, null);
    }
}
