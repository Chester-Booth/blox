import QtQuick
import Quickshell
import Quickshell.Io

// Own DRM discovery and the single approved GPU controller adapter.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int timeout: 5000
    property bool syncReady: false
    property bool refreshPending: false
    property string pendingRaw: ""
    property string actionRaw: ""
    property string queryError: ""
    property string actionError: ""
    property var pendingMode: null
    property bool queryTimedOut: false
    property bool actionTimedOut: false
    property bool confirmationRequired: false
    property string requestedMode: ""
    property var activeClients: []
    property string clientsRaw: ""
    property bool logoutOnAcceptance: false
    readonly property bool providerReady: root.scriptRoot.length > 0
    readonly property bool actionBusy: actionProcess.running || clientsProcess.running || root.confirmationRequired || root.pendingMode !== null || state.pendingMode !== null
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError.length > 0 ? root.actionError : root.queryError
    readonly property bool ok: root.lastError.length === 0
    readonly property var json: state.json

    function applyPayload(payload) {
        const capability = payload && payload.capability ? payload.capability : ({ });
        root.queryError = "";
        state.backendAvailable = capability.reason !== "command-unavailable" && capability.available !== false;
        state.devices = Array.isArray(payload.devices) ? payload.devices : [];
        state.deviceCount = Number(payload.deviceCount || state.devices.length || 0);
        state.discreteCount = Number(payload.discreteCount || 0);
        state.integratedCount = Number(payload.integratedCount || 0);
        state.backend = String(payload.backend || "");
        state.controller = String(payload.controller || "");
        state.controllerMode = String(payload.controllerMode || "");
        state.mode = String(payload.mode || "unavailable");
        state.label = String(payload.label || "GPU unavailable");
        state.gpuOn = payload.gpuOn === true;
        state.gpuUtil = String(payload.gpuUtil || "");
        state.gpuTemp = String(payload.gpuTemp || "");
        state.vramUsed = String(payload.vramUsed || "");
        state.vramTotal = String(payload.vramTotal || "");
        state.controlReason = String(payload.controlReason || capability.reason || "");
        state.permission = String(capability.permission || "not-required");
        state.controlAvailable = capability.canChange === true;
        state.supportedModes = Array.isArray(payload.supportedModes) ? payload.supportedModes : [];
        state.pendingMode = payload.pendingMode === undefined ? null : payload.pendingMode;
        state.pendingAction = payload.pendingAction === undefined ? null : payload.pendingAction;
        root.syncReady = true;
        state.markChanged();
    }

    function applyQueryFailure(message) {
        root.queryError = message;
        root.syncReady = true;
        state.backendAvailable = false;
        state.devices = [];
        state.deviceCount = 0;
        state.discreteCount = 0;
        state.integratedCount = 0;
        state.controlAvailable = false;
        state.supportedModes = [];
        state.markChanged();
    }

    function refresh() {
        if (!root.providerReady)
            return ;
        if (queryProcess.running) {
            root.refreshPending = true;
            return ;
        }
        root.refreshPending = false;
        root.pendingRaw = "";
        root.queryTimedOut = false;
        queryProcess.running = true;
    }

    function setMode(value, logoutAfterAcceptance) {
        const mode = String(value || "");
        if (!state.canChange || root.actionBusy || state.supportedModes.indexOf(mode) < 0)
            return false;
        root.actionError = "";
        root.actionRaw = "";
        root.actionTimedOut = false;
        root.pendingMode = mode;
        root.logoutOnAcceptance = logoutAfterAcceptance === true;
        actionProcess.command = [root.scriptRoot + "/graphicsctl.py", "set-gpu-mode", mode, state.mode].concat(root.logoutOnAcceptance ? ["--logout"] : []);
        actionProcess.running = true;
        actionWatchdog.restart();
        return true;
    }

    function requestMode(value) {
        const mode = String(value || "");
        if (!state.canChange || root.actionBusy || mode === state.mode || state.supportedModes.indexOf(mode) < 0)
            return false;
        root.cancelModeRequest();
        root.requestedMode = mode;
        if (mode !== "integrated") {
            root.confirmationRequired = true;
            return true;
        }
        root.clientsRaw = "";
        clientsProcess.running = true;
        return true;
    }

    function cancelModeRequest() {
        root.confirmationRequired = false;
        root.requestedMode = "";
        root.activeClients = [];
    }

    function confirmModeRequest() {
        const mode = root.requestedMode;
        if (!root.confirmationRequired || mode.length === 0)
            return false;
        root.cancelModeRequest();
        return root.setMode(mode, true);
    }

    GpuState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        busy: root.actionBusy
        actionError: root.actionError.length > 0 ? root.actionError : root.queryError
    }

    Process {
        id: queryProcess

        command: [root.scriptRoot + "/status/gpu.sh"]
        onStarted: queryWatchdog.restart()
        onExited: (exitCode, exitStatus) => {
            queryWatchdog.stop();
            forceKill.stop();
            if (root.queryTimedOut) {
                root.applyQueryFailure("query-timeout");
            } else if (exitCode === 0 && exitStatus === 0) {
                const output = root.pendingRaw.trim();
                try {
                    const parsed = output.length > 0 ? JSON.parse(output) : null;
                    if (!parsed || typeof parsed !== "object")
                        throw new Error("GPU status was not an object");
                    root.applyPayload(parsed);
                } catch (error) {
                    root.applyQueryFailure("malformed-status");
                }
            } else {
                root.applyQueryFailure("query-failed");
            }
            if (root.refreshPending)
                Qt.callLater(root.refresh);
        }

        stdout: StdioCollector {
            onStreamFinished: root.pendingRaw = this.text
        }
    }

    Process {
        id: clientsProcess

        command: [root.scriptRoot + "/graphicsctl.py", "gpu-clients"]
        stdout: StdioCollector {
            onStreamFinished: root.clientsRaw = this.text
        }
        onExited: (exitCode, exitStatus) => {
            const mode = root.requestedMode;
            if (mode.length === 0)
                return;
            try {
                const reply = JSON.parse(root.clientsRaw.trim());
                if (exitCode !== 0 || exitStatus !== 0 || reply.ok !== true || !reply.data)
                    throw new Error("GPU client query failed");
                root.activeClients = Array.isArray(reply.data.clients) ? reply.data.clients : [];
                root.confirmationRequired = true;
            } catch (error) {
                root.actionError = "client-query-failed";
                root.cancelModeRequest();
            }
        }
    }

    Process {
        id: actionProcess

        command: []
        stdout: StdioCollector {
            onStreamFinished: root.actionRaw = this.text
        }
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            const requestedMode = root.pendingMode;
            if (root.actionTimedOut) {
                root.actionError = "timeout";
            } else {
                try {
                    const reply = JSON.parse(root.actionRaw.trim());
                    root.actionError = reply.ok === true ? "" : String(reply.code || "failed");
                    if (reply.ok === true && reply.data) {
                        state.pendingMode = reply.data.changed === true ? requestedMode : null;
                        state.pendingAction = reply.data.pendingAction === undefined ? null : reply.data.pendingAction;
                    }
                } catch (error) {
                    root.actionError = exitCode === 0 && exitStatus === 0 ? "invalid-data" : "failed";
                }
            }
            root.pendingMode = null;
            state.markChanged();
            root.logoutOnAcceptance = false;
            root.refresh();
        }
    }

    Timer {
        id: queryWatchdog

        interval: Math.max(1, root.timeout)
        repeat: false
        onTriggered: {
            if (!queryProcess.running)
                return ;
            root.queryTimedOut = true;
            queryProcess.signal(15);
            forceKill.restart();
        }
    }

    Timer {
        id: actionWatchdog

        interval: Math.max(15000, root.timeout * 3)
        repeat: false
        onTriggered: {
            if (!actionProcess.running)
                return ;
            root.actionTimedOut = true;
            actionProcess.signal(15);
            forceKill.restart();
        }
    }

    Timer {
        id: forceKill

        interval: 1000
        repeat: false
        onTriggered: {
            if (queryProcess.running)
                queryProcess.signal(9);
            if (actionProcess.running)
                actionProcess.signal(9);
        }
    }

    Timer {
        interval: Math.max(1000, root.interval)
        running: root.providerReady && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Connections {
        target: state
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncAction(); }
    }

    function syncAction() {
        if (root.pendingMode === null)
            return ;
        if (!state.canChange) {
            root.pendingMode = null;
            root.actionError = "removed";
        } else if (state.mode === root.pendingMode) {
            root.pendingMode = null;
        }
    }
}
