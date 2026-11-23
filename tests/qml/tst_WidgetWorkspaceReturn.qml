import QtQuick
import QtTest
import "../../shell/shared/WidgetWorkArea.js" as WorkArea

TestCase {
    id: testCase
    name: "WidgetWorkspaceReturn"
    property var subject: null
    property var hostActions: []
    property int editFinishedCount: 0
    property string editFinishedPayload: ""
    property string editFinishedWorkspace: ""
    SignalSpy { id: fullscreenFocus; target: testCase.subject; signalName: "keyboardFocusRequested" }
    QtObject { id: theme; property var widgetItems: []; property int layoutRequests: 0; signal widgetLayoutEditRequested(); onWidgetLayoutEditRequested: layoutRequests++; signal widgetEditModeFinished(string payload, string returnWorkspace) }
    QtObject {
        id: workspaceProvider
        property var focusedWorkspace: null
        property var focusedMonitor: null
        property var activeToplevel: null
        property var workspaces: ({values: []})
    }
    QtObject { id: focusRestore; property bool running: false; property var command: [] }
    QtObject { id: commands; property string shellDir: "/private-fixture"; property var calls: []; function execDetached(command) { calls = calls.concat([command]); } }
    Connections {
        target: theme
        function onWidgetEditModeFinished(payload, returnWorkspace) {
            testCase.editFinishedCount++;
            testCase.editFinishedPayload = payload;
            testCase.editFinishedWorkspace = returnWorkspace;
        }
    }
    function extract(source, name) {
        const start = source.indexOf("    function " + name + "(");
        verify(start >= 0, "Missing production function " + name);
        let index = source.indexOf("{", start), depth = 1;
        while (depth && ++index < source.length) {
            if (source[index] === "{") depth++;
            if (source[index] === "}") depth--;
        }
        return source.slice(start, index + 1);
    }
    function readSource(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        return request.responseText;
    }
    function initTestCase() {
        const desktop = readSource("../../shell/modules/DesktopWidgets.qml");
        const editMode = readSource("../../shell/modules/WidgetEditMode.qml");
        const functions = ["open", "requestLayoutEdit", "cloneItems", "dispatchWorkspace", "beginEdit", "cancelEdit", "saveEdit", "leaveEditWorkspace", "replaceEditItem", "workspaceForMonitor", "workspaceSnapshot", "interactiveWidget", "dispatchHostAction", "registerHost", "unregisterHost", "actionableHost", "terminalRecoveryAvailable", "captureKeyboardReturnTarget", "focusWidget", "releaseKeyboardFocus", "releaseKeyboardFocusAfterOutsideClick", "restoreKeyboardReturnTarget", "reconcileKeyboardFocus", "toggleFullscreen"].map(name => extract(desktop, name))
            .concat(["clone", "initialX", "initialY", "geometryItem"].map(name => extract(editMode, name))).join("\n");
        subject = Qt.createQmlObject('import QtQuick; QtObject { id: root; property var themeProvider; property var workspaceProvider; property var commands; property real width: 1920; property real height: 1080; property rect widgetBounds: Qt.rect(0, 0, width, height); property string keyboardWidgetId: ""; property var keyboardHost: null; property var hosts: []; property string keyboardReturnAddress: ""; property int keyboardReturnPid: 0; property string keyboardReturnClass: ""; property var keyboardFocusRestore; signal keyboardFocusRequested(string widgetId); signal actionRequested(string widgetId, string action, var payload); property string fullscreenWidgetId: ""; property string fullscreenOutputName: ""; property bool editMode: false; property bool editWorkspaceEntered: false; property string editReturnWorkspace: ""; property var editItems: []; property var editSourceItems: []; '
            + functions.replace(/Theme\./g, "themeProvider.").replace(/Hyprland\./g, "workspaceProvider.").replace(/Quickshell\./g, "commands.") + '}', testCase, "ProductionWorkspaceFunctions");
        subject.themeProvider = theme;
        subject.workspaceProvider = workspaceProvider;
        subject.commands = commands;
        subject.keyboardFocusRestore = focusRestore;
        subject.actionRequested.connect(function(id, action, payload) { testCase.hostActions = testCase.hostActions.concat([{id:id, action:action, payload:payload}]); });
        compare(commands.calls.length, 0);
    }
    function init() {
        commands.calls = [];
        hostActions = [];
        theme.layoutRequests = 0;
        focusRestore.running = false;
        focusRestore.command = [];
        subject.keyboardHost = null;
        subject.keyboardWidgetId = "";
        subject.keyboardReturnAddress = "";
        subject.keyboardReturnPid = 0;
        subject.keyboardReturnClass = "";
        subject.fullscreenWidgetId = "";
        subject.fullscreenOutputName = "";
        subject.hosts = [];
        workspaceProvider.activeToplevel = null;
        workspaceProvider.focusedMonitor = null;
        workspaceProvider.focusedWorkspace = null;
        workspaceProvider.workspaces = {values: []};
        subject.editMode = false;
        subject.editWorkspaceEntered = false;
        subject.editReturnWorkspace = "";
        subject.editItems = [];
        subject.editSourceItems = [];
        editFinishedCount = 0;
        editFinishedPayload = "";
        editFinishedWorkspace = "";
        theme.widgetItems = [];
    }
    function item(id, enabled) {
        return {id: id, kind: "notes", name: id, enabled: enabled,
            placement: {anchor: "top-left", x: 24, y: 24, width: 200, height: 100},
            fullscreen: {enabled: true, mode: "native"},
            appearance: {backgroundOpacity: 0.6, scrollbars: "auto"}, settings: {text: "Draft"}};
    }
    function setKeyboardReturnTarget() {
        const workspace = {id: 3, name: "3", toplevels: {values: []}};
        const monitor = {name: "DP-1", activeWorkspace: workspace, lastIpcObject: {specialWorkspace: {address: "", name: "", type: ""}}};
        const toplevel = {workspace: workspace, monitor: monitor,
            lastIpcObject: {address: "0xa0b", pid: 42, class: "test-editor"}};
        workspace.toplevels.values = [toplevel];
        workspaceProvider.focusedMonitor = monitor;
        workspaceProvider.focusedWorkspace = workspace;
        workspaceProvider.workspaces = {values: [workspace]};
        workspaceProvider.activeToplevel = toplevel;
        return toplevel;
    }
    function test_direct_ipc_open_requests_settings_staging_before_desktop_edit() {
        compare(subject.open(), "requested");
        compare(theme.layoutRequests, 1);
        compare(subject.editMode, false);
        compare(subject.editItems.length, 0);
        compare(commands.calls.length, 0);
        subject.editMode = true;
        compare(subject.open(), "editing");
        compare(theme.layoutRequests, 1);
        compare(commands.calls.length, 0);
    }
    function test_named_workspace_round_trip_and_single_leave() {
        workspaceProvider.focusedWorkspace = {id: -1340, name: "blox-proof"};
        compare(subject.beginEdit(), "editing");
        compare(subject.editReturnWorkspace, "name:blox-proof");
        compare(subject.leaveEditWorkspace(), "name:blox-proof");
        compare(commands.calls.length, 2);
        verify(commands.calls[1][2].includes('workspace = "name:blox-proof"'));
        compare(subject.leaveEditWorkspace(), "");
        compare(commands.calls.length, 2);
    }
    function test_numeric_workspace_round_trip() {
        workspaceProvider.focusedWorkspace = {id: 4, name: "4"};
        subject.beginEdit();
        compare(subject.editReturnWorkspace, "4");
        compare(subject.leaveEditWorkspace(), "4");
        verify(commands.calls[1][2].includes('workspace = "4"'));
    }
    function test_special_workspace_return_keeps_its_identity() {
        workspaceProvider.focusedWorkspace = {id: -99, name: "special:notes"};
        subject.beginEdit();
        compare(subject.editReturnWorkspace, "special:notes");
        compare(subject.leaveEditWorkspace(), "special:notes");
        verify(commands.calls[1][2].includes('workspace = "special:notes"'));
    }
    function test_workspace_identity_is_escaped_in_dispatch() {
        const identity = 'name:notes "draft"';
        subject.dispatchWorkspace(identity);
        compare(commands.calls[0][2], "hl.dsp.focus({ workspace = " + JSON.stringify(identity) + " })");
    }
    function test_cancel_returns_once_and_does_not_change_live_profile() {
        workspaceProvider.focusedWorkspace = {id: -1340, name: "blox-proof"};
        theme.widgetItems = [item("live-note", true)];
        subject.beginEdit([item("candidate-note", true)]);
        compare(subject.cancelEdit(), "cancelled");
        compare(subject.cancelEdit(), "inactive");
        compare(commands.calls.length, 2);
        compare(editFinishedCount, 1);
        compare(editFinishedPayload, "");
        compare(editFinishedWorkspace, "name:blox-proof");
        compare(theme.widgetItems[0].id, "live-note");
    }
    function test_save_uses_candidate_and_preserves_disabled_items() {
        workspaceProvider.focusedWorkspace = {id: 4, name: "4"};
        theme.widgetItems = [item("live-note", true)];
        subject.beginEdit([item("candidate-note", true), item("disabled-note", false)]);
        compare(subject.editItems.length, 1);
        const moved = subject.clone(subject.editItems[0]);
        moved.placement.x = 120;
        subject.replaceEditItem(0, moved);
        const saved = JSON.parse(subject.saveEdit());
        compare(saved.length, 2);
        compare(saved[0].placement.x, 120);
        compare(saved[1].enabled, false);
        compare(theme.widgetItems[0].id, "live-note");
        compare(editFinishedCount, 1);
        compare(subject.saveEdit(), "inactive");
    }
    function test_workspace_snapshot_uses_native_membership() {
        compare(subject.workspaceSnapshot(null).empty, false);
        const workspace = {id: -99, name: "special:notes", toplevels: {values: []}};
        compare(subject.workspaceSnapshot(workspace).special, true);
        compare(subject.workspaceSnapshot(workspace).empty, true);
        workspace.toplevels.values = [{}];
        compare(subject.workspaceSnapshot(workspace).empty, false);
    }
    function test_current_empty_special_record_keeps_normal_workspace() {
        const normal = {id: 9, name: "9", toplevels: {values: []}};
        const monitor = {activeWorkspace: normal, lastIpcObject: {
            specialWorkspace: {address: "", name: "", type: ""}}};
        compare(subject.workspaceForMonitor(monitor), normal);
        compare(subject.workspaceSnapshot(subject.workspaceForMonitor(monitor)).empty, true);
    }
    function test_missing_special_name_never_reuses_normal_workspace() {
        const normal = {id: 9, name: "9"};
        const monitor = {activeWorkspace: normal, lastIpcObject: {specialWorkspace: {address: "unknown"}}};
        compare(subject.workspaceForMonitor(monitor), null);
    }
    function test_special_workspace_never_reuses_normal_workspace() {
        const normal = {id: 1, name: "1"}, special = {id: -99, name: "special:notes"};
        const monitor = {activeWorkspace: normal, lastIpcObject: {specialWorkspace: {address: "special-address", name: "special:notes", type: "special"}}};
        workspaceProvider.workspaces = {values: []};
        compare(subject.workspaceForMonitor(monitor), null);
        workspaceProvider.workspaces = {values: [normal, special]};
        compare(subject.workspaceForMonitor(monitor), special);
        monitor.lastIpcObject.specialWorkspace = {address: "", name: "", type: ""};
        compare(subject.workspaceForMonitor(monitor), normal);
    }
    function test_keyboard_focus_belongs_to_one_output_and_restores_valid_target() {
        const toplevel = setKeyboardReturnTarget();
        const monitorA = {name: "DP-2"}, monitorB = toplevel.monitor;
        const first = {widget: item("note", true), phase: "visible", visible: true, eligible: true, outputMonitor: monitorA};
        const second = {widget: item("note", true), phase: "visible", visible: true, eligible: true, outputMonitor: monitorB};
        workspaceProvider.focusedMonitor = monitorB;
        subject.hosts = [first, second];
        compare(subject.focusWidget("note"), "focused");
        compare(subject.keyboardHost, second);
        compare(subject.releaseKeyboardFocus("different-note"), "stale");
        compare(subject.keyboardHost, second);
        compare(subject.releaseKeyboardFocus("note"), "released");
        compare(subject.keyboardHost, null);
        compare(focusRestore.running, true);
        compare(focusRestore.command.slice(-3), ["a0b", "42", "test-editor"]);
        compare(commands.calls.length, 0);
    }
    function test_outside_click_releases_without_return_focus_command() {
        setKeyboardReturnTarget();
        const host = {widget: item("note", true), phase: "visible", visible: true, eligible: true, outputMonitor: null};
        subject.hosts = [host];
        compare(subject.focusWidget("note"), "focused");
        compare(subject.keyboardReturnAddress, "a0b");
        compare(subject.releaseKeyboardFocusAfterOutsideClick("note"), "released");
        compare(subject.keyboardHost, null);
        compare(subject.keyboardReturnAddress, "");
        compare(focusRestore.running, false);
        compare(commands.calls.length, 0);
    }
    function test_workspace_hide_releases_keyboard_owner() {
        setKeyboardReturnTarget();
        const host = {widget: item("note", true), phase: "visible", visible: true, eligible: true, outputMonitor: null};
        subject.hosts = [host];
        compare(subject.focusWidget("note"), "focused");
        host.eligible = false;
        host.phase = "hidden";
        subject.reconcileKeyboardFocus();
        compare(subject.keyboardHost, null);
        compare(subject.keyboardWidgetId, "");
        compare(subject.keyboardReturnAddress, "");
        compare(focusRestore.command.length, 0);
        compare(focusRestore.running, false);
    }
    function test_destroying_focused_host_drops_ownership_without_restoring_workspace() {
        setKeyboardReturnTarget();
        const host = {widget: item("note", true), phase: "visible", visible: true, eligible: true, outputMonitor: null, outputName: "DP-1"};
        subject.registerHost(host);
        compare(subject.focusWidget("note"), "focused");
        subject.unregisterHost(host);
        compare(subject.hosts.length, 0);
        compare(subject.keyboardHost, null);
        compare(subject.keyboardReturnAddress, "");
        compare(focusRestore.command.length, 0);
        compare(focusRestore.running, false);
    }
    function test_fullscreen_return_target_data() {
        return [
            {tag: "empty-workspace-9-retains-workspace-3-app", staleWorkspace: true, restore: false},
            {tag: "current-workspace-app", restore: true},
            {tag: "named-workspace-app", named: true, restore: true},
            {tag: "other-output-app", otherOutput: true, restore: false},
            {tag: "empty-special-retains-normal-app", special: true, staleWorkspace: true, restore: false},
            {tag: "current-special-app", special: true, restore: true},
            {tag: "unobserved-special-retains-normal-app", special: true, unobserved: true, restore: false},
            {tag: "no-focused-monitor", noMonitor: true, restore: false},
            {tag: "no-workspace", noWorkspace: true, restore: false},
            {tag: "no-app", noApp: true, restore: false}
        ];
    }
    function test_fullscreen_return_target(data) {
        const toplevel = setKeyboardReturnTarget();
        const previous = toplevel.workspace, monitor = toplevel.monitor;
        const current = {id: data.special ? -99 : data.named ? -1340 : 9,
            name: data.special ? "special:notes" : data.named ? "notes" : "9", toplevels: {values: []}};
        monitor.activeWorkspace = data.special ? previous : current;
        monitor.lastIpcObject.specialWorkspace = {address: data.special ? "special-address" : "", name: data.special ? current.name : "", type: data.special ? "special" : ""};
        workspaceProvider.focusedWorkspace = monitor.activeWorkspace;
        workspaceProvider.workspaces = {values: data.unobserved ? [previous] : [previous, current]};
        if (!data.staleWorkspace && !data.unobserved) {
            previous.toplevels.values = [];
            current.toplevels.values = [toplevel];
            toplevel.workspace = current;
        }
        if (data.otherOutput) toplevel.monitor = {name: "DP-2", activeWorkspace: current};
        if (data.noMonitor) workspaceProvider.focusedMonitor = null;
        if (data.noWorkspace) monitor.activeWorkspace = null;
        if (data.noApp) workspaceProvider.activeToplevel = null;
        // Invalid captures must also discard any target retained from an earlier session.
        subject.keyboardReturnAddress = "beef";
        subject.keyboardReturnPid = 7;
        subject.keyboardReturnClass = "old-app";
        subject.hosts = [{widget: item("note", true), phase: "visible", visible: true,
            eligible: true, outputName: "DP-1", outputMonitor: monitor}];
        compare(subject.toggleFullscreen("note", "DP-1"), "fullscreen");
        compare(subject.keyboardReturnAddress, data.restore ? "a0b" : "");
        compare(subject.keyboardReturnPid, data.restore ? 42 : 0);
        compare(subject.keyboardReturnClass, data.restore ? "test-editor" : "");
        // The layer can own focus on dismissal without losing the genuine previous app.
        workspaceProvider.activeToplevel = null;
        compare(subject.toggleFullscreen("note", "DP-1"), "normal");
        compare(subject.keyboardHost, null);
        compare(focusRestore.running, data.restore);
        compare(focusRestore.command, data.restore
            ? ["python3", "/private-fixture/scripts/launcher/restore_focus.py", "a0b", "42", "test-editor"] : []);
        compare(commands.calls.length, 0);
    }
    function test_return_target_leaves_focused_workspace_data() {
        return [{tag: "app-moved-workspace"}, {tag: "app-moved-output", output: true},
            {tag: "focused-workspace-changed", focus: true}];
    }
    function test_return_target_leaves_focused_workspace(data) {
        const toplevel = setKeyboardReturnTarget();
        subject.captureKeyboardReturnTarget();
        compare(subject.keyboardReturnAddress, "a0b");
        const other = {id: 9, name: "9", toplevels: {values: []}};
        if (data.output) toplevel.monitor = {name: "DP-2", activeWorkspace: toplevel.workspace};
        else if (data.focus) toplevel.monitor.activeWorkspace = other;
        else {
            toplevel.workspace.toplevels.values = [];
            toplevel.workspace = other;
            other.toplevels.values = [toplevel];
        }
        compare(subject.restoreKeyboardReturnTarget(), false);
        compare(subject.keyboardReturnAddress, "");
        compare(focusRestore.running, false);
        compare(focusRestore.command, []);
    }
    function test_notes_and_calendar_actions_reach_application_without_running_commands() {
        const note = {widget: {id: "note", kind: "notes"}, phase: "visible", visible: true};
        const calendar = {widget: {id: "calendar", kind: "calendar"}, phase: "visible", visible: true};
        compare(subject.dispatchHostAction(note, "edit", {}), true);
        compare(subject.dispatchHostAction(calendar, "open", {}), true);
        compare(hostActions.map(entry => entry.action), ["edit", "open"]);
        note.phase = "hidden";
        compare(subject.dispatchHostAction(note, "edit", {}), false);
        subject.editMode = true;
        compare(subject.dispatchHostAction(calendar, "open", {}), false);
        compare(hostActions.length, 2);
        compare(commands.calls.length, 0);
        compare(focusRestore.running, false);
    }
    function test_fullscreen_is_explicit_and_keeps_placement() {
        fullscreenFocus.clear();
        const widget = item("note", true);
        const host = {widget: widget, phase: "visible", visible: true, eligible: true, outputName: "DP-1", outputMonitor: null};
        subject.hosts = [host];
        compare(subject.fullscreenWidgetId, "");
        compare(subject.toggleFullscreen("note", "DP-1"), "fullscreen");
        compare(subject.fullscreenWidgetId, "note");
        compare(subject.fullscreenOutputName, "DP-1");
        compare(subject.keyboardHost, host);
        compare(fullscreenFocus.count, 1);
        compare(fullscreenFocus.signalArguments[0][0], "note");
        compare(widget.placement.width, 200);
        compare(subject.toggleFullscreen("note", "DP-1"), "normal");
        compare(subject.keyboardHost, null);
        compare(widget.placement.width, 200);
        widget.fullscreen.enabled = false;
        compare(subject.toggleFullscreen("note", "DP-1"), "unavailable");
    }
    function test_reserved_work_area_anchor_round_trip() {
        subject.widgetBounds = Qt.rect(34, 18, 1866, 1032);
        for (const anchor of ["top-left", "top-right", "bottom-left", "bottom-right", "centre"]) {
            const original = item("note", true);
            original.placement.anchor = anchor;
            const x = subject.initialX(original, 200);
            const y = subject.initialY(original, 100);
            const moved = subject.geometryItem(original, x, y, 200, 100);
            compare(subject.initialX(moved, 200), x);
            compare(subject.initialY(moved, 100), y);
        }
        subject.widgetBounds = Qt.rect(0, 0, subject.width, subject.height);
    }

    function test_work_area_uses_all_edges_and_clamps_invalid_reservations() {
        compare(WorkArea.bounds(1920, 1080, [34, 18, 20, 30]), Qt.rect(34, 18, 1866, 1032));
        compare(WorkArea.bounds(960, 540, null), Qt.rect(0, 0, 960, 540));
        compare(WorkArea.bounds(960, 540, [-20, NaN, 2000, 600]), Qt.rect(0, 0, 0, 0));
    }

    function test_widgets_follow_shown_hidden_and_hover_revealed_bar_on_each_edge() {
        const reservations = [34, 34, 34, 34];
        const expected = [Qt.rect(51, 34, 1835, 1012), Qt.rect(34, 51, 1852, 995),
            Qt.rect(34, 34, 1835, 1012), Qt.rect(34, 34, 1852, 995)];
        const positions = ["left", "top", "right", "bottom"];
        for (let i = 0; i < positions.length; ++i) {
            compare(WorkArea.bounds(1920, 1080, reservations, {position: positions[i], extent: 17}), expected[i]);
            const shown = WorkArea.bounds(1920, 1080, [0, 0, 0, 0], {position: positions[i], extent: 34});
            const hidden = WorkArea.bounds(1920, 1080, [0, 0, 0, 0], {position: positions[i], extent: 0});
            compare(i % 2 === 0 ? shown.width : shown.height, i % 2 === 0 ? 1886 : 1046);
            compare(hidden, Qt.rect(0, 0, 1920, 1080));
        }
    }

    function test_invalid_or_missing_owned_observations_do_not_guess_contribution() {
        const own = {position: "left", extent: 34};
        compare(WorkArea.externalReservations([{name: "DP-1", reserved: [24, 0, 0, 0]}], ["DP-1"], own), null);
        compare(WorkArea.externalReservations([{name: "DP-1", reserved: [58, 0, 0, NaN]}], ["DP-1"], own), null);
        compare(WorkArea.externalReservations([], ["DP-1"], own), null);
        compare(WorkArea.externalReservations([{name: "DP-1", reserved: [58, 4, 5, 6]}], ["DP-1"], own), {"DP-1": [24, 4, 5, 6]});
    }

    function test_geometry_changes_only_placement() {
        const original = item("note", true);
        const moved = subject.geometryItem(original, 1700, 24, 200, 100);
        compare(moved.placement.anchor, "top-right");
        compare(moved.placement.x, 20);
        compare(moved.placement.y, 24);
        compare(moved.appearance.backgroundOpacity, 0.6);
        compare(original.placement.anchor, "top-left");
        compare(subject.initialX(moved, 200), 1700);
        compare(subject.initialY(moved, 100), 24);
    }
}
