import QtQuick

QtObject {
    id: root

    property string mode: ""
    property string title: ""
    property string body: ""
    property string statusError: ""
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

        if (item.id === "mic-toggle" && root.setMicMuted(!root.micMuted))
            return ;

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
        if (!networkCanChange || !root.networkProvider)
            return false;
        return root.networkProvider.setWifiEnabled(value === true);
    }

    function setBluetoothEnabled(value) {
        if (!bluetoothCanChange || !root.bluetoothProvider)
            return false;
        return root.bluetoothProvider.setBluetoothEnabled(value === true);
    }

    function toggleAudio() {
        if (!audioCanChange)
            return ;

        if (root.audioProvider && root.audioProvider.toggleMute())
            return ;

        runCommand(scriptRoot + "/control.sh audio-toggle", true);
    }

    function setMicMuted(value) {
        if (!micCanChange)
            return false;

        if (root.audioProvider && root.audioProvider.setMicMuted(value))
            return true;

        runCommand(scriptRoot + "/control.sh mic " + (value ? "muted" : "open"), true);
        return true;
    }

    function applyAudio() {
        if (!audioCanChange)
            return ;
        audioApplyPending = false;
        if (root.audioProvider && root.audioProvider.setVolume(visualAudioVolume))
            return ;

        runCommand(scriptRoot + "/control.sh audio-set-silent " + visualAudioVolume, true);
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
        runCommand(scriptRoot + "/control.sh brightness-set-silent " + visualBrightnessPercent, true);
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

}
