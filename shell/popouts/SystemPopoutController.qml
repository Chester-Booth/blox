import QtQuick

QtObject {
    id: root

    property string mode: ""
    property string title: ""
    property string body: ""
    property string statusError: ""
    property string actionError: ""
    property var pendingActions: []
    property var actionErrorProvider: null
    property string actionErrorCode: ""
    readonly property string disabledReasonText: root.disabledReason()
    readonly property string feedbackText: {
        if (root.actionError.length > 0)
            return root.actionError;
        if (root.statusError.length > 0)
            return "Status error: " + root.statusError + (root.body.length > 0 ? "\n" + root.body : "");
        if (root.disabledReasonText.length > 0)
            return root.disabledReasonText;
        if (root.body.length > 0 && root.currentMode() !== "network" && root.currentMode() !== "bluetooth" && root.currentMode() !== "brightness")
            return root.body;
        return "";
    }
    readonly property bool feedbackIsError: root.actionError.length > 0 || root.statusError.length > 0
    property var actions: []
    property string scriptRoot: ""
    property int audioVolume: 0
    property string audioIcon: "󰕾"
    property bool audioMuted: false
    property bool micMuted: false
    property bool micCanChange: audioCanChange
    property var audioProvider: null
    property bool networkEnabled: true
    property bool bluetoothEnabled: true
    property bool audioCanChange: false
    property bool networkCanChange: false
    property bool bluetoothCanChange: false
    property var networkProvider: null
    property var bluetoothProvider: null
    property var brightnessProvider: null
    property bool brightnessCanChange: false
    property string wifiIcon: "󰤩"
    property string wifiText: "Wi-Fi"
    property string bluetoothIcon: "󰂯"
    property string brightnessIcon: "󰃠"
    property int brightnessPercent: 0
    property string blueLightMode: "auto"
    property bool blueLightActive: false
    property int visualAudioVolume: audioVolume
    property int visualBrightnessPercent: brightnessPercent
    property string visualBlueLightMode: blueLightMode
    property bool adjustingAudio: false
    property bool adjustingBrightness: false
    property bool audioApplyPending: false
    property bool brightnessApplyPending: false
    readonly property bool audioOverdriven: currentMode() === "audio" && !audioMuted && audioVolume > 100
    readonly property bool visualAudioOverdriven: currentMode() === "audio" && !audioMuted && visualAudioVolume > 100
    property Timer audioApplyDelay
    property Timer brightnessApplyDelay
    property Timer audioSyncDelay
    property Timer brightnessSyncDelay

    signal actionRequested(string command, bool keepOpen)
    signal levelPreviewRequested(string kind, int value, bool muted)

    function currentMode() {
        return mode === "mic" ? "bluetooth" : mode;
    }

    function modeCanChange() {
        if (currentMode() === "audio")
            return audioCanChange;
        if (currentMode() === "network")
            return networkCanChange;
        if (currentMode() === "bluetooth")
            return bluetoothCanChange;
        if (currentMode() === "brightness")
            return brightnessCanChange;
        return false;
    }

    function actionByLabel(text) {
        const lower = text.toLowerCase();
        for (let i = 0; i < actions.length; i++) {
            const label = String(actions[i].label || "").toLowerCase();
            if (label.indexOf(lower) >= 0)
                return actions[i];

        }
        return null;
    }

    function runLabel(text, keepOpen) {
        const item = actionByLabel(text);
        if (!item)
            return ;

        if (item.id === "mic-toggle") {
            root.setMicMuted(!root.micMuted);
            return ;
        }

        if (item.id === "network-toggle") {
            root.setNetworkEnabled(!root.networkEnabled);
            return ;
        }

        if (item.id === "bluetooth-toggle") {
            root.setBluetoothEnabled(!root.bluetoothEnabled);
            return ;
        }

        actionRequested(item.command || "", keepOpen);

    }

    function providerStatus(provider) {
        return provider && provider.json && typeof provider.json === "object" ? provider.json : ({ });
    }

    function capabilityReason(provider) {
        const status = root.providerStatus(provider);
        const capability = status.capability || ({ });
        return String(capability.reason || status.errorCode || "");
    }

    function reasonMessage(provider) {
        const reason = root.capabilityReason(provider);
        const messages = {
            "provider-not-ready": "Provider is not ready",
            "provider-loading": "Waiting for provider",
            "provider-unavailable": "Provider is unavailable",
            "backend-unavailable": "NetworkManager is unavailable",
            "command-unavailable": "Brightness control is unavailable",
            "no-default-sink": "No default audio output is available",
            "device-not-ready": "Audio output is not ready",
            "no-wifi-hardware": "No Wi-Fi hardware is available",
            "no-adapter": "No Bluetooth adapter is available",
            "permission-denied": "Permission denied",
            "device-unavailable": "Control device is unavailable"
        };
        return messages[reason] || reason.replace(/-/g, " ");
    }

    function disabledReason() {
        if (currentMode() === "audio") {
            if (!audioCanChange)
                return root.reasonMessage(audioProvider);
            if (!micCanChange)
                return "Default microphone is unavailable";
        } else if (currentMode() === "network" && !networkCanChange) {
            return root.reasonMessage(networkProvider);
        } else if (currentMode() === "bluetooth" && !bluetoothCanChange) {
            return root.reasonMessage(bluetoothProvider);
        } else if (currentMode() === "brightness" && !brightnessCanChange) {
            return root.reasonMessage(brightnessProvider);
        }
        return "";
    }

    function actionCodeMessage(name, code, provider) {
        if (code === "unavailable")
            return root.reasonMessage(provider) || name + " is unavailable";
        if (code === "busy")
            return name + " action is already in progress";
        if (code === "permission-denied")
            return "Permission denied";
        if (code === "stale")
            return name + " status is out of date";
        if (code === "timeout" || code === "action-timeout")
            return name + " action timed out";
        if (code === "device-removed")
            return name + " device was removed";
        if (code === "action-failed")
            return name + " action failed";
        return code ? name + " action failed (" + code + ")" : name + " action failed";
    }

    function actionFailure(result, provider, name) {
        const code = result && result.code ? String(result.code) : "";
        if (["unavailable", "busy", "permission-denied", "stale", "timeout", "action-timeout", "device-removed", "action-failed"].indexOf(code) >= 0)
            return root.actionCodeMessage(name, code, provider);
        if (result && result.message)
            return String(result.message);
        return root.actionCodeMessage(name, code, provider);
    }

    function isProviderActionError(provider, code, reason) {
        if (code.length === 0 || code === reason)
            return false;
        if (provider === brightnessProvider)
            return code === "action-timeout" || code === "action-failed";
        return true;
    }

    function setActionError(message, provider, code) {
        actionError = message;
        actionErrorProvider = provider || null;
        actionErrorCode = String(code || "");
    }

    function clearActionError() {
        actionError = "";
        actionErrorProvider = null;
        actionErrorCode = "";
    }

    function syncPendingActionError(provider) {
        if (!provider)
            return;
        const status = root.providerStatus(provider);
        const code = String(status.errorCode || "");
        const reason = String((status.capability || ({ })).reason || "");

        if (provider === actionErrorProvider && status.busy !== true
                && code !== actionErrorCode && reason !== actionErrorCode)
            root.clearActionError();

        const remaining = [];
        for (let i = 0; i < pendingActions.length; i++) {
            const pending = pendingActions[i];
            if (pending.provider !== provider) {
                remaining.push(pending);
                continue;
            }

            if (root.isProviderActionError(provider, code, reason)) {
                root.setActionError(root.actionCodeMessage(pending.name, code, provider), provider, code);
                continue;
            }

            if (status.busy === true)
                remaining.push(pending);
        }
        pendingActions = remaining;
    }

    function runProviderAction(provider, operation, value, name) {
        root.clearActionError();
        if (!provider || typeof provider.action !== "function") {
            root.setActionError(root.reasonMessage(provider) || name + " provider is unavailable", provider, "unavailable");
            return false;
        }

        let result;
        try {
            result = provider.action(operation, value);
        } catch (error) {
            root.setActionError(String(error && error.message ? error.message : error), provider, "failed");
            return false;
        }
        if (!result || result.ok !== true) {
            const code = result && result.code ? String(result.code) : "failed";
            root.setActionError(root.actionFailure(result, provider, name), provider, code);
            return false;
        }

        const data = result.data || ({ });
        const status = root.providerStatus(provider);
        if (data.pending === true || status.busy === true)
            pendingActions = pendingActions.concat([{"provider": provider, "name": name}]);
        root.syncPendingActionError(provider);
        return true;
    }

    function heroIcon() {
        if (currentMode() === "audio")
            return audioIcon;

        if (currentMode() === "network")
            return wifiIcon;

        if (currentMode() === "bluetooth")
            return bluetoothIcon;

        if (currentMode() === "brightness")
            return brightnessIcon;

        return "󰁹";
    }

    function subtitle() {
        if (currentMode() === "network")
            return wifiText;

        if (currentMode() === "audio")
            return audioMuted ? "Muted" : visualAudioVolume + "%";

        if (currentMode() === "brightness")
            return visualBrightnessPercent + "% • " + (blueLightActive ? "Active" : "Inactive");

        if (currentMode() === "bluetooth")
            return body;

        return body;
    }

    function runCommand(command, keepOpen) {
        actionRequested(command, keepOpen);
    }

    function setNetworkEnabled(value) {
        return root.runProviderAction(root.networkProvider, "set-wifi", value === true ? "on" : "off", "Wi-Fi");
    }

    function setBluetoothEnabled(value) {
        return root.runProviderAction(root.bluetoothProvider, "set-enabled", value === true ? "on" : "off", "Bluetooth");
    }

    function toggleAudio() {
        return root.runProviderAction(root.audioProvider, "toggle-mute", "", "Audio");
    }

    function setMicMuted(value) {
        return root.runProviderAction(root.audioProvider, "set-mic", value ? "muted" : "open", "Microphone");
    }

    function applyAudio() {
        if (!audioCanChange)
            return ;
        audioApplyPending = false;
        return root.runProviderAction(root.audioProvider, "set-volume", String(visualAudioVolume), "Audio");
    }

    function queueAudio(value) {
        if (!audioCanChange)
            return ;
        visualAudioVolume = value;
        levelPreviewRequested("volume", value, audioMuted);
        audioApplyPending = true;
        audioSyncDelay.stop();
        if (!audioApplyDelay.running) {
            applyAudio();
            audioApplyDelay.restart();
        }
    }

    function finishAudio() {
        adjustingAudio = false;
        audioApplyDelay.stop();
        if (audioApplyPending)
            applyAudio();

        audioSyncDelay.restart();
    }

    function applyBrightness() {
        if (!brightnessCanChange)
            return ;
        brightnessApplyPending = false;
        return root.runProviderAction(root.brightnessProvider, "set", String(visualBrightnessPercent), "Brightness");
    }

    function queueBrightness(value) {
        if (!brightnessCanChange)
            return ;
        visualBrightnessPercent = value;
        levelPreviewRequested("brightness", value, false);
        brightnessApplyPending = true;
        brightnessSyncDelay.stop();
        if (!brightnessApplyDelay.running) {
            applyBrightness();
            brightnessApplyDelay.restart();
        }
    }

    function finishBrightness() {
        adjustingBrightness = false;
        brightnessApplyDelay.stop();
        if (brightnessApplyPending)
            applyBrightness();

        brightnessSyncDelay.restart();
    }

    onAudioVolumeChanged: {
        if (!adjustingAudio && !audioSyncDelay.running)
            visualAudioVolume = audioVolume;

    }
    onBrightnessPercentChanged: {
        if (!adjustingBrightness && !brightnessSyncDelay.running)
            visualBrightnessPercent = brightnessPercent;

    }
    onBlueLightModeChanged: visualBlueLightMode = blueLightMode

    audioApplyDelay: Timer {
        interval: 50
        repeat: false
        onTriggered: {
            if (root.audioApplyPending) {
                root.applyAudio();
                restart();
            }
        }
    }

    brightnessApplyDelay: Timer {
        interval: 50
        repeat: false
        onTriggered: {
            if (root.brightnessApplyPending) {
                root.applyBrightness();
                restart();
            }
        }
    }

    audioSyncDelay: Timer {
        interval: 250
        repeat: false
        onTriggered: root.visualAudioVolume = root.audioVolume
    }

    brightnessSyncDelay: Timer {
        interval: 250
        repeat: false
        onTriggered: root.visualBrightnessPercent = root.brightnessPercent
    }

    property Connections audioActionConnection: Connections {
        target: root.audioProvider
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncPendingActionError(root.audioProvider); }
    }

    property Connections networkActionConnection: Connections {
        target: root.networkProvider
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncPendingActionError(root.networkProvider); }
    }

    property Connections bluetoothActionConnection: Connections {
        target: root.bluetoothProvider
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncPendingActionError(root.bluetoothProvider); }
    }

    property Connections brightnessActionConnection: Connections {
        target: root.brightnessProvider
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncPendingActionError(root.brightnessProvider); }
    }

}
