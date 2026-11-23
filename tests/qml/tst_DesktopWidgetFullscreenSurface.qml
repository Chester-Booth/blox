import QtQuick
import QtQuick.Window
import QtTest
import qs.shared
import "../../shell/services" as Services
import "../../widgets/tests/fixtures" as Fixtures

TestCase {
    id: test
    name: "DesktopWidgetFullscreenSurface"
    when: windowShown
    property var firstHost: null
    property var repeaters: []
    property var otherHost: null
    property var keyboardHost: desktopState ? desktopState.keyboardHost : null
    property string fullscreenWidgetId: desktopState ? desktopState.fullscreenWidgetId : ""
    property string fullscreenOutputName: desktopState ? desktopState.fullscreenOutputName : ""
    property string hostAdapter: ""
    property var outputSurface: desktopSurface
    property var fullscreenSurface: raisedSurface
    property var reconciliations: []
    property var desktopState: null
    property var barAdapter: null
    property var surfaceController: barController
    property string originalBarPosition: ""
    Services.BarSurfaceController { id: barController }
    Fixtures.TerminalFixtureDecoder { id: terminalDecoder }
    Window { id: desktopWindow; width: 400; height: 300; visible: true }
    Window { id: fullscreenWindow; width: 400; height: 300; visible: raisedSurface.visible }
    QtObject {
        id: desktopSurface
        property Item contentItem: desktopWindow.contentItem
        property var screen: ({name: "DP-1"})
        property int width: 400
        property int height: 300
        property bool visible: true
        property int focusRequests: 0
        function focusKeyboardRenderer() { focusRequests++; }
    }
    QtObject {
        id: raisedSurface
        property Item contentItem: fullscreenWindow.contentItem
        property var screen: desktopSurface.screen
        property bool visible: false
        property bool keyboardFocused: false
    }
    QtObject {
        id: provider
        property int subscriptions: 0
        property int cancellations: 0
        signal snapshotReady(string consumerId, var snapshot)
        function subscribe(id, kind, settings, generation) {
            subscriptions++;
            terminalDecoder.prepare(id, generation);
            Qt.callLater(function() {
                const envelope = {generation: generation, revision: 0, observedMonotonicMs: 1,
                    state: "ready", error: "", value: {columns: 80, rowCount: 24,
                        rows: Array.from({length: 24}, function() { return {runs: []}; })}};
                snapshotReady(id, terminalDecoder.generations[id] === generation
                    ? terminalDecoder.adapt(id, envelope) : envelope);
            });
        }
        function unsubscribe(id) { cancellations++; terminalDecoder.release(id); }
        function dispatchAction(id, action, payload) {}
    }
    function interactiveWidget(widget) { return true; }
    function reconcileKeyboardFocus() { reconciliations = reconciliations.concat([keyboardHost]); }
    function source(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path || "../../shell/modules/DesktopWidgets.qml"), false);
        request.send();
        return request.responseText;
    }
    function line(text, pattern) {
        const match = text.match(pattern);
        verify(match !== null, "Missing production binding " + pattern);
        return match[0].trim();
    }
    function block(text, marker) {
        const start = text.indexOf(marker);
        verify(start >= 0, "Missing production block " + marker);
        let index = text.indexOf("{", start), depth = 1;
        while (depth && ++index < text.length) {
            if (text[index] === "{") depth++;
            if (text[index] === "}") depth--;
        }
        return text.slice(start, index + 1);
    }
    function initTestCase() {
        const desktop = source();
        originalBarPosition = Theme.barPosition;
        // Execute the production output list and registry, then the shell's Bar binding.
        desktopState = Qt.createQmlObject('import QtQuick; QtObject { id: root; '
            + 'property var hosts: []; property string fullscreenWidgetId: ""; '
            + 'property string fullscreenOutputName: ""; property var keyboardHost: null; '
            + line(desktop, /^\s*readonly property var visibleFullscreenOutputs: [^\n]+/m) + '\n'
            + block(desktop, "function registerHost(") + '\n' + block(desktop, "function unregisterHost(") + '}', test);
        const shell = source("../../shell/shell.qml");
        const shellBar = block(shell, "Bar {");
        const shellWidgets = block(shell, "DesktopWidgets {");
        const widgetId = line(shellWidgets, /^\s*id: [^\n]+/m).replace("id: ", "");
        const bar = source("../../shell/modules/Bar.qml");
        const rail = bar.slice(bar.indexOf("id: railSurface"), bar.indexOf("HoverHandler {", bar.indexOf("id: railSurface")));
        const panelStart = bar.indexOf("id: panel");
        const panel = bar.slice(panelStart, bar.indexOf("Connections {", panelStart));
        barAdapter = Qt.createQmlObject('import QtQuick; import qs.shared; Item { id: root; '
            + 'property var ' + widgetId + ': test.desktopState; property var barSurfaceController: test.surfaceController; '
            + line(bar, /^\s*property var fullscreenWidgetOutputs: [^\n]+/m).replace(/:.*$/, "") + '; '
            + line(shellBar, /^\s*fullscreenWidgetOutputs: [^\n]+/m) + '\n'
            + 'property alias firstPanel: first; property alias secondPanel: second; '
            + ['first', 'second'].map(function(id, index) {
                return 'Item { id: ' + id + '; property var modelData: ({name: "' + (index ? 'DP-2' : 'DP-1') + '", width: 400, height: 300}); '
                    + 'property alias rail: ' + id + 'Rail; property int exclusiveZone; '
                    + line(panel, /^\s*readonly property int barInset: [^\n]+/m) + '\n'
                    + line(panel, /^\s*readonly property int barDepth: [^\n]+/m) + '\n'
                    + line(panel, /^\s*readonly property int barEndInset: [^\n]+/m) + '\n'
                    + ['implicitWidth', 'implicitHeight', 'exclusiveZone', 'visible'].map(function(name) {
                        return line(panel, new RegExp('^\\s*' + name + ': [^\\n]+', 'm'));
                    }).join('\n') + '\n'
                    + 'Rectangle { id: ' + id + 'Rail; property var panel: parent; '
                    + ['opacity', 'x', 'y', 'width', 'height'].map(function(name) {
                        return line(rail, new RegExp('^\\s*' + name + ': [^\\n]+', 'm'));
                    }).join('\n') + '} }';
            }).join('\n') + '}', test);
        const surface = desktop.slice(desktop.indexOf("id: fullscreenSurface"), desktop.indexOf("Repeater {"));
        raisedSurface.visible = Qt.binding(new Function("root", "outputSurface", "screen", "return "
            + line(surface, /^\s*visible: [^\n]+/m).replace(/^visible: /, "")).bind(null, test, desktopSurface, raisedSurface.screen));
        raisedSurface.keyboardFocused = Qt.binding(new Function("root", "fullscreenSurface", "return "
            + line(surface, /^\s*readonly property bool keyboardFocused: [^\n]+/m).replace(/^readonly property bool keyboardFocused: /, "")).bind(null, test, raisedSurface));
        const delegate = block(desktop, "Widgets.WidgetHost {");
        hostAdapter = [
            line(delegate, /^\s*readonly property var outputWindow: [^\n]+/m),
            line(delegate, /^\s*readonly property string outputName: [^\n]+/m),
            line(delegate, /^\s*readonly property bool fullscreenVisible: [^\n]+/m),
            block(delegate, "property Region inputRegion:"),
            block(delegate, "property Region fullscreenInputRegion:"),
            line(delegate, /^\s*parent: [^\n]+/m),
            line(delegate, /^\s*fullscreenBounds: [^\n]+/m),
            line(delegate, /^\s*fullscreen: [^\n]+/m),
            line(delegate, /^\s*z: [^\n]+/m),
            line(delegate, /^\s*visible: [^\n]+/m),
            block(delegate, "onOutputWindowChanged:"),
            line(delegate, /^\s*onVisibleChanged: [^\n]+/m)
        ].join("\n");
        verify(desktop.includes("WlrLayershell.layer: WlrLayer.Background"));
        verify(surface.includes("WlrLayershell.layer: WlrLayer.Overlay"));
    }
    function makeHost(id) {
        const profile = {id: id, kind: "terminal", name: id, enabled: true,
            placement: {anchor: "top-left", x: 10, y: 10, width: 80, height: 60},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.42, scrollbars: "auto"},
            fullscreen: {enabled: true, mode: "fit"},
            settings: {command: ["fixture-never-executed"], workingDirectory: "", environment: {}, columns: 80, rows: 24}};
        const repeater = Qt.createQmlObject('import QtQuick; import QtQuick.Window; import Quickshell; '
            + 'import "../../widgets/qml/Blox/Widgets" as Widgets; Repeater { model: 1; delegate: Widgets.WidgetHost { id: host; '
            + 'property var root: test; property var outputSurface: test.outputSurface; '
            + 'property var fullscreenSurface: test.fullscreenSurface; '
            + 'widget: (' + JSON.stringify(profile) + '); placementBounds: Qt.rect(20, 34, 380, 266); ' + hostAdapter + '} }', test, Qt.resolvedUrl("FullscreenSurfaceHost.qml"));
        repeaters = repeaters.concat([repeater]);
        const host = repeater.itemAt(0);
        host.provider = provider;
        desktopState.registerHost(host);
        return host;
    }
    function init() {
        terminalDecoder.reset();
        desktopState.fullscreenWidgetId = "";
        desktopState.fullscreenOutputName = "";
        desktopState.keyboardHost = null;
        provider.subscriptions = 0;
        provider.cancellations = 0;
        desktopSurface.visible = true;
        barController.barOpen = true;
        firstHost = makeHost("selected");
        otherHost = makeHost("ordinary");
        tryCompare(firstHost, "phase", "visible");
        tryCompare(otherHost, "phase", "visible");
    }
    function cleanup() {
        desktopState.keyboardHost = null;
        desktopState.fullscreenWidgetId = "";
        desktopState.fullscreenOutputName = "";
        repeaters.forEach(item => item.destroy());
        repeaters = [];
        desktopState.hosts = [];
        firstHost = null;
        otherHost = null;
        wait(0);
    }
    function cleanupTestCase() { Theme.barPosition = originalBarPosition; }
    function compareBars(covered) {
        compare(barAdapter.firstPanel.rail.opacity, covered ? 0 : 1);
        compare(barAdapter.secondPanel.rail.opacity, 1);
        compare(desktopState.visibleFullscreenOutputs, covered ? ["DP-1"] : []);
    }
    function test_waits_for_visible_destination_without_cancelling_provider() {
        const generation = firstHost.revealGeneration, view = firstHost.view;
        const destination = Qt.createQmlObject('import QtQuick; Item { width: 400; height: 300; visible: false }', fullscreenWindow.contentItem);
        raisedSurface.contentItem = destination;
        desktopState.fullscreenWidgetId = "selected";
        desktopState.fullscreenOutputName = "DP-1";
        compare(firstHost.parent, desktopWindow.contentItem);
        compare(firstHost.inputRegion.width, 400);
        compare(firstHost.fullscreenInputRegion.width, 0);
        compareBars(false);
        destination.visible = true;
        tryCompare(firstHost, "parent", destination);
        compare(firstHost.inputRegion.width, 0);
        compare(firstHost.fullscreenInputRegion.width, 400);
        compare(firstHost.view, view);
        compare(firstHost.revealGeneration, generation);
        compare(provider.subscriptions, 2);
        compare(provider.cancellations, 0);
        compareBars(true);
        desktopState.fullscreenWidgetId = "";
        desktopState.fullscreenOutputName = "";
        raisedSurface.contentItem = fullscreenWindow.contentItem;
        destination.destroy();
    }
    function test_repeated_fullscreen_moves_only_selected_host_without_restarting_provider() {
        const snapshot = firstHost.snapshot, view = firstHost.view, generation = firstHost.revealGeneration;
        const normalGeometry = Qt.rect(firstHost.x, firstHost.y, firstHost.width, firstHost.height);
        compare(firstHost.Window.window, desktopWindow);
        compare(raisedSurface.visible, false);
        compare(firstHost.inputRegion.width, 80);
        compare(firstHost.fullscreenInputRegion.width, 0);
        for (let iteration = 0; iteration < 3; iteration++) {
            desktopState.keyboardHost = firstHost;
            desktopState.fullscreenWidgetId = firstHost.widget.id;
            desktopState.fullscreenOutputName = "DP-1";
            tryCompare(firstHost, "parent", fullscreenWindow.contentItem);
            compare(firstHost.Window.window, fullscreenWindow);
            compare(otherHost.Window.window, desktopWindow);
            compare(raisedSurface.visible, true);
            compareBars(true);
            compare(raisedSurface.keyboardFocused, true);
            compare(firstHost.inputRegion.width, 0);
            compare(firstHost.fullscreenInputRegion.width, 400);
            compare(firstHost.fullscreenInputRegion.height, 300);
            compare(otherHost.fullscreenInputRegion.width, 0);
            compare(otherHost.inputRegion.width, 80);
            compare(Qt.rect(firstHost.x, firstHost.y, firstHost.width, firstHost.height), Qt.rect(0, 0, 400, 300));
            compare(firstHost.phase, "visible");
            compare(firstHost.snapshot, snapshot);
            compare(firstHost.view, view);
            compare(firstHost.revealGeneration, generation);
            compare(provider.subscriptions, 2);
            compare(provider.cancellations, 0);
            desktopState.fullscreenWidgetId = "";
            desktopState.fullscreenOutputName = "";
            desktopState.keyboardHost = null;
            tryCompare(firstHost, "parent", desktopWindow.contentItem);
            compare(raisedSurface.visible, false);
            compare(raisedSurface.keyboardFocused, false);
            compare(firstHost.fullscreenInputRegion.width, 0);
            compare(firstHost.inputRegion.width, 80);
            compare(Qt.rect(firstHost.x, firstHost.y, firstHost.width, firstHost.height), normalGeometry);
            compare(firstHost.revealGeneration, generation);
            compare(firstHost.view, view);
            compare(provider.cancellations, 0);
            compareBars(false);
        }
    }
    function test_wrong_output_and_hidden_host_have_no_fullscreen_input_region() {
        desktopState.fullscreenWidgetId = "selected";
        desktopState.fullscreenOutputName = "DP-2";
        compare(raisedSurface.visible, false);
        compareBars(false);
        compare(firstHost.parent, desktopWindow.contentItem);
        compare(firstHost.fullscreenInputRegion.width, 0);
        desktopState.fullscreenOutputName = "DP-1";
        tryCompare(firstHost, "parent", fullscreenWindow.contentItem);
        desktopSurface.visible = false;
        compare(firstHost.fullscreenInputRegion.width, 0);
        compare(firstHost.inputRegion.width, 0);
        compare(otherHost.inputRegion.width, 0);
        compare(raisedSurface.visible, false);
        compareBars(false);
    }

    function test_covered_visual_preserves_bar_state_and_geometry_data() {
        const rows = [];
        for (const position of ["left", "right", "top", "bottom"])
            for (const pinned of [true, false]) rows.push({tag: position + (pinned ? "-pinned" : "-hidden"), position: position, pinned: pinned});
        return rows;
    }
    function test_covered_visual_preserves_bar_state_and_geometry(data) {
        Theme.barPosition = data.position;
        barController.barOpen = data.pinned;
        tryCompare(barController, "barSlide", data.pinned ? 1 : 0, 500);
        const panel = barAdapter.firstPanel;
        function layout() {
            return JSON.stringify([barController.barOpen, barController.barPinnedOpen, barController.barVisible,
                barController.barSlide, barController.occupiedBar, barController.reservationKey,
                panel.visible, panel.exclusiveZone, panel.width, panel.height,
                panel.rail.x, panel.rail.y, panel.rail.width, panel.rail.height,
                otherHost.x, otherHost.y, otherHost.width, otherHost.height]);
        }
        const before = layout();
        desktopState.fullscreenWidgetId = "selected";
        desktopState.fullscreenOutputName = "DP-1";
        tryCompare(firstHost, "parent", fullscreenWindow.contentItem);
        compareBars(true);
        compare(findChild(firstHost, "widgetBackground").opacity, 0.42);
        compare(layout(), before);
        desktopState.fullscreenWidgetId = "";
        desktopState.fullscreenOutputName = "";
        compareBars(false);
        compare(layout(), before);
    }

    function test_workspace_and_provider_readiness_restore_bar_without_clearing_selection() {
        const profile = JSON.parse(JSON.stringify(firstHost.widget));
        profile.workspaces = {mode: "include", ids: [1], ranges: []};
        firstHost.widget = profile;
        tryCompare(firstHost, "phase", "visible");
        desktopState.fullscreenWidgetId = "selected";
        desktopState.fullscreenOutputName = "DP-1";
        compareBars(true);
        firstHost.workspace = {id: 2, name: "2", special: false, empty: true};
        tryCompare(firstHost, "phase", "hidden");
        compareBars(false);
        compare(fullscreenWidgetId, "selected");
        firstHost.workspace = {id: 1, name: "1", special: false, empty: true};
        tryCompare(firstHost, "phase", "visible");
        compareBars(true);
        for (const state of ["preparing", "unavailable", "ready"]) {
            const envelope = Object.assign({}, firstHost.snapshot, {state: state, revision: firstHost.snapshot.revision + 1});
            provider.snapshotReady(firstHost.consumerId, envelope);
            compare(firstHost.phase, state === "ready" ? "visible" : state);
            compareBars(state === "ready");
        }
        firstHost.visible = false;
        compareBars(false);
        firstHost.visible = true;
        tryCompare(firstHost, "phase", "visible");
        compareBars(true);
    }

    function test_output_removal_unregisters_selected_host_and_restores_bar() {
        desktopState.fullscreenWidgetId = "selected";
        desktopState.fullscreenOutputName = "DP-1";
        compareBars(true);
        desktopState.unregisterHost(firstHost);
        repeaters[0].destroy();
        repeaters = repeaters.slice(1);
        firstHost = null;
        wait(0);
        compare(fullscreenWidgetId, "");
        compare(fullscreenOutputName, "");
        compareBars(false);
    }
}
