import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import qs.modules

TestCase {
    id: test
    name: "SettingsWidgetModal"
    when: windowShown
    property var fixtureWindow: null
    property var catalogue: null
    property var schema: null
    Component {
        id: fixture
        Window {
            id: window
            width: 680
            height: 480
            visible: true
            property var widgetCatalogue: null
            property var widgetSchema: null
            property var widgetRegistry: ({})
            property bool mutationProtected: false
            property bool applyingSettingsDraft: false
            property alias controller: editor
            property alias modal: modal
            function focusModal() { modal.forceActiveFocus(); modal.focusInitial(); }
            SettingsThemeEditorController { id: editor; host: window }
            SettingsEditorModal { id: modal; controller: editor; anchors.fill: parent }
        }
    }
    function readJson(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        return JSON.parse(request.responseText);
    }
    function initTestCase() {
        failOnWarning(/.*/);
        catalogue = readJson("../../widgets/catalogue.json");
        schema = readJson("../../widgets/schema/profile.schema.json");
    }
    function init() {
        fixtureWindow = fixture.createObject(test, {widgetCatalogue: catalogue, widgetSchema: schema});
        verify(fixtureWindow);
        fixtureWindow.controller.candidate = {id: "fixture", widgets: {schemaVersion: 1, widgets: []}};
        fixtureWindow.controller.openWidgetEditor(-1);
        tryCompare(fixtureWindow.controller, "modalKind", "widget");
        tryCompare(fixtureWindow.modal, "visible", true);
        wait(20);
    }
    function cleanup() {
        fixtureWindow.close();
        fixtureWindow.destroy();
        fixtureWindow = null;
        wait(0);
    }
    function test_long_editor_scrolls_inside_available_height() {
        fixtureWindow.height = 360;
        const flow = findChild(fixtureWindow.modal, "widget-editor");
        flow.selectTab(4, false);
        wait(0);
        const scroll = findChild(fixtureWindow.modal, "widget-editor-scroll");
        const save = findChild(fixtureWindow.modal, "widget-save-button");
        verify(scroll);
        verify(save);
        verify(scroll.height > 0);
        verify(scroll.height < fixtureWindow.height - 80);
        verify(scroll.contentHeight > scroll.height, "content=" + scroll.contentHeight + " viewport=" + scroll.height);
        verify(save.visible);
        verify(save.mapToItem(fixtureWindow.contentItem, 0, save.height).y < fixtureWindow.height);
    }
    function test_save_follows_validation_error() {
        const save = findChild(fixtureWindow.modal, "widget-save-button");
        compare(fixtureWindow.controller.widgetDraftError, "");
        compare(save.enabled, true);
        fixtureWindow.controller.updateWidgetDraft({appearance: {backgroundOpacity: 4, scrollbars: "auto"}});
        verify(fixtureWindow.controller.widgetDraftError.length > 0);
        compare(save.enabled, false);
        fixtureWindow.controller.updateWidgetDraft({appearance: {backgroundOpacity: 0.8, scrollbars: "auto"}});
        compare(fixtureWindow.controller.widgetDraftError, "");
        compare(save.enabled, true);
    }
    function test_save_waits_for_settings_mutations() {
        const save = findChild(fixtureWindow.modal, "widget-save-button");
        compare(save.enabled, true);
        fixtureWindow.mutationProtected = true;
        compare(save.enabled, false);
        fixtureWindow.mutationProtected = false;
        compare(save.enabled, true);
        fixtureWindow.applyingSettingsDraft = true;
        compare(save.enabled, false);
        fixtureWindow.applyingSettingsDraft = false;
        compare(save.enabled, true);
    }

    function test_presentation_keeps_opacity_and_validates() {
        const layout = findChild(fixtureWindow.modal, "widgetPresentation");
        verify(layout);
        compare(layout.currentIndex, 0);
        const opacity = fixtureWindow.controller.widgetDraft.appearance.backgroundOpacity;
        layout.activated(1, "Compact");
        compare(fixtureWindow.controller.widgetDraft.appearance.presentation, "compact");
        compare(fixtureWindow.controller.widgetDraft.appearance.backgroundOpacity, opacity);
        compare(fixtureWindow.controller.widgetDraftError, "");
        layout.activated(0, "Open");
        compare(fixtureWindow.controller.widgetDraft.appearance.presentation, "open");
        compare(fixtureWindow.controller.widgetDraftError, "");
    }
}
