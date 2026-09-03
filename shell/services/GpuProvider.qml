import QtQuick
import Quickshell
import Quickshell.Io

// Own optional graphics discovery and vendor mode actions. The current
// probe keeps privileged GPU power switching non-actionable until a safe
// owner exists.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int timeout: 5000
    property bool syncReady: false
    property bool refreshPending: false
    property string pendingRaw: ""
    property string queryError: ""
    property string actionError: ""
    property var pendingMode: null
    property bool timedOut: false
    readonly property bool providerReady: root.scriptRoot.length > 0
    readonly property bool actionBusy: actionProcess.running || root.pendingMode !== null
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
        state.backend = String(payload.backend || "");
        state.mode = String(payload.mode || "unavailable");
        state.label = String(payload.label || "GPU unavailable");
        state.gpuOn = payload.gpuOn === true;
        state.gpuUtil = String(payload.gpuUtil || "");
        state.gpuTemp = String(payload.gpuTemp || "");
        state.vramUsed = String(payload.vramUsed || "");
        state.vramTotal = String(payload.vramTotal || "");
        state.controlReason = String(payload.controlReason || capability.reason || "no-supported-controller");
        state.permission = String(capability.permission || "not-required");
        state.controlAvailable = capability.canChange === true;
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
        state.controlAvailable = false;
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
        root.timedOut = false;
        queryProcess.running = true;
    }

    function setMode(value) {
        const mode = String(value || "");
        if (!state.canChange || root.actionBusy || ["gaming", "performance", "high-refresh", "eco"].indexOf(mode) < 0)
            return false;
        root.actionError = "";
        root.pendingMode = mode;
        actionProcess.command = [root.scriptRoot + "/gpu/set-mode.sh", mode, "--quiet"];
        actionProcess.running = true;
        actionWatchdog.restart();
        return true;
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
            if (root.timedOut) {
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
        id: actionProcess

        command: []
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            if (root.timedOut)
                root.actionError = "action-timeout";
            else if (exitCode !== 0 || exitStatus !== 0)
                root.actionError = "action-failed";
            root.pendingMode = null;
            state.markChanged();
            if (root.actionError.length === 0)
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
            root.timedOut = true;
            queryProcess.signal(15);
            forceKill.restart();
        }
    }

    Timer {
        id: actionWatchdog

        interval: Math.max(1, root.timeout)
        repeat: false
        onTriggered: {
            if (!actionProcess.running)
                return ;
            root.timedOut = true;
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
            root.actionError = "controller-removed";
        } else if (state.mode === root.pendingMode) {
            root.pendingMode = null;
        }
    }
}
