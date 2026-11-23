import qs.shared
import QtQuick
import Quickshell
import Blox.Services 1.0

Scope {
    id: root

    property string label: "Volume"
    property string icon: "󰕾"
    property int value: 0
    property bool muted: false
    property string valueText: "0%"
    property bool showing: false
    property bool rendered: false
    property string scriptRoot: Quickshell.shellDir + "/scripts"
    property bool segmented: false
    property int segments: 3
    property int activeSegments: 0
    property bool noticeMode: false
    property color noticeAccent: Theme.blue
    property var audioStatus: null
    property var observedAudioSink: null
    property var observedAudioVolume: null
    property bool observedAudioMuted: false
    readonly property bool volumeOverdriven: label === "Volume" && !muted && value > 100
    readonly property int fillValue: Math.max(0, Math.min(100, value))

    // Remember only enough to detect output changes. Values always come from
    // the bar's shared native owner, including reconciliation after a preview.
    function audioObservation() {
        const owner = root.audioStatus;
        const status = owner && owner.json;
        const capability = status && status.capability;
        const sink = owner && owner.sink;
        if (!owner || owner.providerReady !== true || !sink || !status || !capability
            || capability.available !== true || capability.ready !== true || capability.canChange !== true
            || capability.permission === "denied" || status.stale === true || status.busy === true || status.errorCode)
            return null;
        const volume = status.volume;
        if (typeof volume !== "number" || !isFinite(volume) || volume < 0 || Math.round(volume) !== volume
            || typeof status.muted !== "boolean")
            return null;
        return {sink: sink, volume: volume, muted: status.muted};
    }

    function cancelAudioPreview(hide) {
        const active = audioPreviewDelay.running;
        // Consume queued observations while the preview still suppresses them.
        // An explicit show must not be replaced by an already queued change.
        if (active && !hide)
            root.observeAudio();
        audioPreviewDelay.stop();
        if (hide && active && root.label === "Volume") {
            root.showing = false;
            hideFinish.restart();
        }
    }

    function resetAudioObservation() {
        root.observedAudioSink = null;
        root.observedAudioVolume = null;
        root.cancelAudioPreview(true);
    }

    function observeAudio(reconcile) {
        const current = root.audioObservation();
        if (!current) {
            root.resetAudioObservation();
            if (reconcile === true && root.label === "Volume") {
                root.showing = false;
                hideFinish.restart();
            }
            return;
        }
        const baseline = root.observedAudioVolume === null || root.observedAudioSink !== current.sink;
        const changed = !baseline && (root.observedAudioVolume !== current.volume || root.observedAudioMuted !== current.muted);
        root.observedAudioSink = current.sink;
        root.observedAudioVolume = current.volume;
        root.observedAudioMuted = current.muted;
        if (!baseline && !audioPreviewDelay.running && (changed || reconcile === true))
            root.show("volume", current.volume, current.muted);
    }

    function queueAudioObservation() {
        if (!root.audioObservation())
            root.resetAudioObservation();
        // Let the owner's sink identity and status bindings settle together.
        Qt.callLater(root.observeAudio);
    }

    onAudioStatusChanged: {
        root.resetAudioObservation();
        root.queueAudioObservation();
    }
    Component.onCompleted: root.queueAudioObservation()

    Connections {
        target: root.audioStatus
        function onJsonChanged() { root.queueAudioObservation(); }
        function onSinkChanged() {
            root.resetAudioObservation();
            root.queueAudioObservation();
        }
        function onProviderReadyChanged() {
            root.resetAudioObservation();
            root.queueAudioObservation();
        }
    }

    Timer {
        id: audioPreviewDelay
        interval: 300
        repeat: false
        onTriggered: root.observeAudio(true)
    }

    function clamp(percent) {
        return Math.max(0, Math.min(100, parseInt(percent) || 0));
    }

    function iconForKeyboardLevel(level) {
        if (level <= 0)
            return "󰹐";

        if (level === 1)
            return "󱩐";

        if (level === 2)
            return "󱩓";

        return "󰛨";
    }

    function showFor(durationMs) {
        hideDelay.interval = Math.max(500, parseInt(durationMs) || 1200);
        rendered = true;
        showing = true;
        hideFinish.stop();
        hideDelay.restart();
    }

    function showBlueLight(mode, active) {
        root.cancelAudioPreview(false);
        const id = String(mode || "auto").toLowerCase();
        const isActive = active === true || active === "true" || active === "yes" || active === "1";
        label = "Blue light";
        muted = false;
        segmented = false;
        noticeMode = true;
        noticeAccent = Theme.blue;
        if (id === "off" || id === "disable" || id === "disabled") {
            icon = "󰃞";
            value = 0;
            valueText = "";
        } else if (id === "on") {
            icon = "󰖔";
            value = 100;
            valueText = "";
        } else {
            icon = "󰖙";
            value = isActive ? 100 : 0;
            valueText = "Auto";
        }
        showFor(1200);
    }

    function showGpu(mode) {
        root.cancelAudioPreview(false);
        const id = String(mode || "integrated").toLowerCase();
        label = "GPU mode";
        muted = false;
        noticeMode = false;
        segmented = true;
        segments = 3;
        if (id === "dedicated") {
            activeSegments = 3;
            icon = "󰢮";
            valueText = "Dedicated";
        } else if (id === "hybrid") {
            activeSegments = 2;
            icon = "󰾅";
            valueText = "Hybrid";
        } else {
            activeSegments = 1;
            icon = "󰌪";
            valueText = "Integrated";
        }
        value = Math.round(activeSegments * 100 / segments);
        showFor(4500);
    }

    function showFan(profile) {
        root.cancelAudioPreview(false);
        const id = String(profile || "balanced").toLowerCase();
        label = "Fan profile";
        muted = false;
        noticeMode = false;
        segmented = true;
        segments = 3;
        if (id === "quiet") {
            activeSegments = 1;
            icon = "󰠝";
            valueText = "Quiet";
        } else if (id === "performance") {
            activeSegments = 3;
            icon = "󱑬";
            valueText = "Performance";
        } else {
            activeSegments = 2;
            icon = "󱜝";
            valueText = "Balanced";
        }
        value = Math.round(activeSegments * 100 / segments);
        showFor(1200);
    }

    function show(kind, percent, isMuted) {
        root.cancelAudioPreview(false);
        noticeAccent = Theme.blue;
        noticeMode = false;
        value = kind === "volume" ? Math.max(0, parseInt(percent) || 0) : clamp(percent);
        muted = isMuted === true || isMuted === "true" || isMuted === "yes" || isMuted === "1";
        segmented = false;
        segments = 3;
        activeSegments = Math.round(value * segments / 100);
        if (kind === "brightness") {
            label = "Brightness";
            icon = "󰃠";
            valueText = value + "%";
        } else if (kind === "keyboard") {
            label = "Keyboard Backlight";
            segmented = true;
            activeSegments = Math.max(0, Math.min(segments, Math.round(value * segments / 100)));
            icon = iconForKeyboardLevel(activeSegments);
            valueText = "";
        } else if (kind === "camera") {
            label = "Camera";
            icon = muted ? "󰗟" : "󰄀";
            valueText = muted ? "Off" : "On";
        } else if (kind === "touchpad") {
            label = "Touchpad";
            icon = muted ? "󰤳" : "󰟸";
            valueText = muted ? "Off" : "On";
        } else if (kind === "caps") {
            label = "Caps Lock";
            icon = muted ? "󰬶" : "󰬵";
            valueText = muted ? "On" : "Off";
        } else if (kind === "mic") {
            label = "Microphone";
            icon = muted ? "󰍭" : "󰍬";
            valueText = muted ? "Muted" : "Unmuted";
        } else {
            label = "Volume";
            icon = muted ? "󰝟" : value > 100 ? "󰝝" : value < 35 ? "󰕿" : value < 70 ? "󰖀" : "󰕾";
            valueText = muted ? "Muted" : value + "%";
        }
        showFor(1200);
    }

    function preview(kind, percent, isMuted) {
        show(kind, percent, isMuted);
        if (kind === "volume")
            audioPreviewDelay.restart();
    }

    function showNotice(title, message, iconName, level, durationMs) {
        root.cancelAudioPreview(false);
        label = title || "Status";
        icon = iconName || "󰋼";
        valueText = message || "";
        value = 100;
        muted = false;
        segmented = false;
        noticeMode = true;
        noticeAccent = level === "error" || level === "critical" ? Theme.red : level === "warning" ? Theme.yellow : Theme.blue;
        showFor(durationMs);
    }

    Connections {
        function onOsdPositionPreviewRequested() {
            root.showNotice("OSD position", "Previewing the selected position", "󰍹", "info", 1400);
        }

        target: Theme
    }

    Timer {
        id: hideDelay

        interval: 1200
        repeat: false
        onTriggered: {
            root.showing = false;
            hideFinish.restart();
        }
    }

    Timer {
        id: hideFinish

        interval: 190
        repeat: false
        onTriggered: {
            if (!root.showing)
                root.rendered = false;

        }
    }

    KeyboardBacklightWatcher {
        onLevelChanged: (value, maximum) => {
            root.show("keyboard", Math.round(value * 100 / maximum), false);
        }
    }

}
