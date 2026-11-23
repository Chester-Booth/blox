import QtQuick
import QtTest
import Blox.Widgets 1.0
import "../../../shell/shared/models" as Shared

TestCase {
    id: test
    name: "WidgetItemModel"
    when: windowShown
    visible: true
    width: 1000
    height: 700
    property var fixture: null

    Component {
        id: fixtureComponent
        Item {
            id: adapter
            width: 1000; height: 700
            property var items: []
            property int created: 0
            property int destroyed: 0
            property var registry: ({fixture: {source: Qt.resolvedUrl("fixtures/TestView.qml"), layouts: ["native"], providers: []}})
            readonly property var service: fakeProvider
            readonly property var widgetTheme: palette
            function hostFor(id) {
                for (let i = 0; i < delegates.count; ++i) {
                    const host = delegates.itemAt(i);
                    if (host.widget.id === id) return host;
                }
                return null;
            }
            function reload(profile) { items = JSON.parse(JSON.stringify(profile)); }
            WidgetTheme { id: palette }
            QtObject {
                id: fakeProvider
                property int starts: 0
                property int stops: 0
                property int nextFakePid: 1000
                property var processes: ({})
                signal snapshotReady(string consumerId, var envelope)
                function subscribe(id, kind, options, generation) {
                    const next = Object.assign({}, processes);
                    next[id] = {fakePid: ++nextFakePid, generation: generation, kind: kind};
                    processes = next;
                    starts++;
                    snapshotReady(id, {generation: generation, revision: 0, observedMonotonicMs: 1,
                        state: "ready", value: {columns: 80, rowCount: 24, rows: [], epochMs: 1000, hour: 1, minute: 2, second: 3}, error: ""});
                }
                function unsubscribe(id) {
                    if (!processes[id]) return;
                    const next = Object.assign({}, processes); delete next[id]; processes = next;
                    stops++;
                }
                function dispatchAction(id, action, payload) {}
            }
            Shared.WidgetItemModel { id: stableItems; items: adapter.items.filter(item => item.enabled) }
            Repeater {
                id: delegates
                model: stableItems
                WidgetHost {
                    required property string document
                    required property int index
                    widget: JSON.parse(document)
                    theme: adapter.widgetTheme
                    provider: fakeProvider
                    qmlRegistry: adapter.registry
                    Component.onCompleted: adapter.created++
                    Component.onDestruction: adapter.destroyed++
                }
            }
        }
    }
    function item(id) {
        return {id: id, kind: "terminal", name: id, enabled: true,
            placement: {anchor: "top-left", x: 10, y: 20, width: 300, height: 200},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 1, scrollbars: "auto"}, fullscreen: {enabled: true, mode: "fit"},
            settings: {command: ["fixture-no-execution", id], workingDirectory: "", environment: {},
                columns: 80, rows: 24, restartPolicy: "never", maxRuntimeSeconds: 0}};
    }
    function init() {
        fixture = fixtureComponent.createObject(test);
        verify(fixture !== null);
        fixture.reload([item("first"), item("second")]);
        tryCompare(fixture.service, "starts", 2);
    }
    function cleanup() { fixture.destroy(); fixture = null; wait(0); }
    function pid(host) { return fixture.service.processes[host.consumerId].fakePid; }

    function test_equalReloadAndVisualPlacementEditsPreserveBothHosts() {
        const first = fixture.hostFor("first"), second = fixture.hostFor("second");
        const firstPid = pid(first), secondPid = pid(second), generation = first.revealGeneration;
        fixture.reload(fixture.items);
        fixture.widgetTheme.palette = {background: "#334455", foreground: "#ddeeff"};
        fixture.widgetTheme.densityScale = 1.2;
        compare(fixture.hostFor("first"), first); compare(fixture.hostFor("second"), second);
        const next = JSON.parse(JSON.stringify(fixture.items));
        next[0].placement.x = 80; next[0].placement.width = 420;
        next[0].appearance.backgroundOpacity = 0.4;
        fixture.reload(next);
        wait(0);
        compare(fixture.hostFor("first"), first); compare(fixture.hostFor("second"), second);
        compare(first.x, 80); compare(first.width, 420);
        compare(first.widget.appearance.backgroundOpacity, 0.4);
        compare(pid(first), firstPid); compare(pid(second), secondPid);
        compare(first.revealGeneration, generation);
        compare(fixture.service.starts, 2); compare(fixture.service.stops, 0);
        compare(fixture.created, 2); compare(fixture.destroyed, 0);
    }
    function test_reorderInsertionAndRemovalPreserveUnaffectedIdentity() {
        const first = fixture.hostFor("first"), second = fixture.hostFor("second");
        const firstPid = pid(first), secondPid = pid(second);
        fixture.reload([item("second"), item("third"), item("first")]);
        tryCompare(fixture.service, "starts", 3);
        compare(fixture.hostFor("first"), first); compare(fixture.hostFor("second"), second);
        compare(pid(first), firstPid); compare(pid(second), secondPid);
        compare(first.index, 2); compare(second.index, 0);
        fixture.reload([item("third"), item("first")]);
        tryCompare(fixture.service, "stops", 1);
        compare(fixture.hostFor("second"), null);
        compare(fixture.hostFor("first"), first); compare(pid(first), firstPid);
        compare(first.index, 1);
        compare(fixture.created, 3); compare(fixture.destroyed, 1);
    }
    function test_settingsAndKindChangesRestartOnlyAffectedProvider() {
        const first = fixture.hostFor("first"), second = fixture.hostFor("second");
        const firstPid = pid(first), secondPid = pid(second);
        let next = JSON.parse(JSON.stringify(fixture.items)); next[0].settings.command = ["fixture-no-execution", "changed"];
        fixture.reload(next);
        tryCompare(fixture.service, "starts", 3);
        compare(fixture.service.stops, 1);
        compare(fixture.hostFor("first"), first); compare(fixture.hostFor("second"), second);
        verify(pid(first) !== firstPid); compare(pid(second), secondPid);
        next = JSON.parse(JSON.stringify(next)); next[0].kind = "clock";
        next[0].settings = {style: "digital", timezone: "local", format: "24h", showSeconds: false};
        next[0].fullscreen.mode = "native";
        fixture.reload(next);
        tryCompare(fixture.service, "starts", 4);
        compare(fixture.service.stops, 2);
        compare(fixture.hostFor("first"), first); compare(pid(second), secondPid);
        compare(fixture.created, 2); compare(fixture.destroyed, 0);
    }
    function test_disableAndHideCancelWithoutAffectingOtherWidgets() {
        const first = fixture.hostFor("first"), second = fixture.hostFor("second"), secondPid = pid(second);
        const next = JSON.parse(JSON.stringify(fixture.items)); next[0].enabled = false;
        fixture.reload(next);
        tryCompare(fixture.service, "stops", 1);
        compare(fixture.hostFor("first"), null); compare(pid(second), secondPid);
        fixture.visible = false;
        compare(fixture.service.stops, 2);
        fixture.visible = true;
        tryCompare(fixture.service, "starts", 3);
        compare(fixture.hostFor("second"), second); verify(pid(second) !== secondPid);
        next[0].enabled = true; fixture.reload(next);
        tryCompare(fixture.service, "starts", 4);
        verify(fixture.hostFor("first") !== first);
    }
    function test_customJsonFieldNamesSurviveModelAndInvalidateHost() {
        const first = fixture.hostFor("first"), second = fixture.hostFor("second"), secondPid = pid(second);
        const next = JSON.parse(JSON.stringify(fixture.items));
        next[0].kind = "qml"; next[0].fullscreen.mode = "native";
        next[0].settings = {manifest: "fixture", layouts: ["native"], providers: [],
            settings: JSON.parse('{"__proto__":{"value":1},"constructor":{"value":3}}')};
        fixture.reload(next);
        tryVerify(function() { return first.view !== null && first.widget.kind === "qml"; });
        compare(first.widget.settings.settings["__proto__"].value, 1);
        compare(first.widget.settings.settings.constructor.value, 3);
        verify(Object.keys(first.widget.settings.settings).indexOf("__proto__") >= 0);
        const generation = first.revealGeneration;
        next[0].settings.settings["__proto__"].value = 2;
        fixture.reload(next);
        tryVerify(function() { return first.revealGeneration > generation; });
        compare(first.widget.settings.settings["__proto__"].value, 2);
        const updated = first.revealGeneration;
        next[0].settings.settings.constructor.value = 4;
        fixture.reload(next);
        tryVerify(function() { return first.revealGeneration > updated; });
        compare(first.widget.settings.settings.constructor.value, 4);
        compare(fixture.hostFor("first"), first); compare(pid(second), secondPid);
    }
    function test_semanticallyEqualSettingsOrderDoesNotRestartDirectHost() {
        const first = fixture.hostFor("first"), firstPid = pid(first), generation = first.revealGeneration;
        const next = JSON.parse(JSON.stringify(first.widget));
        next.settings = {restartPolicy: "never", maxRuntimeSeconds: 0, rows: 24, columns: 80, environment: {},
            workingDirectory: "", command: ["fixture-no-execution", "first"]};
        // Exercise the SDK directly as well as canonical model documents.
        first.widget = next;
        wait(0);
        compare(pid(first), firstPid); compare(first.revealGeneration, generation);
        fixture.reload([next, item("second")]);
        wait(0);
        compare(fixture.service.starts, 2); compare(fixture.service.stops, 0);
    }
}
