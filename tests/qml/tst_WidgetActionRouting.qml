import "../../widgets/qml/Blox/Widgets" as Widgets
import QtQuick
import QtTest

TestCase {
    id: test
    name: "WidgetActionRouting"
    when: windowShown
    visible: true
    width: 600
    height: 450
    property var adapter: null
    property var host: null
    property var delegateHandler: null
    property var shellHandler: null
    property var dispatcher: null
    property var applicationOwners: null
    property var edited: []
    property int calendarOpens: 0

    QtObject {
        id: fixtureProvider
        signal snapshotReady(string consumerId, var envelope)
        function subscribe(id, kind, options, generation) {
            Qt.callLater(function() {
                fixtureProvider.snapshotReady(id, {generation: generation, revision: 1, observedMonotonicMs: 1,
                    state: "ready", value: {epochMs: 1792230120000, events: []}, error: ""});
            });
        }
        function unsubscribe(id) {}
        function dispatchAction(id, action, payload) {}
    }
    Component {
        id: hostComponent
        Widgets.WidgetHost {
            id: nativeHost
            provider: fixtureProvider
            placementBounds: Qt.rect(0, 0, test.width, test.height)
            onActionRequested: (action, payload) => test.delegateHandler(nativeHost, test.adapter, action, payload)
        }
    }

    function source(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        verify(request.status === 0 || request.status === 200, "Could not read production source " + path);
        return request.responseText;
    }
    function initTestCase() {
        const desktop = source("../../shell/modules/DesktopWidgets.qml");
        const start = desktop.indexOf("    function dispatchHostAction(");
        verify(start >= 0);
        const end = desktop.indexOf("\n    }", start);
        const dispatch = desktop.slice(start, end + 6);
        adapter = Qt.createQmlObject('import QtQuick; QtObject { id: root; property bool editMode: false; '
            + 'signal actionRequested(string widgetId, string action, var payload); '
            + 'function toggleFullscreen() { return "unavailable"; } ' + dispatch + '}', test, "ProductionWidgetActionAdapter");
        verify(adapter !== null);

        // Reuse the production delegate and shell handlers, so a broken handoff fails here.
        const delegate = desktop.match(/onActionRequested:\s*\(action, payload\)\s*=>\s*([^\n]+)/);
        verify(delegate !== null, "Missing DesktopWidgets host action handler");
        delegateHandler = new Function("host", "root", "action", "payload", "return " + delegate[1]);
        const shellSource = source("../../shell/shell.qml");
        const shell = shellSource.match(/onActionRequested:\s*\(widgetId, action, payload\)\s*=>\s*([^\n]+)/);
        verify(shell !== null, "Missing shell widget action handler");
        shellHandler = new Function("widgetActions", "widgetId", "action", "payload", "return " + shell[1]);
        const settingsBinding = shellSource.match(/settingsWindow:\s*(\w+)/);
        const calendarBinding = shellSource.match(/openCalendar:\s*([^\n]+)/);
        verify(settingsBinding !== null && calendarBinding !== null, "Missing application action owners");
        applicationOwners = Qt.createQmlObject('import QtQuick; import "../../shell/services" as Services; Item {'
            + 'property alias dispatcher: widgetActions; '
            + 'QtObject { id: ' + settingsBinding[1] + '; function openWidgetEditor(id) { test.edited = test.edited.concat([id]); return true; } } '
            + 'QtObject { id: bar; property QtObject controller: QtObject { function openKeyboardPanel(panel) { test.calendarOpens++; return panel === "calendar"; } } } '
            + 'Services.WidgetActionController { id: widgetActions; settingsWindow: ' + settingsBinding[1]
            + '; openCalendar: ' + calendarBinding[1] + ' } }', test, "ProductionApplicationActionOwners");
        dispatcher = applicationOwners.dispatcher;
        adapter.actionRequested.connect(function(id, action, payload) { test.shellHandler(dispatcher, id, action, payload); });
    }
    function init() {
        edited = [];
        calendarOpens = 0;
        adapter.editMode = false;
    }
    function cleanup() {
        if (host) host.destroy();
        host = null;
        wait(0);
    }
    function widget(kind, style) {
        return {id: "test-" + kind, kind: kind, name: kind, enabled: true,
            placement: {anchor: "top-left", x: 0, y: 0, width: 400, height: 350},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.5, scrollbars: "auto"}, fullscreen: {enabled: true, mode: "native"},
            settings: kind === "notes" ? {title: "Note", text: "Fixture"} : {style: style}};
    }
    function buttonWithText(item, text) {
        if (item.text === text && typeof item.clicked === "function" && item.visible) return item;
        const children = item.children || [];
        for (let i = 0; i < children.length; i++) {
            const found = buttonWithText(children[i], text);
            if (found) return found;
        }
        return null;
    }
    function test_native_controls_reach_application_dispatcher_data() {
        return [{tag: "notes-edit", kind: "notes", text: "Edit"},
            {tag: "calendar-month-open", kind: "calendar", style: "month", text: "Open"},
            {tag: "calendar-agenda-open", kind: "calendar", style: "agenda", text: "Open"}];
    }
    function test_native_controls_reach_application_dispatcher(row) {
        const item = widget(row.kind, row.style);
        dispatcher.widgetItems = [item];
        host = hostComponent.createObject(test, {widget: item});
        verify(host !== null);
        tryCompare(host, "phase", "visible");
        const button = buttonWithText(host.view, row.text);
        verify(button !== null, "Native action control is missing");
        mouseClick(button);
        compare(edited, row.kind === "notes" ? [item.id] : []);
        compare(calendarOpens, row.kind === "calendar" ? 1 : 0);
        compare(dispatcher.lastResult.code, "ok");
        verify(!findChild(dispatcher, "widget-action-process").running);

        adapter.editMode = true;
        mouseClick(button);
        compare(edited.length + calendarOpens, 1);
    }
}
