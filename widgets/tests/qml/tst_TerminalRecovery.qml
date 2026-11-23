import QtQuick
import QtTest
import Blox.Widgets 1.0
import "../../qml/Blox/Widgets/Native" as Native
import "../fixtures" as Fixtures

TestCase {
    id: test
    name: "TerminalRecovery"
    when: windowShown
    visible: true
    width: 1000
    height: 760

    WidgetTheme { id: widgetTheme }
    Fixtures.TerminalFixtureDecoder { id: decoder }
    Component { id: terminalComponent; Native.TerminalView {} }
    Component { id: hostComponent; WidgetHost {} }
    QtObject {
        id: provider
        property int subscriptions: 0
        property int cancellations: 0
        signal snapshotReady(string consumerId, var envelope)
        signal connectionError(string message)
        function subscribe(id, kind, options, generation) { subscriptions++; decoder.prepare(id, generation); }
        function unsubscribe(id) { cancellations++; decoder.release(id); }
    }
    property var terminal
    property var host: null
    property int refreshes: 0
    property int revision: 0
    SignalSpy { id: actions; signalName: "actionRequested" }

    function viewContext(extra) {
        return Object.assign({presentation: "open", scrollbars: "hide", editing: false,
            fullscreenMode: "fit", fullscreenEnabled: false,
            requestRefresh: function() { test.refreshes++; }}, extra || {});
    }
    function envelope(lifecycle, extra, state, error) {
        return {state: state || "ready", generation: 1, revision: ++revision,
            observedMonotonicMs: revision, error: error || "", value: Object.assign({
                generation: 1, attempt: 1, sequence: revision, columns: 40, rowCount: 8,
                rows: [{runs: [{column: 0, text: "owned fixture", cells: Array.from("owned fixture")}]}],
                changedRuns: [], lifecycle: lifecycle, exitCode: null, restartPending: false}, extra || {})};
    }
    function publish(lifecycle, extra, state, error) { terminal.snapshot = decoder.adapt("standalone", envelope(lifecycle, extra, state, error)); }
    function part(name) { const item = findChild(terminal, name); verify(item !== null, name); return item; }
    function init() {
        failOnWarning(/.*/);
        refreshes = 0; revision = 0;
        decoder.reset();
        widgetTheme.densityScale = 1; widgetTheme.radiusScale = 1;
        widgetTheme.fontSize = 14;
        widgetTheme.palette = {background: "#142739", foreground: "#eddfc9", muted: "#87ab63",
            accent: "#d17f22", negative: "#c82468"};
        widgetTheme.iconRoot = Qt.resolvedUrl("../../../shell/assets/phosphor/");
        terminal = terminalComponent.createObject(test, {width: 480, height: 280,
            theme: widgetTheme, settings: {columns: 40, rows: 8}, context: viewContext()});
        verify(terminal !== null);
        actions.target = terminal; actions.clear();
        publish("running");
        tryCompare(terminal, "contentReady", true);
    }
    function cleanup() {
        actions.target = null;
        if (host) { host.destroy(); host = null; }
        terminal.destroy(); terminal = null;
        wait(0);
    }
    function test_lifecycle_data() {
        return [
            {tag: "running", lifecycle: "running", text: "", shown: false},
            {tag: "retained-success", lifecycle: "retained-success", extra: {exitCode: 0}, text: "Retained · exit 0", shown: true},
            {tag: "retained-failure", lifecycle: "retained-failure", extra: {exitCode: 1}, text: "Retained · exit 1", shown: true, failed: true},
            {tag: "signal", lifecycle: "retained-failure", extra: {exitCode: -15}, text: "Retained · exit -15", shown: true, failed: true},
            {tag: "launch-failure", lifecycle: "retained-failure", extra: {failure: {kind: "launch-failed", errno: 2}}, text: "Retained · launch failed", shown: true, failed: true},
            {tag: "backoff", lifecycle: "backoff", extra: {exitCode: 1, restartPending: true, restartDelaySeconds: 2}, text: "Retained · exit 1 · retry pending", shown: true},
            {tag: "launch-backoff", lifecycle: "backoff", extra: {failure: {kind: "launch-failed"}, restartPending: true}, text: "Retained · launch failed · retry pending", shown: true},
            {tag: "draining", lifecycle: "draining", extra: {exitCode: 0}, text: "Draining · exit 0", shown: true},
            {tag: "runtime-limit", lifecycle: "runtime-limit", extra: {stopReason: "runtime-limit"}, text: "Retained · runtime limit", shown: true},
            {tag: "empty-success", lifecycle: "retained-success", extra: {exitCode: 0, rows: []}, text: "Retained · exit 0", shown: true},
            // Standalone presentation only. The host-level gap is tested below.
            {tag: "unavailable", lifecycle: "running", state: "unavailable", error: "parser error", text: "Unavailable · parser error", shown: true, failed: true},
            {tag: "unknown", lifecycle: "future-state", text: "", shown: false}
        ];
    }
    function test_lifecycle(data) {
        publish(data.lifecycle, data.extra, data.state, data.error);
        compare(part("terminalRecoveryRow").visible, data.shown);
        compare(part("terminalRecoveryStatus").text, data.text);
        compare(terminal.recoveryFailed, !!data.failed);
        compare(part("terminalRecoveryStatus").color, data.failed ? widgetTheme.palette.negative : widgetTheme.palette.muted);
        compare(part("terminalRestartAction").enabled, data.shown);
        const viewport = part("terminalViewport");
        compare(viewport.height, terminal.height - 2 * terminal.padding - (data.shown ? 30 * terminal.density : 0));
        if (data.shown) verify(viewport.y + viewport.height <= part("terminalRecoveryRow").y);
    }
    function test_pointerAndKeyboardUseRefreshOnly() {
        publish("retained-failure", {exitCode: 7});
        const restart = part("terminalRestartAction");
        compare(restart.Accessible.name, "Restart terminal");
        mouseClick(restart, restart.width / 2, restart.height / 2);
        compare(refreshes, 1);
        // Traverse from the containing view so this also checks tab eligibility.
        terminal.forceActiveFocus();
        keyClick(Qt.Key_Tab);
        tryCompare(restart, "activeFocus", true);
        keyClick(Qt.Key_Space);
        compare(refreshes, 2);
        compare(actions.count, 0);
    }
    function test_ineligibleControlsCannotRefresh_data() {
        return [{tag: "editing"}, {tag: "hidden"}, {tag: "zero-width"},
            {tag: "zero-height"}, {tag: "missing-callback"}, {tag: "running"}];
    }
    function test_ineligibleControlsCannotRefresh(data) {
        publish("retained-success", {exitCode: 0});
        const restart = part("terminalRestartAction");
        restart.forceActiveFocus();
        if (data.tag === "editing") terminal.context = viewContext({editing: true});
        if (data.tag === "hidden") terminal.visible = false;
        if (data.tag === "zero-width") terminal.width = 0;
        if (data.tag === "zero-height") terminal.height = 0;
        if (data.tag === "missing-callback") terminal.context = {};
        if (data.tag === "running") publish("running");
        compare(restart.enabled, false);
        if (data.tag === "editing" || data.tag === "missing-callback")
            mouseClick(restart, restart.width / 2, restart.height / 2);
        keyClick(Qt.Key_Space); keyClick(Qt.Key_Return);
        terminal.restartTerminal();
        compare(refreshes, 0);
        compare(actions.count, 0);
    }
    function test_themeDensityAndNarrowBounds_data() {
        return [{tag: "open", density: 1, presentation: "open", width: 480, height: 280, rounding: 1},
            {tag: "compact", density: 1.5, presentation: "compact", width: 360, height: 240, rounding: 2},
            {tag: "narrow", density: 0.75, presentation: "compact", width: 80, height: 70, rounding: 0},
            {tag: "tiny", density: 2, presentation: "open", width: 24, height: 18, rounding: 1}];
    }
    function test_themeDensityAndNarrowBounds(data) {
        terminal.width = data.width; terminal.height = data.height;
        widgetTheme.densityScale = data.density; widgetTheme.radiusScale = data.rounding;
        widgetTheme.fontFamily = "DejaVu Sans";
        terminal.context = viewContext({presentation: data.presentation});
        publish("retained-failure", {exitCode: 1});
        const restart = part("terminalRestartAction"), row = part("terminalRecoveryRow"), status = part("terminalRecoveryStatus");
        compare(restart.foreground, widgetTheme.palette.accent);
        compare(restart.fontFamily, widgetTheme.fontFamily);
        compare(status.font.family, widgetTheme.fontFamily);
        compare(status.font.pixelSize, 12);
        compare(restart.rounding, data.rounding);
        compare(restart.background.radius, Math.min(restart.width / 2, restart.height / 2, 5 * data.rounding));
        verify(row.x >= 0 && row.y >= 0 && row.x + row.width <= terminal.width);
        verify(row.y + row.height <= terminal.height);
        verify(status.width >= 0 && restart.width <= row.width && restart.height <= row.height);
        verify(part("terminalViewport").height >= 0);
        const image = grabImage(terminal);
        compare(image.width, terminal.width);
        compare(image.height, terminal.height);
    }
    function test_fullscreenModesReserveRow_data() {
        return [{tag: "fit", mode: "fit"}, {tag: "scroll", mode: "scroll"}, {tag: "resize", mode: "resize"}];
    }
    function test_fullscreenModesReserveRow(data) {
        terminal.context = viewContext({fullscreenMode: data.mode, fullscreenEnabled: true});
        terminal.fullscreen = true;
        publish("retained-success", {exitCode: 0});
        const viewport = part("terminalViewport"), canvas = part("terminalCanvas"), row = part("terminalRecoveryRow");
        verify(viewport.y + viewport.height <= row.y);
        compare(terminal.scrollbarMode, "hide");
        compare(viewport.interactive, data.mode === "scroll");
        const restore = part("widgetFullscreenAction");
        compare(restore.iconName, "arrows-in-line-horizontal");
        compare(restore.iconRoot, widgetTheme.iconRoot);
        verify(restore.hasIcon);
        if (data.mode === "fit") {
            verify(canvas.displayWidth <= viewport.width + 0.01);
            verify(canvas.displayHeight <= viewport.height + 0.01);
        }
        if (data.mode === "resize") {
            tryCompare(actions, "count", 1);
            const size = actions.signalArguments[0][1];
            compare(size.rows, Math.min(100, Math.floor(12000 / size.columns), Math.max(1, Math.floor(viewport.height / terminal.cellHeight))));
            compare(size.columns, Math.min(240, Math.max(2, Math.floor(viewport.width / terminal.cellWidth))));
        } else compare(actions.count, 0);
        mouseClick(part("terminalRestartAction"));
        compare(refreshes, 1);
    }
    function test_runningRestoresSpaceAndBackoffIsStatic() {
        const viewport = part("terminalViewport"), initialHeight = viewport.height;
        publish("backoff", {exitCode: 1, restartPending: true, restartDelaySeconds: 0.5});
        const status = part("terminalRecoveryStatus").text;
        wait(90);
        compare(part("terminalRecoveryStatus").text, status);
        compare(actions.count, 0);
        publish("running", {attempt: 2, rows: []});
        compare(viewport.height, initialHeight);
        compare(part("terminalRecoveryRow").visible, false);
        tryCompare(terminal, "contentReady", true);
    }
    function makeHost() {
        host = hostComponent.createObject(test, {provider: provider, theme: widgetTheme,
            placementBounds: Qt.rect(0, 0, 800, 600), widget: {
                id: "terminal-recovery-fixture", kind: "terminal", enabled: true, visibility: "always",
                placement: {anchor: "top-left", x: 500, y: 20, width: 480, height: 280, sizing: "fixed"},
                workspaces: {mode: "all", ids: [], ranges: []},
                appearance: {backgroundOpacity: 1, scrollbars: "hide"},
                fullscreen: {enabled: true, mode: "fit"},
                settings: {columns: 40, rows: 8, restartPolicy: "never", maxRuntimeSeconds: 0}}});
        verify(host !== null);
        tryCompare(host, "phase", "preparing");
    }
    function deliver(lifecycle, state) {
        const frame = envelope(lifecycle, {exitCode: 1}, state, state === "unavailable" ? "fixture unavailable" : "");
        frame.generation = host.revealGeneration; frame.value.generation = host.revealGeneration;
        provider.snapshotReady(host.consumerId, decoder.adapt(host.consumerId, frame));
    }
    function test_realHostRestartInvalidatesGenerationAndStaleCallback() {
        makeHost(); deliver("retained-failure");
        tryCompare(host, "phase", "visible");
        const oldGeneration = host.revealGeneration, staleRefresh = host.view.context.requestRefresh;
        const cancellations = provider.cancellations, subscriptions = provider.subscriptions;
        const restart = findChild(host.view, "terminalRestartAction");
        mouseClick(restart, restart.width / 2, restart.height / 2);
        verify(host.revealGeneration > oldGeneration);
        compare(provider.cancellations, cancellations + 1);
        tryCompare(provider, "subscriptions", subscriptions + 1);
        const generation = host.revealGeneration;
        staleRefresh();
        compare(host.revealGeneration, generation);
        deliver("running");
        tryCompare(host, "phase", "visible");
        compare(findChild(host.view, "terminalRecoveryRow").visible, false);
    }
    function test_unavailableHostHidesThenDisconnectUnloadsView() {
        makeHost(); deliver("retained-failure");
        tryCompare(host, "phase", "visible");
        deliver("unavailable", "unavailable");
        compare(host.phase, "unavailable");
        verify(host.view !== null);
        compare(host.view.visible, false);
        compare(findChild(host.view, "terminalRestartAction").visible, false);
        provider.connectionError("owned fixture disconnect");
        compare(host.phase, "unavailable");
        tryCompare(host, "view", null);
        // This is a documented integration limit, not coverage of a clickable row.
    }
}
