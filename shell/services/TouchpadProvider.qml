import QtQuick
import Quickshell
import Quickshell.Io

// Own touchpad discovery and compositor actions. The helper discovers the
// current compositor device list, so the owner never embeds a device name.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 15000
    property int timeout: 5000
    property bool syncReady: false
    property bool refreshPending: false
    property string pendingRaw: ""
    property var pendingEnabled: null
    property string queryError: ""
    property string actionError: ""
    property bool timedOut: false
    readonly property bool providerReady: root.scriptRoot.length > 0
    readonly property bool actionBusy: actionProcess.running || root.pendingEnabled !== null
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
        state.device = String(payload.device || "");
        state.touchpadEnabled = payload.enabled !== false;
        root.syncReady = true;
        state.markChanged();
    }

    function applyQueryFailure(message) {
        root.queryError = message;
        root.syncReady = true;
        state.backendAvailable = false;
        state.devices = [];
        state.device = "";
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

    function setEnabled(value) {
        if (!state.canChange || root.actionBusy)
            return false;
        root.actionError = "";
        root.pendingEnabled = value === true;
        actionProcess.command = [root.scriptRoot + "/osd/control.sh", root.pendingEnabled ? "touchpad-on" : "touchpad-off"];
        actionProcess.running = true;
        actionWatchdog.restart();
        return true;
    }

    function toggle() {
        return root.setEnabled(!state.touchpadEnabled);
    }

    TouchpadState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        busy: root.actionBusy
        actionError: root.actionError.length > 0 ? root.actionError : root.queryError
    }

    Process {
        id: queryProcess

        command: [root.scriptRoot + "/status/touchpad.sh"]
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
                        throw new Error("touchpad status was not an object");
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
            root.pendingEnabled = null;
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
        if (root.pendingEnabled === null)
            return ;
        if (!state.canChange) {
            root.pendingEnabled = null;
            root.actionError = "device-removed";
        } else if (state.touchpadEnabled === root.pendingEnabled) {
            root.pendingEnabled = null;
        }
    }
}
