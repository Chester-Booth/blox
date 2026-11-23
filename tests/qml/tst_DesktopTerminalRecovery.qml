import QtQuick
import QtQuick.Window
import QtTest
import qs.shared
import Blox.Widgets 1.0 as Widgets
import "../../widgets/tests/fixtures" as Fixtures

TestCase {
    id: test
    name: "DesktopTerminalRecovery"
    when: windowShown
    visible: true
    width: 1000
    height: 380
    property var subject
    property var outputs: []
    property var created: []
    property string desktopSource
    property string hostSource
    property string screenshotPath: ""
    property alias fixtureProvider: provider
    property alias fixtureTheme: widgetTheme
    property alias workspaceProvider: workspaceProvider
    Widgets.WidgetTheme { id: widgetTheme }
    Fixtures.TerminalFixtureDecoder { id: terminalDecoder }
    QtObject {
        id: workspaceProvider
        property var focusedMonitor: null
        property var activeToplevel: null
        property var workspaces: ({values: []})
    }
    QtObject { id: restore; property bool running: false; property var command: [] }
    QtObject {
        id: provider
        property int subscriptions: 0
        property int cancellations: 0
        signal snapshotReady(string consumerId, var envelope)
        signal connectionError(string message)
        function subscribe(id, kind, options, generation) {
            subscriptions++;
            if (kind === "terminal") terminalDecoder.prepare(id, generation);
        }
        function unsubscribe(id) { cancellations++; terminalDecoder.release(id); }
        function dispatchAction(id, action, payload) { fail("Fallback must not dispatch a provider action"); }
    }

    function block(source, marker) {
        const start = source.indexOf(marker);
        verify(start >= 0, "Missing production block " + marker);
        let index = source.indexOf("{", start), depth = 1;
        while (depth && ++index < source.length) {
            if (source[index] === "{") depth++;
            if (source[index] === "}") depth--;
        }
        return source.slice(start, index + 1);
    }
    function line(source, pattern) {
        const match = source.match(pattern);
        verify(match !== null, "Missing production binding " + pattern);
        return match[0].trim();
    }
    function initTestCase() {
        failOnWarning(/.*/);
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/modules/DesktopWidgets.qml"), false);
        request.send();
        desktopSource = request.responseText;
        const functions = ["workspaceForMonitor", "captureKeyboardReturnTarget", "restoreKeyboardReturnTarget",
            "interactiveWidget", "actionableHost", "terminalRecoveryAvailable", "restartTerminal", "focusWidget",
            "releaseKeyboardFocus", "releaseKeyboardFocusAfterOutsideClick", "reconcileKeyboardFocus",
            "registerHost", "unregisterHost", "toggleFullscreen", "validateCommandHost", "dispatchApplicationAction", "releaseHostKeyboardFocus"].map(name => block(desktopSource, "function " + name + "("))
            .join("\n").replace(/Hyprland\./g, "workspaceProvider.");
        subject = Qt.createQmlObject('import QtQuick; import Quickshell; QtObject { id: root; '
            + 'property var workspaceProvider: test.workspaceProvider; property var keyboardFocusRestore: restore; '
            + 'property var hosts: []; property bool editMode: false; property string keyboardWidgetId: ""; '
            + 'property var keyboardHost: null; property string keyboardReturnAddress: ""; property int keyboardReturnPid: 0; '
            + 'property string keyboardReturnClass: ""; property string fullscreenWidgetId: ""; property string fullscreenOutputName: ""; '
            + 'signal keyboardFocusRequested(string widgetId); signal applicationActionRequested(string action, var identity, var trustedContext); '
            + line(desktopSource, /^\s*readonly property var visibleFullscreenOutputs: [^\n]+/m) + '\n'
            + line(desktopSource, /^\s*onEditModeChanged: [^\n]+/m) + '\n' + functions + '}', test);
        // Execute the entire production host delegate.
        hostSource = block(desktopSource, "Widgets.WidgetHost {");
        hostSource = hostSource
            .replace("required property string document", "property string document")
            .replace("theme: sharedWidgetTheme", "theme: test.fixtureTheme")
            .replace("provider: nativeProvider", "provider: test.fixtureProvider")
            .replace("qmlRegistry: Theme.widgetRegistry", "qmlRegistry: ({})");
    }
    function makeOutput(name, left) {
        const normalFocus = desktopSource.match(/readonly property bool keyboardFocused: [^\n]+\n\s*&&[^\n]+/)[0];
        const fullStart = desktopSource.indexOf("id: fullscreenSurface");
        const fullSource = desktopSource.slice(fullStart);
        const fullFocus = fullSource.match(/readonly property bool keyboardFocused: [^\n]+\n\s*&&[^\n]+/)[0];
        const source = 'import QtQuick; import QtQuick.Window; import Quickshell; import Quickshell.Hyprland; Item { '
            + 'id: outputSurface; property var root: test.subject; property var screen: ({name: "' + name + '"}); '
            + 'property Item contentItem: outputSurface; property var outputMonitor: ({name: screen.name}); '
            + 'property var workspaceState: ({id: 1, name: "1", special: false, empty: true}); '
            + 'property rect widgetBounds: Qt.rect(20, 30, 460, 320); '
            + 'property alias raised: fullscreenSurface; property alias grab: grab; property alias mask: inputMask; '
            + 'property alias fullMask: fullscreenInputMask; x: ' + left + '; width: 500; height: 380; '
            + normalFocus + '\n' + block(desktopSource, "function focusKeyboardRenderer(") + '\n'
            + block(desktopSource, "function removeRegion(") + '\n'
            + 'Region { id: inputMask } Region { id: fullscreenInputMask } '
            + 'Item { id: fullscreenSurface; property Item contentItem: fullscreenSurface; property var screen: outputSurface.screen; '
            + 'width: outputSurface.width; height: outputSurface.height; '
            + fullFocus + '\n' + line(fullSource, /^\s*visible: [^\n]+/m) + '\n'
            + block(fullSource, "Shortcut {") + '} '
            + block(desktopSource, "HyprlandFocusGrab {").replace("HyprlandFocusGrab {", "HyprlandFocusGrab { id: grab;")
            + block(desktopSource, "Connections {\n                target: root")
            + block(desktopSource, "Shortcut {\n                sequence: \"Escape\"") + '}';
        const output = Qt.createQmlObject(source, test);
        verify(output !== null);
        outputs.push(output);
        return output;
    }
    function makeHost(output, kind) {
        const document = {id: "terminal-fixture", kind: kind || "terminal", enabled: true, visibility: "always",
            workspaces: {mode: "all", ids: [], ranges: []},
            placement: {anchor: "top-left", x: 12, y: 10, width: 360, height: 220, sizing: "fixed"},
            appearance: {backgroundOpacity: 0.4, scrollbars: "auto", presentation: "open"},
            fullscreen: {enabled: true, mode: "fit"}, settings: {columns: 20, rows: 3}};
        const source = 'import QtQuick; import QtQuick.Window; import Quickshell; import qs.shared; '
            + 'import Blox.Widgets 1.0 as Widgets
import "../../widgets/tests/fixtures" as Fixtures; ' + hostSource.replace('id: host', 'id: host; '
                + 'property var root: test.subject; property var outputSurface: test.outputs[' + outputs.indexOf(output) + ']; '
                + 'property var fullscreenSurface: outputSurface.raised; '
                + 'property var inputMask: outputSurface.mask; property var fullscreenInputMask: outputSurface.fullMask; '
                + 'document: ' + JSON.stringify(JSON.stringify(document)) + ';');
        // Keep output identity stable when the production delegate reparents for fullscreen.
        const host = Qt.createQmlObject(source, test);
        verify(host !== null);
        created.push(host);
        tryCompare(host, "phase", "preparing");
        return host;
    }
    function unavailable(host, message) {
        tryVerify(() => host.phase !== "hidden");
        provider.snapshotReady(host.consumerId, {generation: host.revealGeneration, revision: host.snapshot ? host.snapshot.revision + 1 : 10,
            observedMonotonicMs: 1, state: "unavailable", error: message || "Fixture provider failure", value: {}});
        tryCompare(host, "phase", "unavailable");
        tryVerify(() => host.recoveryRow !== null);
        return findChild(host.recoveryRow, "terminalUnavailableRestart");
    }
    function ready(host, generation) {
        const envelope = {generation: generation === undefined ? host.revealGeneration : generation,
            revision: 20, observedMonotonicMs: 2, state: "ready", error: "",
            value: host.widget.kind === "command" ? {text: "Fixture output"}
                : {columns: 20, rowCount: 3, rows: [{runs: []}, {runs: []}, {runs: []}], sequence: 1}};
        // Stale envelopes exercise the host guard without replacing the active native subscription.
        provider.snapshotReady(host.consumerId, host.widget.kind === "terminal"
            && envelope.generation === host.revealGeneration
            ? terminalDecoder.adapt(host.consumerId, envelope) : envelope);
    }
    function init() {
        terminalDecoder.reset();
        provider.subscriptions = 0; provider.cancellations = 0;
        restore.running = false; restore.command = [];
        widgetTheme.densityScale = 1; widgetTheme.radiusScale = 1;
        subject.editMode = false;
        subject.keyboardHost = null; subject.keyboardWidgetId = "";
        subject.fullscreenWidgetId = ""; subject.fullscreenOutputName = "";
        workspaceProvider.focusedMonitor = null; workspaceProvider.activeToplevel = null;
        outputs = []; created = [];
    }
    function cleanup() {
        for (const host of created) host.destroy();
        wait(0);
        compare(subject.hosts.length, 0);
        for (const output of outputs) {
            compare(output.mask.regions.length, 0);
            compare(output.fullMask.regions.length, 0);
            output.destroy();
        }
        wait(0);
    }

    function test_provider_failure_pointer_restart_and_stale_generation() {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        const button = unavailable(host);
        verify(host.view !== null);
        compare(host.view.visible, false);
        compare(findChild(host.recoveryRow, "terminalUnavailableStatus").text, "Unavailable · Fixture provider failure");
        compare(subject.keyboardHost, null);
        compare(output.keyboardFocused, false);
        compare(output.grab.active, false);
        const generation = host.revealGeneration, cancels = provider.cancellations, subscriptions = provider.subscriptions;
        mouseClick(button, button.width / 2, button.height / 2);
        verify(host.revealGeneration > generation);
        compare(provider.cancellations, cancels + 1);
        tryCompare(host, "phase", "preparing");
        compare(provider.subscriptions, subscriptions + 1);
        compare(host.recoveryRow, null);
        compare(host.recoveryInputRegion.width, 0);
        compare(output.grab.active, false);
        ready(host, generation);
        compare(host.phase, "preparing");
        ready(host);
        tryCompare(host, "phase", "visible");
        compare(host.recoveryRow, null);
        compare(host.inputRegion.width, Math.ceil(host.width));
    }
    function test_disconnect_unloads_view_keyboard_restart_and_escape() {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        ready(host); tryCompare(host, "phase", "visible");
        provider.connectionError("Fixture disconnected");
        tryCompare(host, "phase", "unavailable");
        compare(host.view, null);
        const button = findChild(host.recoveryRow, "terminalUnavailableRestart");
        compare(subject.keyboardHost, null);
        compare(output.grab.active, false);
        compare(subject.focusWidget(host.widget.id), "focused");
        tryVerify(() => button.activeFocus);
        compare(output.keyboardFocused, true);
        compare(output.grab.active, true);
        keyClick(Qt.Key_Escape);
        tryCompare(subject, "keyboardHost", null);
        compare(output.grab.active, false);
        const releasedGeneration = host.revealGeneration;
        keyClick(Qt.Key_Space);
        compare(host.revealGeneration, releasedGeneration);
        compare(subject.focusWidget(host.widget.id), "focused");
        tryVerify(() => button.activeFocus);
        const generation = host.revealGeneration;
        keyClick(Qt.Key_Space);
        verify(host.revealGeneration > generation);
        tryCompare(host, "phase", "preparing");
        compare(host.recoveryRow, null);
        compare(output.keyboardFocused, false);
        compare(output.grab.active, false);
        ready(host); tryCompare(host, "phase", "visible");
        tryVerify(() => host.view.activeFocus);
    }
    function test_regions_only_cover_fallback_row_and_selected_fullscreen_output() {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        unavailable(host);
        const row = host.recoveryRow;
        compare(host.inputRegion.width, 0);
        compare(host.fullscreenInputRegion.width, 0);
        compare(host.recoveryInputRegion.x, Math.floor(host.x + row.x));
        compare(host.recoveryInputRegion.y, Math.floor(host.y + row.y));
        compare(host.recoveryInputRegion.width, Math.ceil(row.width));
        compare(host.recoveryInputRegion.height, Math.ceil(row.height));
        verify(host.recoveryInputRegion.height < host.height);
        verify(host.recoveryInputRegion.y >= output.widgetBounds.y);
        compare(host.fullscreenRecoveryInputRegion.width, 0);
        // Fullscreen is entered through the existing visible-host route, then fails.
        ready(host); tryCompare(host, "phase", "visible");
        compare(subject.toggleFullscreen(host.widget.id, "DP-1"), "fullscreen");
        tryCompare(host, "outputWindow", output.raised);
        compare(subject.visibleFullscreenOutputs, ["DP-1"]);
        unavailable(host);
        compare(host.recoveryInputRegion.width, 0);
        compare(host.fullscreenRecoveryInputRegion.width, Math.ceil(host.recoveryRow.width));
        // Keep the existing readiness rule for bar coverage while retaining fullscreen selection.
        compare(subject.visibleFullscreenOutputs, []);
        compare(output.raised.keyboardFocused, true);
        const generation = host.revealGeneration;
        const button = findChild(host.recoveryRow, "terminalUnavailableRestart");
        mouseClick(button, button.width / 2, button.height / 2);
        verify(host.revealGeneration > generation);
        tryCompare(host, "phase", "preparing");
        compare(host.outputWindow, output.raised);
        compare(host.fullscreenRecoveryInputRegion.width, 0);
        compare(subject.visibleFullscreenOutputs, []);
        ready(host); tryCompare(host, "phase", "visible");
        compare(subject.visibleFullscreenOutputs, ["DP-1"]);
        compare(host.fullscreenInputRegion.width, Math.ceil(host.width));
        unavailable(host);
        keyClick(Qt.Key_Escape);
        tryCompare(host, "outputWindow", output);
        compare(subject.fullscreenWidgetId, "");
        compare(subject.keyboardHost, null);
    }
    function test_multiple_outputs_restart_only_clicked_or_keyboard_selected_copy() {
        const firstOutput = makeOutput("DP-1", 0), secondOutput = makeOutput("DP-2", 500);
        const first = makeHost(firstOutput), second = makeHost(secondOutput);
        unavailable(first); const button = unavailable(second);
        const firstGeneration = first.revealGeneration, secondGeneration = second.revealGeneration;
        compare(subject.restartTerminal(first.widget.id, "").status, "ambiguous");
        compare(subject.restartTerminal(first.widget.id, "missing").status, "unavailable");
        mouseClick(button, button.width / 2, button.height / 2);
        compare(first.revealGeneration, firstGeneration);
        verify(second.revealGeneration > secondGeneration);
        unavailable(second);
        workspaceProvider.focusedMonitor = secondOutput.outputMonitor;
        compare(subject.focusWidget(first.widget.id), "focused");
        compare(subject.keyboardHost, second);
        tryVerify(() => findChild(second.recoveryRow, "terminalUnavailableRestart").activeFocus);
        compare(firstOutput.grab.active, false);
        compare(secondOutput.grab.active, true);
        keyClick(Qt.Key_Return);
        compare(first.revealGeneration, firstGeneration);
        compare(secondOutput.grab.active, false);
    }
    function test_escape_releases_fallback_without_toggling_other_outputs_fullscreen() {
        const firstOutput = makeOutput("DP-1", 0), secondOutput = makeOutput("DP-2", 500);
        const first = makeHost(firstOutput), second = makeHost(secondOutput);
        ready(first); tryCompare(first, "phase", "visible");
        compare(subject.toggleFullscreen(first.widget.id, "DP-1"), "fullscreen");
        unavailable(second);
        workspaceProvider.focusedMonitor = secondOutput.outputMonitor;
        compare(subject.focusWidget(second.widget.id), "focused");
        tryVerify(() => findChild(second.recoveryRow, "terminalUnavailableRestart").activeFocus);
        compare(secondOutput.grab.active, true);
        const generation = second.revealGeneration;
        keyClick(Qt.Key_Escape);
        tryCompare(subject, "keyboardHost", null);
        compare(secondOutput.grab.active, false);
        compare(subject.fullscreenWidgetId, first.widget.id);
        compare(subject.fullscreenOutputName, "DP-1");
        compare(subject.visibleFullscreenOutputs, ["DP-1"]);
        compare(second.revealGeneration, generation);
    }
    function test_hide_edit_disable_and_nonterminal_cleanup_data() {
        return [{tag: "hidden"}, {tag: "editing"}, {tag: "edit-mode"}, {tag: "disabled"}, {tag: "workspace"},
            {tag: "zero-size"}];
    }
    function test_hide_edit_disable_and_nonterminal_cleanup(data) {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        const button = unavailable(host);
        compare(subject.focusWidget(host.widget.id), "focused");
        tryVerify(() => button.activeFocus);
        const subscriptions = provider.subscriptions;
        if (data.tag === "hidden") output.visible = false;
        if (data.tag === "editing") host.editing = true;
        if (data.tag === "edit-mode") subject.editMode = true;
        if (data.tag === "disabled") host.widget = Object.assign({}, host.widget, {enabled: false});
        if (data.tag === "workspace") host.widget = Object.assign({}, host.widget, {workspaces: {mode: "include", ids: [9], ranges: []}});
        if (data.tag === "zero-size") {
            host.widget = Object.assign({}, host.widget, {placement: Object.assign({}, host.widget.placement, {sizing: "content"})});
            host.placementBounds = Qt.rect(0, 0, 0, 0);
        }
        tryCompare(host, "recoveryRow", null);
        compare(host.recoveryInputRegion.width, 0);
        compare(host.fullscreenRecoveryInputRegion.width, 0);
        compare(subject.keyboardHost, null);
        compare(output.grab.active, false);
        const generation = host.revealGeneration;
        compare(subject.restartTerminal(host.widget.id, "DP-1").status, "unavailable");
        compare(subject.focusWidget(host.widget.id), "unavailable");
        keyClick(Qt.Key_Space);
        compare(host.revealGeneration, generation);
        wait(0);
        compare(provider.subscriptions, subscriptions);
    }
    function test_generation_change_cancels_pointer_press_and_deferred_focus() {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        let button = unavailable(host);
        mousePress(button, button.width / 2, button.height / 2);
        const point = button.mapToItem(test, button.width / 2, button.height / 2);
        const subscriptions = provider.subscriptions;
        provider.connectionError("New disconnect generation");
        const generation = host.revealGeneration;
        mouseRelease(test, point.x, point.y);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions, subscriptions);
        compare(subject.focusWidget(host.widget.id), "focused");
        // The focus signal queued a callback for this generation. Replacement must cancel it.
        host.refresh();
        output.focusKeyboardRenderer(host, generation);
        compare(host.recoveryRow, null);
        compare(output.keyboardFocused, false);
        compare(output.grab.active, false);
        wait(0);
        compare(host.phase, "preparing");
        keyClick(Qt.Key_Space);
        compare(host.revealGeneration, generation + 1);
        const other = makeHost(output);
        unavailable(host); unavailable(other);
        subject.keyboardHost = host; subject.keyboardWidgetId = host.widget.id;
        const queuedGeneration = host.revealGeneration;
        subject.keyboardHost = other;
        output.focusKeyboardRenderer(null, queuedGeneration);
        compare(other.recoveryRow.activeFocus, false);
        output.focusKeyboardRenderer(host, queuedGeneration);
        compare(other.recoveryRow.activeFocus, false);
        output.focusKeyboardRenderer(other, other.revealGeneration);
        tryVerify(() => findChild(other.recoveryRow, "terminalUnavailableRestart").activeFocus);
    }
    function test_nonterminal_failure_has_no_fallback_or_input() {
        const output = makeOutput("DP-1", 0), host = makeHost(output, "command");
        provider.connectionError("Fixture disconnected");
        tryCompare(host, "phase", "unavailable");
        compare(host.view, null); compare(host.recoveryRow, null);
        compare(host.recoveryInputRegion.width, 0);
        compare(subject.focusWidget(host.widget.id), "unavailable");
        compare(output.grab.active, false);
    }
    function test_nonterminal_disconnect_releases_existing_keyboard_owner() {
        const output = makeOutput("DP-1", 0), host = makeHost(output, "command");
        ready(host); tryCompare(host, "phase", "visible");
        compare(subject.focusWidget(host.widget.id), "focused");
        tryCompare(output.grab, "active", true);
        provider.connectionError("Fixture disconnected");
        tryCompare(host, "phase", "unavailable");
        compare(subject.keyboardHost, null);
        compare(subject.keyboardWidgetId, "");
        compare(host.recoveryRow, null);
        compare(output.grab.active, false);
        compare(restore.running, false);
    }
    function test_fallback_keyboard_requires_owner_and_unmodified_activation_data() {
        return [{tag: "space", key: Qt.Key_Space}, {tag: "return", key: Qt.Key_Return},
            {tag: "enter", key: Qt.Key_Enter}];
    }
    function test_fallback_keyboard_requires_owner_and_unmodified_activation(data) {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        const button = unavailable(host);
        const generation = host.revealGeneration;
        // Tab or another local focus source must not take compositor keyboard ownership.
        button.forceActiveFocus();
        keyClick(data.key);
        compare(host.revealGeneration, generation);
        compare(output.grab.active, false);
        compare(subject.focusWidget(host.widget.id), "focused");
        tryVerify(() => button.activeFocus);
        keyClick(data.key, Qt.ControlModifier);
        compare(host.revealGeneration, generation);
        keyClick(Qt.Key_Tab);
        keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        tryVerify(() => button.activeFocus);
        keyClick(data.key);
        verify(host.revealGeneration > generation);
        tryCompare(host, "phase", "preparing");
        compare(host.recoveryRow, null);
        compare(output.grab.active, false);
    }
    function test_interrupted_press_does_not_restart_replacement_row_data() {
        return [{tag: "hidden"}, {tag: "editing"}, {tag: "edit-mode"}];
    }
    function test_interrupted_press_does_not_restart_replacement_row(data) {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        const button = unavailable(host);
        const point = button.mapToItem(test, button.width / 2, button.height / 2);
        mousePress(button, button.width / 2, button.height / 2);
        if (data.tag === "hidden") output.visible = false;
        if (data.tag === "editing") host.editing = true;
        if (data.tag === "edit-mode") subject.editMode = true;
        tryCompare(host, "recoveryRow", null);
        compare(host.recoveryInputRegion.width, 0);
        if (data.tag === "hidden") {
            output.visible = true;
            tryCompare(host, "phase", "preparing");
        }
        if (data.tag === "editing") host.editing = false;
        if (data.tag === "edit-mode") subject.editMode = false;
        unavailable(host);
        const generation = host.revealGeneration, subscriptions = provider.subscriptions;
        mouseRelease(test, point.x, point.y);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions, subscriptions);
    }
    function test_fallback_escape_preserves_previous_workspace_guard_data() {
        return [{tag: "valid", restore: true}, {tag: "stale-workspace"}, {tag: "stale-output"},
            {tag: "unobserved-special"}, {tag: "moved-after-capture"}, {tag: "outside-click"}];
    }
    function test_fallback_escape_preserves_previous_workspace_guard(data) {
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        unavailable(host);
        const workspace = {id: 1, name: "1", toplevels: {values: []}};
        const other = {id: 2, name: "2", toplevels: {values: []}};
        const monitor = output.outputMonitor;
        monitor.activeWorkspace = workspace;
        monitor.lastIpcObject = {specialWorkspace: {address: data.tag === "unobserved-special" ? "unobserved" : "", name: data.tag === "unobserved-special" ? "special:notes" : "", type: data.tag === "unobserved-special" ? "special" : ""}};
        const app = {workspace: data.tag === "stale-workspace" ? other : workspace,
            monitor: data.tag === "stale-output" ? {name: "DP-2"} : monitor,
            lastIpcObject: {address: "0xa0b", pid: 42, class: "fixture-editor"}};
        workspace.toplevels.values = [app];
        workspaceProvider.workspaces = {values: [workspace, other]};
        workspaceProvider.focusedMonitor = monitor;
        workspaceProvider.activeToplevel = app;
        compare(subject.focusWidget(host.widget.id), "focused");
        tryVerify(() => findChild(host.recoveryRow, "terminalUnavailableRestart").activeFocus);
        if (data.tag === "moved-after-capture") monitor.activeWorkspace = other;
        workspaceProvider.activeToplevel = null;
        if (data.tag === "outside-click") output.grab.cleared();
        else keyClick(Qt.Key_Escape);
        tryCompare(subject, "keyboardHost", null);
        compare(output.grab.active, false);
        compare(subject.keyboardReturnAddress, "");
        compare(restore.running, data.restore === true);
        compare(restore.command.slice(-3), data.restore ? ["a0b", "42", "fixture-editor"] : []);
    }
    function test_selected_a_geometry_and_screenshot_data() {
        return [{tag: "normal", density: 1}, {tag: "dense", density: 1.5}, {tag: "compact", density: 1, compact: true}];
    }
    function test_selected_a_geometry_and_screenshot(data) {
        widgetTheme.densityScale = data.density;
        const output = makeOutput("DP-1", 0), host = makeHost(output);
        if (data.compact) host.widget = Object.assign({}, host.widget, {appearance: Object.assign({}, host.widget.appearance, {presentation: "compact"})});
        unavailable(host, "Fixture provider failure");
        const row = host.recoveryRow, button = findChild(row, "terminalUnavailableRestart");
        compare(row.height, 28 * data.density); compare(button.width, 72 * data.density);
        compare(row.x, Math.min(22, (data.compact ? 16 : 20) * data.density));
        compare(row.y, host.height - row.height - row.padding / 2);
        const status = findChild(row, "terminalUnavailableStatus");
        compare(status.textFormat, Text.PlainText); compare(status.elide, Text.ElideRight);
        compare(status.color, widgetTheme.palette.negative);
        if (screenshotPath && data.tag === "normal") {
            Qt.createQmlObject('import QtQuick; Rectangle { anchors.fill: parent; color: "#161a20"; z: -1 }', output);
            wait(30);
            let image = grabImage(output);
            compare(image.width, output.width); compare(image.height, output.height);
            image.save(screenshotPath);
            provider.connectionError("Fixture disconnected");
            compare(host.view, null);
            compare(host.error, "Fixture disconnected");
            compare(findChild(host.recoveryRow, "terminalUnavailableStatus").text, "Unavailable · Fixture disconnected");
            compare(subject.focusWidget(host.widget.id), "focused");
            tryVerify(() => findChild(host.recoveryRow, "terminalUnavailableRestart").activeFocus);
            wait(30);
            image = grabImage(output);
            compare(image.width, output.width); compare(image.height, output.height);
            image.save(screenshotPath.replace(".png", "-disconnect.png"));
        }
        host.widget = Object.assign({}, host.widget, {placement: Object.assign({}, host.widget.placement, {width: 60, height: 20})});
        unavailable(host, "Long unavailable fixture message");
        verify(host.recoveryRow.width <= host.width);
        verify(findChild(host.recoveryRow, "terminalUnavailableRestart").width <= host.recoveryRow.width);
    }
}
