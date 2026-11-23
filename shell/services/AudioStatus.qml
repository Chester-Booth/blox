import qs.shared
import QtQuick
import "ActionContract.js" as ActionContract
import Quickshell
import Quickshell.Io

// Keep the optional PipeWire service from becoming a shell-start dependency.
// A failed provider reports typed unavailable state without a second owner.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 30000
    property url providerSource: Qt.resolvedUrl("PipewireAudioProvider.qml")
    property var pendingMicrophoneFeedback: null
    property var pendingMicrophoneFeedbackSource: null
    signal microphoneFeedbackRequested(bool muted)
    property string raw: ""
    property var json: providerReady ? providerLoader.item.json : providerFailed ? unavailableStatus : loadingStatus
    property bool ok: true
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property bool refreshPending: false
    property string pendingRaw: ""
    property int lastExitCode: 0
    property string lastError: providerReady ? providerLoader.item.lastError : ""
    property bool timedOut: false
    // Identity only. The existing provider remains the sole audio observer.
    readonly property var sink: providerReady ? providerLoader.item.sink || null : null
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error
    readonly property var loadingStatus: ({
        "icon": "󰝟",
        "micIcon": "󰍭",
        "volume": 0,
        "muted": true,
        "micMuted": true,
        "micCanChange": false,
        "tooltip": "Audio provider loading",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-loading",
        "capability": {
            "available": true,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "provider-loading"
        }
    })

    readonly property var unavailableStatus: ({
        "icon": "󰝟",
        "micIcon": "󰍭",
        "volume": 0,
        "muted": true,
        "micMuted": true,
        "micCanChange": false,
        "tooltip": "Audio provider unavailable",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-unavailable",
        "capability": {
            "available": false,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "provider-unavailable"
        }
    })

    function refresh() {
        if (root.providerReady) {
            providerLoader.item.refresh();
            return ;
        }
    }

    function setVolume(value) {
        return root.providerReady && providerLoader.item.setVolume(value);
    }

    function toggleMute() {
        return root.providerReady && providerLoader.item.toggleMute();
    }

    function setMicMuted(value) {
        return root.providerReady && providerLoader.item.setMicMuted(value);
    }

    function actionResult(ok, code, message, data) {
        return {
            "version": 1,
            "ok": ok,
            "code": code,
            "message": message,
            "data": data
        };
    }

    function actionData(operation, value, beforeRevision) {
        const status = root.json || ({
        });
        const afterRevision = Number(status.providerRevision || beforeRevision);
        const data = {
            "operation": operation,
            "beforeRevision": beforeRevision,
            "afterRevision": afterRevision,
            "observedAtMs": Number(status.observedAtMs || 0),
            "pending": status.busy === true || (operation === "set-mic" || operation === "toggle-mic"
                ? status.micMuted !== (value === "muted")
                : operation === "toggle-mute" ? status.muted !== value : Number(status.volume) !== Number(value))
        };
        if (value !== undefined)
            data.value = value;
        return data;
    }

    function publishMicrophoneFeedback() {
        if (pendingMicrophoneFeedback === null)
            return;
        if (!providerReady || providerLoader.item.source !== pendingMicrophoneFeedbackSource || !root.json || root.json.micCanChange !== true) {
            pendingMicrophoneFeedback = null;
            return;
        }
        if (root.json.micMuted !== pendingMicrophoneFeedback)
            return;
        const muted = pendingMicrophoneFeedback;
        pendingMicrophoneFeedback = null;
        microphoneFeedbackRequested(muted);
        if (scriptRoot.length > 0)
            Quickshell.execDetached([scriptRoot + "/providers/mic-feedback.sh", muted ? "true" : "false"]);
    }

    onJsonChanged: publishMicrophoneFeedback()

    function action(operation, value) {
        const name = String(operation || "");
        if (["set-volume", "adjust-volume", "toggle-mute", "set-mic", "toggle-mic"].indexOf(name) < 0)
            return root.actionResult(false, "invalid-data", "unknown audio operation", null);

        if (!root.providerReady)
            return root.actionResult(false, "unavailable", "the PipeWire audio provider is not ready", null);

        const status = root.json || ({
        });
        const capability = status.capability || ({
        });
        // Microphone readiness is independent of the default output sink.
        const actionStatus = ["set-mic", "toggle-mic"].indexOf(name) >= 0 ? Object.assign({}, status, {
            stale: false,
            capability: Object.assign({}, capability, {available: status.micCanChange === true ? true : capability.available})
        }) : status;
        const blocked = ActionContract.blockedCode(actionStatus, ["set-mic", "toggle-mic"].indexOf(name) >= 0 ? status.micCanChange : capability.canChange);
        if (blocked)
            return root.actionResult(false, blocked, "the audio action is unavailable", null);
        const beforeRevision = Number(status.providerRevision || 0);
        if (["set-mic", "toggle-mic"].indexOf(name) >= 0) {
            if (status.micCanChange !== true)
                return root.actionResult(false, "unavailable", "the default microphone is unavailable", null);
            if (name === "set-mic" && ["open", "muted"].indexOf(String(value || "")) < 0)
                return root.actionResult(false, "invalid-data", "microphone state must be open or muted", null);
            const muted = name === "toggle-mic" ? status.micMuted !== true : String(value) === "muted";
            if (!root.setMicMuted(muted))
                return root.actionResult(false, "failed", "the microphone action was rejected", null);
            pendingMicrophoneFeedbackSource = providerLoader.item.source;
            pendingMicrophoneFeedback = muted;
            publishMicrophoneFeedback();
            return root.actionResult(true, "ok", "", root.actionData(name, muted ? "muted" : "open", beforeRevision));
        }

        if (capability.canChange !== true)
            return root.actionResult(false, "unavailable", "the default audio sink is unavailable", null);

        if (name === "set-volume" || name === "adjust-volume") {
            const requested = Number(value);
            if (!isFinite(requested) || Math.round(requested) !== requested || (name === "adjust-volume" && (requested < -150 || requested > 150)))
                return root.actionResult(false, "invalid-data", "volume must be an integer within the supported range", null);
            const volume = name === "adjust-volume" ? Math.max(0, Math.min(150, Number(status.volume || 0) + requested)) : requested;
            if (!isFinite(volume) || Math.round(volume) !== volume || volume < 0 || volume > 150)
                return root.actionResult(false, "invalid-data", "volume must be an integer from 0 to 150", null);
            if (!root.setVolume(volume))
                return root.actionResult(false, "failed", "the volume action was rejected", null);
            return root.actionResult(true, "ok", "", root.actionData(name, volume, beforeRevision));
        }

        if (!root.toggleMute())
            return root.actionResult(false, "failed", "the mute action was rejected", null);
        return root.actionResult(true, "ok", "", root.actionData(name, status.muted !== true, beforeRevision));
    }

    Loader {
        id: providerLoader

        active: true
        source: root.providerSource
    }

}
