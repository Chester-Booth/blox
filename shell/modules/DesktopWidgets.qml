import qs.shared
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0 as Providers
import "../shared/WidgetWorkArea.js" as WidgetWorkArea

// The shell owns windows and focus. The SDK owns widget eligibility and rendering.
Scope {
    id: root

    property bool editMode: false
    property var occupiedBar: null
    property var externalReservationsByOutput: ({})
    property bool editWorkspaceEntered: false
    property string editReturnWorkspace: ""
    property var editItems: []
    property var editSourceItems: []
    property string keyboardWidgetId: ""
    property var keyboardHost: null
    property string keyboardReturnAddress: ""
    property int keyboardReturnPid: 0
    property string keyboardReturnClass: ""
    property var hosts: []
    property string fullscreenWidgetId: ""
    property string fullscreenOutputName: ""
    property int workspaceRevision: 0
    readonly property var visibleFullscreenOutputs: root.hosts.filter(host => host.fullscreenVisible).map(host => host.outputName)
    readonly property var activeItems: Theme.widgetItems.filter(item => item.enabled === true)
    WidgetItemModel { id: widgetModel; items: root.activeItems }

    signal keyboardFocusRequested(string widgetId)
    // The application dispatches view actions. Providers handle music and terminals.
    signal actionRequested(string widgetId, string action, var payload)
    signal applicationActionRequested(string action, var identity, var trustedContext)
    signal applicationWorkflowReady(var identity)
    signal applicationWorkflowCancelled(var identity)

    // Terminal diagnostics contain counts and lifecycle state, never cell text or command paths.
    function terminalSnapshotMetadata(snapshot) {
        const frame = snapshot && snapshot.value ? snapshot.value : {};
        const number = value => typeof value === "number" && Number.isFinite(value) ? value : null;
        return {columns: number(frame.columns), rowCount: number(frame.rowCount), sequence: number(frame.sequence),
            bytesObserved: number(frame.bytesObserved), revision: number(snapshot ? snapshot.revision : null), nonblankCells: number(frame.nonblankCells), exitCode: number(frame.exitCode),
            readiness: frame.readiness === "partial" || frame.readiness === "settled" ? frame.readiness : null,
            stopReason: !frame.stopReason ? null : frame.stopReason === "runtime-limit" ? "runtime-limit" : "other"};
    }

    // Expose progress for acceptance checks without returning widget content.
    function snapshotMetadata(snapshot) {
        const number = value => typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
        const counter = value => number(value) !== null && Number.isSafeInteger(value) ? value : null;
        return {generation: counter(snapshot ? snapshot.generation : null),
            revision: counter(snapshot ? snapshot.revision : null),
            observedMonotonicMs: number(snapshot ? snapshot.observedMonotonicMs : null),
            state: snapshot && ["preparing", "ready", "unavailable"].indexOf(snapshot.state) >= 0 ? snapshot.state : null};
    }

    function cloneItems(items) { return JSON.parse(JSON.stringify(items || [])); }

    function workspaceForMonitor(monitor) {
        if (!monitor) return null;
        const special = (monitor.lastIpcObject || {}).specialWorkspace;
        if (special && typeof special.name !== "string") return null;
        if (special && special.name.length > 0) {
            const found = Hyprland.workspaces.values.find(workspace => workspace.name === special.name);
            if (found) return found;
            // An unobserved special workspace must not display the normal workspace's frame.
            return null;
        }
        return monitor.activeWorkspace;
    }

    function workspaceSnapshot(workspace) {
        if (!workspace) return {id: null, name: "", special: false, empty: false};
        const toplevels = workspace.toplevels && workspace.toplevels.values ? workspace.toplevels.values : [];
        const ipcWindows = workspace.lastIpcObject && typeof workspace.lastIpcObject.windows === "number"
            ? workspace.lastIpcObject.windows : 0;
        return {id: workspace.id, name: workspace.name,
            special: String(workspace.name).startsWith("special:"),
            empty: toplevels.length === 0 && ipcWindows === 0};
    }

    function interactiveWidget(widget) {
        return widget && ((widget.fullscreen && widget.fullscreen.enabled)
            || ["music", "system", "network", "calendar", "notes", "files", "shortcuts", "terminal", "command", "qml"].indexOf(widget.kind) >= 0);
    }
    function dispatchHostAction(host, action, payload) {
        if (!host || host.phase !== "visible" || !host.visible || editMode) return false;
        if (action === "fullscreen") return toggleFullscreen(host.widget.id, host.outputName) !== "unavailable";
        if (["files", "shortcuts", "notes", "calendar", "qml"].indexOf(host.widget.kind) < 0) return false;
        actionRequested(host.widget.id, action, payload);
        return true;
    }

    // Resolve the exact originating copy, including output and reveal generation.
    function validateCommandHost(identity, context) {
        if (editMode || !identity || !context || !context.workspace) return false;
        const matches = hosts.filter(host => host.consumerId === identity.consumerId);
        if (matches.length !== 1) return false;
        const host = matches[0];
        return host.widget && host.widget.kind === "command" && host.widget.enabled === true
            && host.visible && host.eligible && !host.editing && host.phase === "visible"
            && context.outputName === host.outputName && context.workspace.id === host.workspace.id
            && context.workspace.name === host.workspace.name && context.workspace.special === host.workspace.special
            && typeof host.isCurrentAction === "function" && host.isCurrentAction(identity, context);
    }
    function dispatchApplicationAction(host, action, identity, context) {
        if (!host || hosts.indexOf(host) < 0 || !identity || identity.consumerId !== host.consumerId
                || action !== "activate" || !validateCommandHost(identity, context)) return false;
        applicationActionRequested(action, identity, context);
        return true;
    }
    function beginCommandWorkflow(identity, context) {
        if (!validateCommandHost(identity, context)) return false;
        const host = hosts.find(item => item.consumerId === identity.consumerId);
        return host.beginApplicationWorkflow(identity, context);
    }
    function finishCommandWorkflow(identity) {
        const host = hosts.find(item => item.consumerId === identity.consumerId);
        return host ? host.finishApplicationWorkflow(identity) : false;
    }

    function releaseHostKeyboardFocus(host) {
        if (!host || keyboardHost !== host || keyboardWidgetId !== host.widget.id) return "stale";
        return releaseKeyboardFocus(host.widget.id);
    }

    function registerHost(host) { hosts = hosts.concat([host]); }
    function unregisterHost(host) {
        if (fullscreenWidgetId === host.widget.id && fullscreenOutputName === host.outputName) { fullscreenWidgetId = ""; fullscreenOutputName = ""; }
        if (keyboardHost === host) releaseKeyboardFocus(keyboardWidgetId, false);
        hosts = hosts.filter(item => item !== host);
    }
    function actionableHost(widgetId) {
        const matches = hosts.filter(host => host.widget.id === widgetId
            && (host.phase === "visible" && host.visible && interactiveWidget(host.widget) || terminalRecoveryAvailable(host)));
        return matches.find(host => host.outputMonitor === Hyprland.focusedMonitor) || matches[0] || null;
    }
    function terminalRecoveryAvailable(host) {
        return !!host && !!host.widget && host.widget.kind === "terminal" && host.widget.enabled === true
            && host.phase === "unavailable" && host.eligible && host.visible && !host.editing && !editMode
            && host.width > 0 && host.height > 0;
    }
    // Recovery must also reach eligible hosts which have not produced a view.
    function restartTerminal(widgetId, outputName) {
        if (editMode) return {status: "unavailable"};
        const matches = hosts.filter(host => host.widget && host.widget.id === widgetId
            && host.widget.kind === "terminal" && host.widget.enabled === true
            && host.eligible && host.visible && !host.editing
            && (!outputName || host.outputName === outputName));
        if (matches.length !== 1) return {status: matches.length > 1 ? "ambiguous" : "unavailable"};
        const host = matches[0];
        host.refresh();
        return {status: "restarted", widgetId: widgetId, output: host.outputName};
    }

    function toggleFullscreen(widgetId, outputName) {
        if (fullscreenWidgetId === widgetId && (!outputName || fullscreenOutputName === outputName)) {
            fullscreenWidgetId = ""; fullscreenOutputName = "";
            releaseKeyboardFocus(widgetId);
            return "normal";
        }
        const matches = hosts.filter(item => item.widget.id === widgetId && item.phase === "visible" && item.visible);
        const host = outputName ? matches.find(item => item.outputName === outputName) : matches.find(item => item.outputMonitor === Hyprland.focusedMonitor) || matches[0];
        if (!host || !host.widget.fullscreen.enabled || editMode) return "unavailable";
        if (!keyboardHost) captureKeyboardReturnTarget();
        keyboardWidgetId = widgetId;
        keyboardHost = host;
        fullscreenWidgetId = widgetId;
        fullscreenOutputName = host.outputName;
        keyboardFocusRequested(widgetId);
        return "fullscreen";
    }

    function captureKeyboardReturnTarget() {
        keyboardReturnAddress = ""; keyboardReturnPid = 0; keyboardReturnClass = "";
        const monitor = Hyprland.focusedMonitor;
        const workspace = workspaceForMonitor(monitor);
        const toplevel = Hyprland.activeToplevel;
        // Layer focus can retain a toplevel from a workspace or output we have left.
        if (!workspace || !toplevel || toplevel.workspace !== workspace || toplevel.monitor !== monitor) return;
        const state = toplevel.lastIpcObject || {};
        const address = String(state.address || "").toLowerCase().replace(/^0x/, "");
        const pid = Math.floor(Number(state.pid || 0));
        keyboardReturnAddress = /^[0-9a-f]+$/.test(address) ? address : "";
        keyboardReturnPid = Number.isFinite(pid) && pid > 0 ? pid : 0;
        keyboardReturnClass = String(state.class || "");
    }
    function focusWidget(widgetId) {
        if (editMode) return "unavailable";
        if (keyboardFocusRestore.running) return "busy";
        const host = actionableHost(widgetId);
        if (!host) return "unavailable";
        if (!keyboardHost) captureKeyboardReturnTarget();
        keyboardWidgetId = widgetId;
        keyboardHost = host;
        keyboardFocusRequested(widgetId);
        return "focused";
    }
    function restoreKeyboardReturnTarget() {
        const address = keyboardReturnAddress, pid = keyboardReturnPid, windowClass = keyboardReturnClass;
        keyboardReturnAddress = ""; keyboardReturnPid = 0; keyboardReturnClass = "";
        if (!/^[0-9a-f]+$/.test(address) || pid <= 0 || !windowClass || keyboardFocusRestore.running) return false;
        const monitor = Hyprland.focusedMonitor;
        const workspace = workspaceForMonitor(monitor);
        // A captured app may have moved while the widget held keyboard focus.
        if (!workspace || !workspace.toplevels.values.some(toplevel => toplevel.monitor === monitor
                && toplevel.workspace === workspace
                && String((toplevel.lastIpcObject || {}).address || "").toLowerCase().replace(/^0x/, "") === address)) return false;
        keyboardFocusRestore.command = ["python3", Quickshell.shellDir + "/scripts/launcher/restore_focus.py", address, String(pid), windowClass];
        keyboardFocusRestore.running = true;
        return true;
    }
    function releaseKeyboardFocus(widgetId, restorePrevious) {
        if (!widgetId || keyboardWidgetId !== widgetId) return "stale";
        keyboardWidgetId = "";
        keyboardHost = null;
        if (restorePrevious === false) {
            keyboardReturnAddress = ""; keyboardReturnPid = 0; keyboardReturnClass = "";
        } else restoreKeyboardReturnTarget();
        return "released";
    }
    function releaseKeyboardFocusAfterOutsideClick(widgetId) {
        return releaseKeyboardFocus(widgetId, false);
    }
    function reconcileKeyboardFocus() {
        if (keyboardHost && (editMode || keyboardHost.editing || !keyboardHost.eligible || !keyboardHost.visible))
            releaseKeyboardFocus(keyboardWidgetId, false);
    }
    onEditModeChanged: reconcileKeyboardFocus()

    // Workspace dispatch runs only after an explicit edit command or edit dismissal.
    function dispatchWorkspace(identity) {
        Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = " + JSON.stringify(identity) + " })"]);
    }
    function requestLayoutEdit() {
        if (editMode) return "editing";
        Theme.widgetLayoutEditRequested();
        return "requested";
    }
    function beginEdit(widgets) {
        if (editMode) return "editing";
        if (keyboardWidgetId) releaseKeyboardFocus(keyboardWidgetId, false);
        fullscreenWidgetId = ""; fullscreenOutputName = "";
        editSourceItems = cloneItems(Array.isArray(widgets) ? widgets : Theme.widgetItems);
        editItems = cloneItems(editSourceItems.filter(item => item.enabled));
        const workspace = Hyprland.focusedWorkspace;
        editReturnWorkspace = workspace ? (String(workspace.name).startsWith("special:") ? workspace.name : workspace.id > 0 ? String(workspace.id) : "name:" + workspace.name) : "";
        editMode = true;
        editWorkspaceEntered = true;
        dispatchWorkspace("name:blox-widget-edit");
        return "editing";
    }
    function leaveEditWorkspace() {
        if (!editWorkspaceEntered) return "";
        const returnWorkspace = editReturnWorkspace;
        editWorkspaceEntered = false;
        editReturnWorkspace = "";
        dispatchWorkspace(returnWorkspace || "previous");
        return returnWorkspace;
    }
    function cancelEdit() {
        if (!editMode) return "inactive";
        editMode = false;
        editItems = []; editSourceItems = [];
        const returnWorkspace = leaveEditWorkspace();
        Theme.widgetEditModeFinished("", returnWorkspace);
        return "cancelled";
    }
    function saveEdit() {
        if (!editMode) return "inactive";
        const edited = {};
        editItems.forEach(item => edited[item.id] = item);
        const payload = JSON.stringify(editSourceItems.map(item => edited[item.id] || item));
        editMode = false;
        editItems = []; editSourceItems = [];
        const returnWorkspace = leaveEditWorkspace();
        Theme.widgetEditModeFinished(payload, returnWorkspace);
        return payload;
    }
    function replaceEditItem(index, item) {
        if (index < 0 || index >= editItems.length) return;
        const next = editItems.slice(); next[index] = item; editItems = next;
    }

    Widgets.WidgetTheme {
        id: sharedWidgetTheme
        iconRoot: Qt.resolvedUrl("../assets/phosphor/")
        palette: ({background: Theme.background, foreground: Theme.foreground, muted: Theme.muted,
            accent: Theme.accent, secondary: Theme.mauve, border: Theme.border,
            positive: Theme.green, warning: Theme.yellow, negative: Theme.red})
        fontFamily: Theme.bodyFontFamily
        monospaceFamily: Theme.monoFontFamily
        radiusScale: Theme.radiusScale
        densityScale: Theme.densityScale
    }
    Providers.NativeProvider {
        id: nativeProvider
        enabled: true
        enableNativeMusic: true
        brokerCommand: ["python3", "-m", "blox_widgets.broker"]
        brokerEnvironment: ({PYTHONPATH: Quickshell.env("BLOX_WIDGETS_ROOT") + "/lib"})
    }
    Process { id: keyboardFocusRestore; objectName: "desktop-widget-focus-restore" }
    Component.onCompleted: {
        Hyprland.refreshToplevels();
        Hyprland.refreshWorkspaces();
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (["openwindow", "closewindow", "movewindow", "movewindowv2", "workspace", "workspacev2",
                    "activespecial", "focusedmon", "createworkspace", "destroyworkspace"].indexOf(event.name) < 0)
                return;
            Hyprland.refreshToplevels();
            Hyprland.refreshWorkspaces();
            root.workspaceRevision++;
        }
    }
    Connections {
        target: Hyprland.toplevels
        function onValuesChanged() { root.workspaceRevision++; }
        function onObjectInsertedPost() { root.workspaceRevision++; }
        function onObjectRemovedPost() { root.workspaceRevision++; }
    }
    Connections {
        target: Theme
        function onWidgetItemsChanged() { root.reconcileKeyboardFocus(); }
        function onWidgetEditModeRequested(widgets) { root.beginEdit(widgets); }
        function onWidgetEditModeCancelRequested() { root.cancelEdit(); }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: outputSurface
            required property var modelData
            readonly property var outputMonitor: Hyprland.monitorFor(screen)
            readonly property var externalReservations: root.externalReservationsByOutput[modelData.name]
            readonly property bool workAreaReady: Theme.ready && !!externalReservations
            readonly property rect widgetBounds: WidgetWorkArea.bounds(width, height,
                externalReservations, root.occupiedBar)
            readonly property var workspaceObject: {
                void root.workspaceRevision;
                return root.workspaceForMonitor(outputMonitor);
            }
            readonly property var workspaceState: {
                void root.workspaceRevision;
                return root.workspaceSnapshot(workspaceObject);
            }
            Connections {
                target: outputSurface.workspaceObject ? outputSurface.workspaceObject.toplevels : null
                function onValuesChanged() { root.workspaceRevision++; }
                function onObjectInsertedPost() { root.workspaceRevision++; }
                function onObjectRemovedPost() { root.workspaceRevision++; }
            }
            readonly property bool keyboardFocused: !!root.keyboardHost && root.keyboardHost.outputWindow === outputSurface
                && (root.keyboardHost.phase === "visible" || root.terminalRecoveryAvailable(root.keyboardHost))
            screen: modelData
            anchors { left: true; right: true; top: true; bottom: true }
            visible: workAreaReady && !root.editMode && root.activeItems.length > 0 && workspaceObject !== null
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            focusable: keyboardFocused
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "blox-widgets-" + modelData.name
            WlrLayershell.keyboardFocus: keyboardFocused ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

            // Region defaults to an empty mask. Each visible interactive host adds its bounds.
            mask: Region { id: inputMask }
            function removeRegion(region) {
                const index = inputMask.regions.indexOf(region);
                if (index >= 0) inputMask.regions.splice(index, 1);
            }
            function focusKeyboardRenderer(expectedHost, generation) {
                const host = root.keyboardHost;
                if (!host || host !== expectedHost || host.revealGeneration !== generation
                        || host.outputName !== screen.name || !host.eligible || !host.visible || host.editing || root.editMode) return;
                const target = root.terminalRecoveryAvailable(host) ? host.recoveryRow : host.phase === "visible" ? host.view : null;
                if (!target) return;
                const window = host.Window.window;
                if (window) window.requestActivate();
                target.forceActiveFocus();
            }

            // Map fullscreen separately so only the selected widget rises above the bar.
            // Reparent its existing host to keep the view and provider subscription alive.
            PanelWindow {
                id: fullscreenSurface
                readonly property bool keyboardFocused: !!root.keyboardHost && root.keyboardHost.outputWindow === fullscreenSurface
                    && (root.keyboardHost.phase === "visible" || root.terminalRecoveryAvailable(root.keyboardHost))
                screen: outputSurface.screen
                anchors { left: true; right: true; top: true; bottom: true }
                visible: outputSurface.visible && root.fullscreenOutputName === outputSurface.screen.name && root.fullscreenWidgetId !== ""
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                focusable: keyboardFocused
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "blox-widgets-fullscreen-" + screen.name
                WlrLayershell.keyboardFocus: keyboardFocused ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
                mask: Region { id: fullscreenInputMask }
                Shortcut {
                    sequence: "Escape"
                    enabled: fullscreenSurface.keyboardFocused
                    onActivated: root.toggleFullscreen(root.fullscreenWidgetId, fullscreenSurface.screen.name)
                }
            }
            Repeater {
                model: widgetModel
                Widgets.WidgetHost {
                    id: host
                    required property string document
                    // An invisible destination would cancel WidgetHost eligibility during the move.
                    readonly property var outputWindow: effectiveFullscreen && fullscreenSurface.contentItem.visible ? fullscreenSurface : outputSurface
                    readonly property string outputName: outputSurface.screen.name
                    readonly property var outputMonitor: outputSurface.outputMonitor
                    readonly property bool fullscreenVisible: effectiveFullscreen && outputWindow === fullscreenSurface && fullscreenSurface.visible && visible && eligible && phase === "visible"
                    readonly property Item recoveryRow: unavailableRecovery.item
                    property Region recoveryInputRegion: Region {
                        x: Math.floor(host.x + (host.recoveryRow ? host.recoveryRow.x : 0))
                        y: Math.floor(host.y + (host.recoveryRow ? host.recoveryRow.y : 0))
                        width: host.outputWindow === outputSurface && root.terminalRecoveryAvailable(host) && host.recoveryRow ? Math.ceil(host.recoveryRow.width) : 0
                        height: host.outputWindow === outputSurface && root.terminalRecoveryAvailable(host) && host.recoveryRow ? Math.ceil(host.recoveryRow.height) : 0
                    }
                    property Region fullscreenRecoveryInputRegion: Region {
                        x: host.recoveryInputRegion.x
                        y: host.recoveryInputRegion.y
                        width: host.outputWindow === fullscreenSurface && root.terminalRecoveryAvailable(host) && host.recoveryRow ? Math.ceil(host.recoveryRow.width) : 0
                        height: host.outputWindow === fullscreenSurface && root.terminalRecoveryAvailable(host) && host.recoveryRow ? Math.ceil(host.recoveryRow.height) : 0
                    }
                    property Region inputRegion: Region {
                        x: Math.floor(host.x)
                        y: Math.floor(host.y)
                        width: host.outputWindow === outputSurface && host.phase === "visible" && host.visible && root.interactiveWidget(host.widget) ? Math.ceil(host.width) : 0
                        height: host.outputWindow === outputSurface && host.phase === "visible" && host.visible && root.interactiveWidget(host.widget) ? Math.ceil(host.height) : 0
                    }
                    property Region fullscreenInputRegion: Region {
                        x: Math.floor(host.x)
                        y: Math.floor(host.y)
                        width: host.outputWindow === fullscreenSurface && host.phase === "visible" && host.visible ? Math.ceil(host.width) : 0
                        height: host.outputWindow === fullscreenSurface && host.phase === "visible" && host.visible ? Math.ceil(host.height) : 0
                    }
                    parent: outputWindow.contentItem
                    widget: JSON.parse(document)
                    theme: sharedWidgetTheme
                    provider: nativeProvider
                    qmlRegistry: Theme.widgetRegistry
                    workspace: outputSurface.workspaceState
                    trustedLaunchContext: ({outputName: host.outputName, workspace: {
                        id: outputSurface.workspaceState.id, name: outputSurface.workspaceState.name,
                        special: outputSurface.workspaceState.special}})
                    placementBounds: outputSurface.widgetBounds
                    fullscreenBounds: Qt.rect(0, 0, outputSurface.width, outputSurface.height)
                    fullscreen: root.fullscreenWidgetId === widget.id && root.fullscreenOutputName === outputName
                    z: effectiveFullscreen ? 1 : 0
                    visible: outputSurface.visible
                    onOutputWindowChanged: {
                        if (root.keyboardHost === host) Qt.callLater(outputSurface.focusKeyboardRenderer, host, host.revealGeneration);
                    }
                    onPhaseChanged: {
                        if (root.keyboardHost === host && (host.phase === "visible" || root.terminalRecoveryAvailable(host))) outputSurface.focusKeyboardRenderer(host, host.revealGeneration);
                        else if (root.keyboardHost === host && host.phase === "unavailable") root.releaseKeyboardFocus(host.widget.id, false);
                        else if (host.phase === "hidden" && !host.eligible) root.reconcileKeyboardFocus();
                    }
                    onVisibleChanged: root.reconcileKeyboardFocus()
                    onEligibleChanged: root.reconcileKeyboardFocus()
                    onEditingChanged: root.reconcileKeyboardFocus()
                    onRevealGenerationChanged: {
                        // Cancel an in-flight press even if another disconnect leaves the phase unchanged.
                        unavailableRecovery.sourceComponent = null;
                        unavailableRecovery.sourceComponent = unavailableRecoveryRow;
                    }
                    onActionRequested: (action, payload) => root.dispatchHostAction(host, action, payload)
                    onApplicationActionRequested: (action, identity, context) => root.dispatchApplicationAction(host, action, identity, context)
                    onApplicationWorkflowReady: identity => root.applicationWorkflowReady(identity)
                    onApplicationWorkflowCancelled: identity => root.applicationWorkflowCancelled(identity)
                    onFocusReleaseRequested: root.releaseHostKeyboardFocus(host)
                    // WidgetHost hides or unloads its own view on failure. This loader survives both.
                    Loader {
                        id: unavailableRecovery
                        active: root.terminalRecoveryAvailable(host)
                        sourceComponent: unavailableRecoveryRow
                        onLoaded: {
                            if (root.keyboardHost === host) Qt.callLater(outputSurface.focusKeyboardRenderer, host, host.revealGeneration);
                        }
                    }
                    Component {
                        id: unavailableRecoveryRow
                        FocusScope {
                            id: row
                            objectName: "terminalUnavailableRow"
                            readonly property real density: host.theme.densityScale
                            readonly property real padding: Math.min(host.width / 10, host.height / 10,
                                (host.effectiveFullscreen ? 40 : host.widget.appearance.presentation === "compact" ? 16 : 20) * density)
                            property int generation: -1
                            Component.onCompleted: generation = host.revealGeneration
                            Keys.onPressed: event => {
                                if (event.modifiers !== Qt.NoModifier || [Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter].indexOf(event.key) < 0) return;
                                event.accepted = true;
                                if (!event.isAutoRepeat && root.keyboardHost === host && restart.enabled) restart.clicked();
                            }
                            x: padding
                            y: Math.max(0, host.height - height - padding / 2)
                            width: Math.max(0, host.width - 2 * padding)
                            height: Math.min(28 * density, Math.max(0, host.height - padding / 2))
                            clip: true
                            Text {
                                objectName: "terminalUnavailableStatus"
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(0, parent.width - restart.width - 6 * row.density)
                                height: Math.min(implicitHeight, parent.height)
                                text: "Unavailable" + (host.error ? " · " + host.error : "")
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: host.theme.palette.negative
                                font.family: host.theme.fontFamily
                                font.pixelSize: 12
                            }
                            BloxButton {
                                id: restart
                                objectName: "terminalUnavailableRestart"
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(72 * row.density, parent.width)
                                height: parent.height
                                Accessible.name: "Restart terminal"
                                focus: true
                                enabled: root.terminalRecoveryAvailable(host) && row.generation === host.revealGeneration
                                accent: host.theme.palette.accent
                                color: down ? Theme.withAlpha(accent, 0.23) : hovered ? Theme.withAlpha(accent, 0.12) : "transparent"
                                radius: Theme.scaledRadius(5)
                                border.width: activeFocus ? 1 : 0
                                border.color: accent
                                Keys.enabled: false
                                Text {
                                    anchors.fill: parent
                                    text: "Restart"
                                    color: restart.accent
                                    font.family: host.theme.fontFamily
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    fontSizeMode: Text.Fit
                                    minimumPixelSize: 10
                                    elide: Text.ElideRight
                                }
                                onClicked: {
                                    if (enabled) root.restartTerminal(host.widget.id, host.outputName);
                                }
                            }
                        }
                    }
                    Component.onCompleted: {
                        inputMask.regions.push(inputRegion);
                        inputMask.regions.push(recoveryInputRegion);
                        fullscreenInputMask.regions.push(fullscreenInputRegion);
                        fullscreenInputMask.regions.push(fullscreenRecoveryInputRegion);
                        root.registerHost(host);
                    }
                    Component.onDestruction: {
                        outputSurface.removeRegion(inputRegion);
                        outputSurface.removeRegion(recoveryInputRegion);
                        const index = fullscreenInputMask.regions.indexOf(fullscreenInputRegion);
                        if (index >= 0) fullscreenInputMask.regions.splice(index, 1);
                        const recoveryIndex = fullscreenInputMask.regions.indexOf(fullscreenRecoveryInputRegion);
                        if (recoveryIndex >= 0) fullscreenInputMask.regions.splice(recoveryIndex, 1);
                        root.unregisterHost(host);
                    }
                }
            }
            Connections {
                target: root
                function onKeyboardFocusRequested(widgetId) {
                    if (root.keyboardHost && root.keyboardHost.outputName === outputSurface.screen.name)
                        Qt.callLater(outputSurface.focusKeyboardRenderer, root.keyboardHost, root.keyboardHost.revealGeneration);
                }
            }
            HyprlandFocusGrab {
                active: outputSurface.keyboardFocused || fullscreenSurface.keyboardFocused
                windows: [outputSurface, fullscreenSurface]
                onCleared: {
                    if (root.keyboardHost && root.keyboardHost.outputName === outputSurface.screen.name)
                        root.releaseKeyboardFocusAfterOutsideClick(root.keyboardWidgetId);
                }
            }
            Shortcut {
                sequence: "Escape"
                enabled: outputSurface.keyboardFocused
                onActivated: {
                    if (root.fullscreenWidgetId && root.fullscreenOutputName === outputSurface.screen.name)
                        root.toggleFullscreen(root.fullscreenWidgetId, outputSurface.screen.name);
                    else root.releaseKeyboardFocus(root.keyboardWidgetId);
                }
            }
        }
    }

    WidgetEditMode {
        occupiedBar: root.occupiedBar
        externalReservationsByOutput: root.externalReservationsByOutput
        active: root.editMode
        items: root.editItems
        widgetTheme: sharedWidgetTheme
        provider: nativeProvider
        qmlRegistry: Theme.widgetRegistry
        onItemChanged: (index, item) => root.replaceEditItem(index, item)
        onExitRequested: root.cancelEdit()
        onSaveRequested: root.saveEdit()
    }
    IpcHandler {
        target: "widget-edit"
        function focus(widgetId: string): string { return root.focusWidget(widgetId); }
        function fullscreen(widgetId: string): string { return root.toggleFullscreen(widgetId); }
        function restart(widgetId: string, outputName: string): string { return JSON.stringify(root.restartTerminal(widgetId, outputName)); }
        function open(): string { return root.requestLayoutEdit(); }
        function close(): string { return root.cancelEdit(); }
        function save(): string { return root.saveEdit(); }
        function status(): string { return JSON.stringify({active: root.editMode, items: root.editItems, widgets: root.hosts.map(host => ({id: host.widget.id, output: host.outputName, phase: host.phase, error: host.error, revealGeneration: host.revealGeneration, snapshot: root.snapshotMetadata(host.snapshot), terminal: host.widget.kind === "terminal" ? root.terminalSnapshotMetadata(host.snapshot) : undefined}))}); }
    }
}
