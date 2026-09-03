import QtQuick
import Quickshell
import Quickshell.Io

// Own the discovered kernel-backlight path and its actions. DDC is read as
// bounded discovery metadata for now; an absent ddcutil command is harmless.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 30000
    property int timeout: 5000
    property string requestedDevice: ""
    property bool syncReady: false
    property bool refreshPending: false
    property string pendingRaw: ""
    property string activeBrightness: ""
    property string pendingBrightness: ""
    property string actionError: ""
    property bool timedOut: false
    readonly property bool providerReady: root.scriptRoot.length > 0
    readonly property bool actionBusy: actionProcess.running || root.pendingBrightness.length > 0
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError.length > 0 ? root.actionError : queryError
    readonly property bool ok: root.lastError.length === 0
    readonly property var json: state.json
    property string queryError: ""

    function applyPayload(payload) {
        root.queryError = "";
        state.backendAvailable = payload.capability && payload.capability.reason !== "command-unavailable";
        state.device = String(payload.device || "");
        state.backlights = Array.isArray(payload.backlights) ? payload.backlights : [];
        state.percent = Number(payload.percent || 0);
        state.blueLightMode = String(payload.blueLightMode || "auto");
        state.blueLightActive = payload.blueLightActive === true;
        state.ddcAvailable = payload.ddcAvailable === true;
        state.ddcDisplayCount = Number(payload.ddcDisplayCount || 0);
        state.ddcReason = String(payload.ddcReason || "");
        root.syncReady = true;
        state.markChanged();
    }

    function applyQueryFailure(message) {
        root.queryError = message;
        root.syncReady = true;
        state.backendAvailable = false;
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

    function startBrightness(value) {
        root.activeBrightness = String(value);
        root.actionError = "";
        actionProcess.command = [root.scriptRoot + "/control.sh", "brightness-set-silent", root.activeBrightness];
        actionProcess.running = true;
    }

    function setBrightness(value) {
        const next = Math.max(0, Math.min(100, Math.round(Number(value))));
        if (!isFinite(next) || !state.canChange)
            return false;
        root.pendingBrightness = String(next);
        if (!actionProcess.running)
            root.startBrightness(next);
        return true;
    }

    BrightnessState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        busy: root.actionBusy
        actionError: root.actionError.length > 0 ? root.actionError : root.queryError
    }

    Process {
        id: queryProcess

        command: [root.scriptRoot + "/status/brightness.sh", root.requestedDevice]
        onStarted: queryWatchdog.restart()
        onExited: (exitCode, exitStatus) => {
            queryWatchdog.stop();
            actionKill.stop();
            if (root.timedOut) {
                root.applyQueryFailure("query-timeout");
            } else if (exitCode === 0 && exitStatus === 0) {
                const output = root.pendingRaw.trim();
                try {
                    const parsed = output.length > 0 ? JSON.parse(output) : null;
                    if (!parsed || typeof parsed !== "object")
                        throw new Error("brightness status was not an object");
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
        onStarted: actionWatchdog.restart()
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            if (root.timedOut)
                root.actionError = "action-timeout";
            else if (exitCode !== 0 || exitStatus !== 0)
                root.actionError = "action-failed";
            const next = root.pendingBrightness;
            const completed = root.activeBrightness;
            root.activeBrightness = "";
            if (root.actionError.length === 0 && next.length > 0 && next !== completed) {
                root.pendingBrightness = "";
                root.startBrightness(next);
                return ;
            }
            root.pendingBrightness = "";
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
            actionKill.restart();
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
            actionKill.restart();
        }
    }

    Timer {
        id: actionKill

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

        function onJsonChanged() { }
    }
}
