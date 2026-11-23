import QtQuick
import QtTest
import "../../widgets/qml/Blox/Widgets" as Widgets

TestCase {
    id: test
    name: "WidgetTerminalRestart"
    when: windowShown
    visible: true
    width: 600; height: 400
    property var subject
    property var created: []
    QtObject {
        id: fixtureProvider
        property int subscriptions: 0
        property int cancellations: 0
        signal snapshotReady(string consumerId, var envelope)
        function subscribe(id, kind, options, generation) { subscriptions++; }
        function unsubscribe(id) { cancellations++; }
    }
    Component {
        id: hostComponent
        Widgets.WidgetHost {
            property string outputName: "eDP-1"
            provider: fixtureProvider
            placementBounds: Qt.rect(0, 0, 600, 400)
        }
    }
    function initTestCase() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/modules/DesktopWidgets.qml"), false);
        request.send();
        const source = request.responseText;
        const start = source.indexOf("    function restartTerminal(");
        verify(start >= 0);
        const end = source.indexOf("\n    }", start);
        const implementation = source.slice(start, end + 6);
        subject = Qt.createQmlObject('import QtQuick; QtObject { property bool editMode: false; property var hosts: []; '
            + implementation + '}', test, "ProductionTerminalRestart");
    }
    function makeHost(output) {
        const host = hostComponent.createObject(test, {outputName: output || "eDP-1", widget: {
            id: "terminal-fixture", kind: "terminal", enabled: true, visibility: "always",
            workspaces: {mode: "all", ids: [], ranges: []},
            placement: {anchor: "top-left", x: 0, y: 0, width: 300, height: 200, sizing: "fixed"},
            appearance: {backgroundOpacity: 0.5, scrollbars: "auto"},
            fullscreen: {enabled: false, mode: "fit"}, settings: {columns: 20, rows: 3}
        }});
        verify(host !== null);
        created.push(host); subject.hosts = created.slice();
        tryVerify(function() { return host.eligible; });
        return host;
    }
    function init() { subject.editMode = false; subject.hosts = []; created = []; }
    function cleanup() {
        subject.hosts = [];
        for (const host of created) host.destroy();
        created = []; wait(0);
    }
    function test_preparing_host_restarts_with_new_generation() {
        const host = makeHost();
        tryCompare(host, "phase", "preparing");
        const generation = host.revealGeneration;
        const cancellations = fixtureProvider.cancellations;
        compare(subject.restartTerminal(host.widget.id, "").status, "restarted");
        verify(host.revealGeneration > generation);
        verify(fixtureProvider.cancellations > cancellations);
        tryCompare(host, "phase", "preparing");
    }
    function test_unavailable_host_can_recover() {
        const host = makeHost(); tryCompare(host, "phase", "preparing");
        fixtureProvider.snapshotReady(host.consumerId, {generation: host.revealGeneration, revision: 1, observedMonotonicMs: 1, state: "unavailable", error: "fixture failure", value: {}});
        tryCompare(host, "phase", "unavailable");
        compare(subject.restartTerminal(host.widget.id, "eDP-1").status, "restarted");
        tryCompare(host, "phase", "preparing"); compare(host.error, "");
    }
    function test_ambiguous_outputs_require_selection() {
        const first = makeHost(); const second = makeHost("DP-1");
        const generation = first.revealGeneration;
        compare(subject.restartTerminal(first.widget.id, "").status, "ambiguous");
        compare(first.revealGeneration, generation);
        compare(subject.restartTerminal(first.widget.id, "DP-1").status, "restarted");
        compare(first.revealGeneration, generation);
    }
    function test_hidden_and_editing_hosts_never_restart() {
        const host = makeHost(); host.visible = false;
        const generation = host.revealGeneration;
        compare(subject.restartTerminal(host.widget.id, "").status, "unavailable");
        compare(host.revealGeneration, generation);
        host.visible = true; subject.editMode = true;
        compare(subject.restartTerminal(host.widget.id, "").status, "unavailable");
        subject.editMode = false; host.editing = true;
        compare(subject.restartTerminal(host.widget.id, "").status, "unavailable");
        compare(subject.restartTerminal("missing", "").status, "unavailable");
    }
}
