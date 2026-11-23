import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "SettingsWidgetLayoutRouting"
    property var windowSubject: null
    property var editorHost: null
    property var widgetEditor: null
    property var catalogue: null
    property var schema: null
    QtObject {
        id: themeEvents
        property var widgetItems: []
        signal widgetLayoutEditRequested()
        signal widgetEditModeRequested(var widgets)
        signal widgetEditModeFinished(string payload, string returnWorkspace)
    }
    QtObject { id: revealTimer; property int starts: 0; function restart() { starts++; } }
    SignalSpy { id: editRequests; target: themeEvents; signalName: "widgetEditModeRequested" }

    function source(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        return request.responseText;
    }
    function extract(text, name) {
        const start = text.indexOf("function " + name + "(");
        verify(start >= 0, "Missing production function " + name);
        let index = text.indexOf("{", start), depth = 1;
        while (depth && ++index < text.length) {
            if (text[index] === "{") depth++;
            if (text[index] === "}") depth--;
        }
        return text.slice(start, index + 1);
    }
    function initTestCase() {
        failOnWarning(/.*/);
        catalogue = JSON.parse(source("../../widgets/catalogue.json"));
        schema = JSON.parse(source("../../widgets/schema/profile.schema.json"));
        const windowSource = source("../../shell/modules/SettingsWindow.qml");
        const hostSource = source("../../shell/modules/SettingsThemeEditorController.qml");
        const gatewaySource = source("../../shell/services/SettingsGateway.qml");
        const windowFunctions = ["requestWidgetLayoutEdit", "completePendingWidgetLayoutEdit", "beginWidgetEditMode"].map(name => extract(windowSource, name)).join("\n");
        windowSubject = Qt.createQmlObject('import QtQuick; QtObject { id: root; property var themeEvents: null; property var themeEditorController; property bool windowOpen: false; property bool widgetEditing: false; property bool mutationProtected: false; property bool applyingSettingsDraft: false; property bool pendingSettingsRead: false; property bool widgetEditorReadReady: false; property var settingsController: ({settings: {}}); property bool settingsMutationPending: false; property bool pendingWidgetLayoutEdit: false; property int openCalls: 0; property string visited: ""; function openWindow() { windowOpen=true; pendingSettingsRead=true; widgetEditorReadReady=false; openCalls++; } function startSettingsRead() {} function openSettingsSection(category,section) { visited=category+"/"+section; } '
            + windowFunctions + ' property Connections bridge: Connections { target: root.themeEvents; '
            + extract(gatewaySource, "onWidgetLayoutEditRequested") + extract(windowSource, "onWidgetEditModeFinished") + ' } }', testCase, "ProductionSettingsLayoutRoute");
        windowSubject.themeEvents = themeEvents;
        const controlsGuard = hostSource.match(/readonly property bool widgetControlsEnabled:[^\n]+/)[0];
        editorHost = Qt.createQmlObject('import QtQuick; QtObject { id: root; property var host; property var themeEvents: null; property var widgetEditor; property var candidate: null; property var widgetCatalogue: null; property var widgetSchema: null; property var widgetRegistry: ({}); property bool busy: false; property bool creationBusy: false; '
            + controlsGuard + '; property var savedProfile; property var stagedProfile: null; property bool widgetEditModePending: false; property bool rendered: true; property string widgetReturnWorkspace: ""; property string statusMessage: ""; property string errorMessage: ""; property string widgetDraftError: widgetEditor ? widgetEditor.errorMessage : ""; property var revealTimer; function widgetProfileProvider() { return stagedProfile || savedProfile; } function widgetProfileWriter(profile) { stagedProfile=profile; return true; } function widgetItemsChangeAllowed(items) { return widgetControlsEnabled && Array.isArray(items); } function setWidgetItems(items) { return widgetEditor.setItems(items); } function openWidgetEditMode() { const accepted=widgetEditor.openEditMode(); widgetEditModePending=widgetEditor.editModePending; return accepted; } onWidgetEditModePendingChanged: { if(widgetEditor) widgetEditor.editModePending=widgetEditModePending; } function recoverPickerWorkspace(workspace,focus) {} property Connections bridge: Connections { target: root.themeEvents; '
            + extract(hostSource, "onWidgetEditModeFinished") + ' } }', testCase, "ProductionWidgetLayoutSave");
        editorHost.host = windowSubject;
        editorHost.themeEvents = themeEvents;
        editorHost.revealTimer = revealTimer;
        windowSubject.themeEditorController = editorHost;
        widgetEditor = Qt.createQmlObject(source("../../shell/modules/SettingsWidgetController.qml")
            .replace("import qs.shared\n", "")
            .replace("required property var host", "property var host")
            .replace("Theme.widgetEditModeRequested(", "host.themeEvents.widgetEditModeRequested("), testCase, "ProductionLayoutWidgetController");
        widgetEditor.host = editorHost;
        editorHost.widgetEditor = widgetEditor;
    }
    function profile() {
        return {schemaVersion: 1, widgets: [{id: "desk-clock", kind: "clock", name: "Desk clock", enabled: true,
            placement: {anchor: "top-left", x: 24, y: 24, width: 280, height: 160},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.8, scrollbars: "auto"}, fullscreen: {enabled: false, mode: "native"},
            settings: catalogue.widgets[0].defaultSettings}]};
    }
    function init() {
        windowSubject.windowOpen = false;
        windowSubject.widgetEditing = false;
        windowSubject.mutationProtected = false;
        windowSubject.applyingSettingsDraft = false;
        windowSubject.pendingSettingsRead = false;
        windowSubject.widgetEditorReadReady = false;
        windowSubject.settingsMutationPending = false;
        windowSubject.pendingWidgetLayoutEdit = false;
        windowSubject.openCalls = 0;
        windowSubject.visited = "";
        editorHost.candidate = null;
        editorHost.widgetCatalogue = null;
        editorHost.widgetSchema = null;
        editorHost.savedProfile = profile();
        editorHost.stagedProfile = null;
        editorHost.widgetEditModePending = false;
        editorHost.rendered = true;
        editorHost.statusMessage = "";
        editorHost.errorMessage = "";
        widgetEditor.errorMessage = "";
        widgetEditor.editModePending = false;
        themeEvents.widgetItems = profile().widgets;
        editRequests.clear();
    }
    function makeReady() {
        editorHost.candidate = {id: "source", widgets: {schemaVersion: 1, widgets: []}};
        editorHost.widgetCatalogue = catalogue;
        editorHost.widgetSchema = schema;
        windowSubject.pendingSettingsRead = false;
        windowSubject.widgetEditorReadReady = true;
    }
    function test_direct_request_queues_then_save_stages_profile() {
        const liveBefore = JSON.stringify(themeEvents.widgetItems);
        themeEvents.widgetLayoutEditRequested();
        compare(windowSubject.openCalls, 1);
        compare(windowSubject.visited, "widgets/widgets");
        verify(windowSubject.pendingWidgetLayoutEdit);
        windowSubject.completePendingWidgetLayoutEdit();
        compare(editRequests.count, 0);
        makeReady();
        windowSubject.completePendingWidgetLayoutEdit();
        compare(editRequests.count, 1);
        verify(windowSubject.widgetEditing);
        verify(editorHost.widgetEditModePending);
        const edited = JSON.parse(JSON.stringify(editRequests.signalArguments[0][0]));
        edited[0].placement.x = 92;
        themeEvents.widgetEditModeFinished(JSON.stringify(edited), "2");
        verify(!windowSubject.widgetEditing);
        verify(!editorHost.widgetEditModePending);
        compare(editorHost.stagedProfile.schemaVersion, 1);
        compare(editorHost.stagedProfile.widgets[0].placement.x, 92);
        compare(editorHost.candidate.widgets.widgets.length, 0);
        compare(JSON.stringify(themeEvents.widgetItems), liveBefore);
    }
    function test_protected_settings_reject_request_without_opening() {
        windowSubject.mutationProtected = true;
        verify(!windowSubject.requestWidgetLayoutEdit());
        compare(windowSubject.openCalls, 0);
        verify(!windowSubject.pendingWidgetLayoutEdit);
        makeReady();
        verify(!windowSubject.beginWidgetEditMode());
        compare(editRequests.count, 0);
    }
    function test_invalid_profile_does_not_hide_settings() {
        makeReady();
        editorHost.savedProfile = {items: []};
        verify(windowSubject.requestWidgetLayoutEdit());
        windowSubject.pendingSettingsRead = false;
        windowSubject.widgetEditorReadReady = true;
        windowSubject.completePendingWidgetLayoutEdit();
        verify(!windowSubject.widgetEditing);
        compare(editRequests.count, 0);
        verify(widgetEditor.errorMessage.indexOf("Unsupported widget profile") >= 0);
    }
}
