import "../shared"
import QtQuick
import Quickshell
import Quickshell.Io

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
    property double volumePreviewUntil: 0
    readonly property bool volumeOverdriven: label === "Volume" && !muted && value > 100
    readonly property int fillValue: Math.max(0, Math.min(100, value))

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
        const id = String(mode || "eco").toLowerCase();
        label = "GPU mode";
        muted = false;
        noticeMode = false;
        segmented = true;
        segments = 4;
        if (id === "gaming") {
            activeSegments = 4;
            icon = "󰪫";
            valueText = "GPU 144";
        } else if (id === "performance") {
            activeSegments = 3;
            icon = "󰢮";
            valueText = "GPU 60";
        } else if (id === "high-refresh") {
            activeSegments = 2;
            icon = "";
            valueText = "iGPU 144";
        } else {
            activeSegments = 1;
            icon = "󰌪";
            valueText = "iGPU 60";
        }
        value = Math.round(activeSegments * 100 / segments);
        showFor(4500);
    }

    function showFan(profile) {
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
        if (kind === "volume")
            volumePreviewUntil = Date.now() + 300;

        show(kind, percent, isMuted);
    }

    function showNotice(title, message, iconName, level, durationMs) {
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

    Timer {
        id: restartKeyboardWatcher

        interval: 2000
        repeat: false
        onTriggered: keyboardWatcher.running = true
    }

    Timer {
        id: restartAudioWatcher

        interval: 2000
        repeat: false
        onTriggered: audioWatcher.running = true
    }

    Process {
        id: audioWatcher

        command: [root.scriptRoot + "/osd/watch-audio.sh"]
        running: true
        onExited: (exitCode) => {
            if (exitCode !== 0)
                restartAudioWatcher.restart();

        }
        Component.onDestruction: {
            if (running)
                signal(15);

        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: (data) => {
                let event = {
                };
                try {
                    event = JSON.parse(data.trim());
                } catch (error) {
                    return ;
                }
                if (Date.now() >= root.volumePreviewUntil)
                    root.show("volume", event.volume, event.muted);

            }
        }

    }

    Process {
        id: keyboardWatcher

        command: [root.scriptRoot + "/osd/watch-keyboard-backlight.sh"]
        running: true
        onExited: (exitCode) => {
            if (exitCode !== 0)
                restartKeyboardWatcher.restart();

        }
        Component.onDestruction: {
            if (running)
                signal(15);

        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: (data) => {
                let event = {
                };
                try {
                    event = JSON.parse(data.trim());
                } catch (error) {
                    return ;
                }
                const max = parseInt(event.max) || 0;
                const value = parseInt(event.value) || 0;
                if (max > 0)
                    root.show("keyboard", Math.round(value * 100 / max), false);

            }
        }

    }

}
