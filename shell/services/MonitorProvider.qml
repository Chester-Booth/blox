import QtQuick
import Quickshell
import Quickshell.Io

// Own Hyprland monitor discovery and refresh changes.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int timeout: 5000
    property string pendingRaw: ""
    property string actionRaw: ""
    property string queryError: ""
    property string actionError: ""
    property var pendingRequest: null
    property bool syncReady: false
    property bool timedOut: false
    readonly property bool providerReady: root.scriptRoot.length > 0
    readonly property bool actionBusy: actionProcess.running || root.pendingRequest !== null
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError.length > 0 ? root.actionError : root.queryError
    readonly property bool ok: root.lastError.length === 0
    readonly property var json: state.json

    function applyPayload(payload) {
        root.queryError = "";
        state.backendAvailable = payload && payload.capability && payload.capability.available === true;
        state.monitors = payload && Array.isArray(payload.monitors) ? payload.monitors : [];
        root.syncReady = true;
        state.markChanged();
    }

    function refresh() {
        if (!root.providerReady || queryProcess.running)
            return false;
        root.pendingRaw = "";
        root.timedOut = false;
        queryProcess.running = true;
        return true;
    }

    function setRefresh(monitorName, refreshId) {
        if (!state.canChange || root.actionBusy)
            return false;
        const monitor = state.monitors.find(item => item.name === String(monitorName));
        if (!monitor || monitor.canChange !== true || !monitor.rates.some(item => item.id === String(refreshId)))
            return false;
        root.actionError = "";
        root.actionRaw = "";
        root.timedOut = false;
        root.pendingRequest = {"monitor": monitor.name, "refreshId": String(refreshId)};
        actionProcess.command = [root.scriptRoot + "/graphicsctl.py", "set-refresh", monitor.name, String(refreshId), JSON.stringify(monitor)];
        actionProcess.running = true;
        return true;
    }

    MonitorState {
        id: state
        providerReady: root.providerReady
        syncReady: root.syncReady
        busy: root.actionBusy
        errorCode: root.lastError
    }

    Process {
        id: queryProcess
        command: [root.scriptRoot + "/graphicsctl.py", "monitors"]
        onStarted: queryWatchdog.restart()
        onExited: (exitCode, exitStatus) => {
            queryWatchdog.stop();
            if (root.timedOut) {
                root.queryError = "query-timeout";
                state.backendAvailable = false;
                root.syncReady = true;
            } else if (exitCode === 0 && exitStatus === 0) {
                try {
                    root.applyPayload(JSON.parse(root.pendingRaw.trim()));
                } catch (error) {
                    root.queryError = "malformed-status";
                    state.backendAvailable = false;
                    root.syncReady = true;
                }
            } else {
                root.queryError = "query-failed";
                state.backendAvailable = false;
                root.syncReady = true;
            }
            state.markChanged();
        }
        stdout: StdioCollector { onStreamFinished: root.pendingRaw = this.text }
    }

    Process {
        id: actionProcess
        command: []
        onStarted: actionWatchdog.restart()
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            if (root.timedOut) {
                root.actionError = "timeout";
            } else {
                try {
                    const reply = JSON.parse(root.actionRaw.trim());
                    root.actionError = reply.ok === true ? "" : String(reply.code || "failed");
                } catch (error) {
                    root.actionError = exitCode === 0 && exitStatus === 0 ? "invalid-data" : "failed";
                }
            }
            root.pendingRequest = null;
            state.markChanged();
            root.refresh();
        }
        stdout: StdioCollector { onStreamFinished: root.actionRaw = this.text }
    }

    Timer {
        id: queryWatchdog
        interval: Math.max(1, root.timeout)
        repeat: false
        onTriggered: {
            if (queryProcess.running) {
                root.timedOut = true;
                queryProcess.signal(15);
            }
        }
    }

    Timer {
        id: actionWatchdog
        interval: Math.max(1, root.timeout)
        repeat: false
        onTriggered: {
            if (actionProcess.running) {
                root.timedOut = true;
                actionProcess.signal(15);
            }
        }
    }

    Timer {
        interval: Math.max(1000, root.interval)
        running: root.providerReady && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
