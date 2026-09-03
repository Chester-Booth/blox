import QtQuick
import Quickshell
import Quickshell.Io

// Keep the optional PipeWire service from becoming a shell-start dependency.
// A failed provider reports typed unavailable state without a second owner.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 30000
    property url providerSource: Qt.resolvedUrl("PipewireAudioProvider.qml")
    property string raw: ""
    property var json: providerReady ? providerLoader.item.json : providerFailed ? unavailableStatus : loadingStatus
    property bool ok: true
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property bool refreshPending: false
    property string pendingRaw: ""
    property int lastExitCode: 0
    property string lastError: providerReady ? providerLoader.item.lastError : ""
    property bool timedOut: false
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
            "pending": afterRevision < beforeRevision + 1
        };
        if (value !== undefined)
            data.value = value;
        return data;
    }

    function action(operation, value) {
        const name = String(operation || "");
        if (["set-volume", "toggle-mute", "set-mic"].indexOf(name) < 0)
            return root.actionResult(false, "invalid-data", "unknown audio operation", null);

        if (!root.providerReady)
            return root.actionResult(false, "unavailable", "the PipeWire audio provider is not ready", null);

        const status = root.json || ({
        });
        const capability = status.capability || ({
        });
        const beforeRevision = Number(status.providerRevision || 0);
        if (name === "set-mic") {
            if (status.micCanChange !== true)
                return root.actionResult(false, "unavailable", "the default microphone is unavailable", null);
            if (["open", "muted"].indexOf(String(value || "")) < 0)
                return root.actionResult(false, "invalid-data", "microphone state must be open or muted", null);
            if (!root.setMicMuted(String(value) === "muted"))
                return root.actionResult(false, "failed", "the microphone action was rejected", null);
            return root.actionResult(true, "ok", "", root.actionData(name, String(value), beforeRevision));
        }

        if (capability.canChange !== true)
            return root.actionResult(false, "unavailable", "the default audio sink is unavailable", null);

        if (name === "set-volume") {
            const volume = Number(value);
            if (!isFinite(volume) || Math.round(volume) !== volume || volume < 0 || volume > 150)
                return root.actionResult(false, "invalid-data", "volume must be an integer from 0 to 150", null);
            if (!root.setVolume(volume))
                return root.actionResult(false, "failed", "the volume action was rejected", null);
            return root.actionResult(true, "ok", "", root.actionData(name, volume, beforeRevision));
        }

        if (!root.toggleMute())
            return root.actionResult(false, "failed", "the mute action was rejected", null);
        return root.actionResult(true, "ok", "", root.actionData(name, undefined, beforeRevision));
    }

    Loader {
        id: providerLoader

        active: true
        source: root.providerSource
    }

}
