import QtQuick
import QtTest
import "../../widgets/tests/fixtures" as Fixtures

TestCase {
    id: test
    name: "DesktopWidgetStacking"
    when: windowShown
    visible: true
    width: 400
    height: 300
    property var firstHost: null
    property var laterHost: null
    property var actions: []
    property string stackingExpression: ""
    Fixtures.TerminalFixtureDecoder { id: terminalDecoder }
    Item { id: canvas; anchors.fill: parent }
    QtObject {
        id: provider
        property int subscriptions: 0
        property int cancellations: 0
        signal snapshotReady(string consumerId, var snapshot)
        function subscribe(id, kind, settings, generation) {
            subscriptions++;
            if (kind === "terminal") terminalDecoder.prepare(id, generation);
            Qt.callLater(function() {
                const envelope = {generation: generation, revision: 0, observedMonotonicMs: 1,
                    state: "ready", error: "", value: {columns: 80, rowCount: 24,
                        rows: Array.from({length: 24}, function() { return {runs: []}; })}};
                snapshotReady(id, kind === "terminal" && terminalDecoder.generations[id] === generation
                    ? terminalDecoder.adapt(id, envelope) : envelope);
            });
        }
        function unsubscribe(id) { cancellations++; terminalDecoder.release(id); }
        function dispatchAction(id, action, payload) {}
    }
    function profile(id, kind) {
        return {id: id, kind: kind, name: id, enabled: true,
            placement: {anchor: "top-left", x: 0, y: 0, width: kind === "terminal" ? 80 : 400, height: kind === "terminal" ? 60 : 300},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.35, scrollbars: "auto"},
            fullscreen: {enabled: true, mode: kind === "terminal" ? "fit" : "native"},
            settings: kind === "terminal" ? {command: ["fixture-never-executed"], workingDirectory: "", environment: {}, columns: 80, rows: 24}
                : {title: id, text: Array(80).fill("Private stacking fixture").join("\n")}};
    }
    function makeHost(id, kind) {
        const host = Qt.createQmlObject('import QtQuick; import "../../widgets/qml/Blox/Widgets" as Widgets; Widgets.WidgetHost { z: '
            + stackingExpression + ' }', canvas, Qt.resolvedUrl("WidgetStackingHost.qml"));
        host.provider = provider;
        host.widget = profile(id, kind);
        host.placementBounds = Qt.rect(0, 0, 400, 300);
        host.actionRequested.connect(function(action, payload) { test.actions = test.actions.concat([{id: id, action: action}]); });
        return host;
    }
    function descendant(item, predicate) {
        if (predicate(item)) return item;
        for (const child of item.children || []) {
            const found = descendant(child, predicate);
            if (found) return found;
        }
        return null;
    }
    function editButton(host) {
        return descendant(host.view, function(item) { return item.objectName === "notes-edit-button" && typeof item.clicked === "function"; });
    }
    function clickButton(button) {
        verify(button !== null);
        const point = button.mapToItem(canvas, button.width / 2, button.height / 2);
        mouseClick(canvas, point.x, point.y);
    }
    function makePair(kind) {
        firstHost = makeHost("earlier-widget", kind);
        laterHost = makeHost("later-widget", "notes");
        tryCompare(firstHost, "phase", "visible");
        tryCompare(laterHost, "phase", "visible");
    }
    function initTestCase() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/modules/DesktopWidgets.qml"), false);
        request.send();
        const binding = request.responseText.match(/^\s*z:\s*(effectiveFullscreen[^\n]*)/m);
        verify(binding !== null, "Desktop adapter must raise effective fullscreen hosts");
        stackingExpression = binding[1];
    }
    function init() { terminalDecoder.reset(); actions = []; provider.subscriptions = 0; provider.cancellations = 0; }
    function cleanup() {
        if (firstHost) firstHost.destroy();
        if (laterHost) laterHost.destroy();
        firstHost = null; laterHost = null;
        wait(0);
    }

    function test_fullscreen_terminal_blocks_real_note_button_and_scroll_beneath_blank_area() {
        makePair("terminal");
        const noteButton = editButton(laterHost);
        const scroll = findChild(laterHost.view, "nativeScroll").contentItem;
        tryVerify(function() { return scroll.contentHeight > scroll.height; });
        const subscriptions = provider.subscriptions;
        const snapshot = firstHost.snapshot;
        firstHost.fullscreen = true;
        tryCompare(firstHost, "phase", "visible");
        verify(firstHost.z > laterHost.z);
        clickButton(noteButton);
        compare(actions.length, 0);
        mouseWheel(canvas, 200, 260, 0, -120);
        wait(100);
        compare(scroll.contentY, 0);
        compare(laterHost.phase, "visible");
        compare(provider.subscriptions, subscriptions);
        compare(provider.cancellations, 0);
        compare(firstHost.snapshot, snapshot);
        compare(findChild(firstHost, "widgetBackground").opacity, 0.35);
        compare(firstHost.opacity, 1);
        compare(firstHost.view.opacity, 1);

        firstHost.fullscreen = false;
        tryCompare(firstHost, "phase", "visible");
        compare(firstHost.z, laterHost.z);
        clickButton(noteButton);
        compare(actions, [{id: "later-widget", action: "edit"}]);
        mouseWheel(canvas, 200, 260, 0, -120);
        tryVerify(function() { return scroll.contentY > 0; });
        compare(firstHost.widget.placement.width, 80);
        compare(firstHost.widget.placement.height, 60);
    }
    function test_fullscreen_foreground_native_button_keeps_input_before_fallback_shield() {
        makePair("notes");
        firstHost.fullscreen = true;
        tryCompare(firstHost, "phase", "visible");
        clickButton(editButton(firstHost));
        compare(actions, [{id: "earlier-widget", action: "edit"}]);
        compare(laterHost.phase, "visible");
        compare(provider.cancellations, 0);
    }
}
