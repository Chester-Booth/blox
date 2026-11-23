import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

// Own the optional asusctl profile backend. It is separate from UPower's
// generic power-profile service and may be absent on other machines.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int timeout: 5000
    // Three two-second reads share a six-second deadline. Leave time for
    // capture and JSON parsing before the provider cancels the whole helper.
    property int queryTimeout: Math.max(8000, root.timeout)
    property bool syncReady: false
    property bool refreshPending: false
    property string pendingRaw: ""
    property var pendingProfile: null
    property var pendingFanCurve: null
    property string queryError: ""
    property string actionError: ""
    property bool queryTimedOut: false
    property bool actionTimedOut: false
    property int queryFailureCount: 0
    property real retryAfterMs: 0
    readonly property bool providerReady: root.scriptRoot.length > 0
    readonly property bool actionBusy: actionProcess.running || root.pendingProfile !== null || root.pendingFanCurve !== null
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError.length > 0 ? root.actionError : root.queryError
    readonly property bool ok: root.lastError.length === 0
    readonly property var json: state.json

    function applyPayload(payload) {
        const capability = payload && payload.capability ? payload.capability : ({ });
        root.queryError = capability.available === false ? String(payload.errorCode || capability.reason || "query-failed") : "";
        root.recordQueryResult(root.queryError.length > 0);
        state.backendAvailable = capability.reason !== "command-unavailable" && capability.available !== false;
        state.vendor = String(payload.vendor || "");
        state.profile = String(payload.profile || "unavailable");
        state.profileLabel = String(payload.profileLabel || "");
        state.profiles = Array.isArray(payload.profiles) ? payload.profiles : [];
        state.profileControlDomain = String(payload.profileControlDomain || "");
        state.fanCurveAvailable = !!payload.fanCurveCapability && payload.fanCurveCapability.available === true;
        state.fanCurveEnabled = payload.fanCurveEnabled === true;
        state.fanCurveCapability = payload.fanCurveCapability || ({
            "available": false,
            "ready": true,
            "canChange": false,
            "permission": "not-required",
            "reason": "fan-curves-unsupported"
        });
        root.syncReady = true;
        state.markChanged();
    }

    function applyQueryFailure(message) {
        root.queryError = message;
        root.recordQueryResult(true);
        root.syncReady = true;
        state.backendAvailable = false;
        state.profiles = [];
        state.profileControlDomain = "";
        state.fanCurveAvailable = false;
        state.fanCurveEnabled = false;
        state.profile = "unavailable";
        state.markChanged();
    }

    function recordQueryResult(failed) {
        if (!failed) {
            root.queryFailureCount = 0;
            root.retryAfterMs = 0;
            return;
        }
        root.queryFailureCount = Math.min(8, root.queryFailureCount + 1);
        const delay = Math.min(300000, Math.max(5000, root.interval) * Math.pow(2, root.queryFailureCount - 1));
        root.retryAfterMs = Date.now() + delay;
    }

    function refresh(explicit) {
        if (!root.providerReady)
            return ;
        const force = explicit !== false;
        if (!force && Date.now() < root.retryAfterMs)
            return;
        if (queryProcess.running) {
            // Periodic ticks need no follow-up. Explicit refreshes and action
            // completion still coalesce into one immediate recovery attempt.
            if (force)
                root.refreshPending = true;
            return ;
        }
        root.refreshPending = false;
        root.pendingRaw = "";
        root.queryTimedOut = false;
        queryProcess.running = true;
    }

    function setProfile(value) {
        const profile = String(value || "");
        if (!state.canChange || root.actionBusy || state.profiles.indexOf(profile) < 0)
            return false;
        root.actionError = "";
        root.pendingProfile = profile;
        root.actionTimedOut = false;
        actionProcess.command = [root.scriptRoot + "/providers/hardware-control.sh", "profile-set", profile];
        actionProcess.running = true;
        actionWatchdog.restart();
        return true;
    }

    function setFanCurvesEnabled(value) {
        if (!state.fanCurveAvailable || root.actionBusy)
            return false;
        root.actionError = "";
        root.pendingFanCurve = value === true;
        root.actionTimedOut = false;
        actionProcess.command = [root.scriptRoot + "/providers/hardware-control.sh", "fan-curves-set", value === true ? "on" : "off"];
        actionProcess.running = true;
        actionWatchdog.restart();
        return true;
    }

    VendorPerformanceState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        busy: root.actionBusy
        actionError: root.actionError.length > 0 ? root.actionError : root.queryError
    }

    Process {
        id: queryProcess

        command: [root.scriptRoot + "/status/vendor-performance.sh"]
        onStarted: queryWatchdog.restart()
        onExited: (exitCode, exitStatus) => {
            queryWatchdog.stop();
            queryKill.stop();
            if (root.queryTimedOut) {
                root.applyQueryFailure("query-timeout");
            } else if (exitCode === 0 && exitStatus === 0) {
                const output = root.pendingRaw.trim();
                try {
                    const parsed = output.length > 0 ? JSON.parse(output) : null;
                    if (!parsed || typeof parsed !== "object")
                        throw new Error("vendor performance status was not an object");
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

        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text.trim().length > 0)
                    console.warn("[blox.vendor-performance] " + this.text.trim());
            }
        }
    }

    Process {
        id: actionProcess

        command: []
        onExited: (exitCode, exitStatus) => {
            actionWatchdog.stop();
            actionKill.stop();
            root.pendingProfile = null;
            root.pendingFanCurve = null;
            if (root.actionTimedOut)
                root.actionError = "action-timeout";
            else if (exitCode !== 0 || exitStatus !== 0)
                root.actionError = "action-failed";
            state.markChanged();
            if (root.actionError.length === 0)
                root.refresh();
        }
    }

    Timer {
        id: queryWatchdog

        interval: Math.max(1, root.queryTimeout)
        repeat: false
        onTriggered: {
            if (!queryProcess.running)
                return ;
            root.queryTimedOut = true;
            queryProcess.signal(15);
            queryKill.restart();
        }
    }

    Timer {
        id: actionWatchdog

        interval: Math.max(1, root.timeout)
        repeat: false
        onTriggered: {
            if (!actionProcess.running)
                return ;
            root.actionTimedOut = true;
            actionProcess.signal(15);
            actionKill.restart();
        }
    }

    Timer {
        id: queryKill
        interval: 1000
        repeat: false
        onTriggered: {
            if (queryProcess.running)
                queryProcess.signal(9);
        }
    }

    Timer {
        id: actionKill
        interval: 1000
        repeat: false
        onTriggered: {
            if (actionProcess.running)
                actionProcess.signal(9);
        }
    }

    Timer {
        interval: Math.max(1000, root.interval)
        running: root.providerReady && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh(false)
    }

    Connections {
        target: state
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncAction(); }
    }

    function syncAction() {
        // A failed discovery must not invalidate an action still in flight.
        // Its completion owns the result and requests a fresh query on success.
        if (actionProcess.running)
            return;
        if (root.pendingProfile !== null) {
            if (!state.canChange) {
                root.pendingProfile = null;
                root.actionError = "profile-removed";
            } else if (state.profile === root.pendingProfile) {
                root.pendingProfile = null;
            }
        }
        if (root.pendingFanCurve !== null) {
            if (!state.fanCurveAvailable) {
                root.pendingFanCurve = null;
                root.actionError = "fan-curves-removed";
            } else if (state.fanCurveEnabled === root.pendingFanCurve) {
                root.pendingFanCurve = null;
            }
        }
    }
}
