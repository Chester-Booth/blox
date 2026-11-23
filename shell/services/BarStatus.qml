import Blox.Services 1.0
import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property var settingsController: null

    property string scriptRoot: ""
    property bool barVisible: true
    property string openPanel: ""
    property bool performanceVisible: false
    property alias workspaces: bloxDaemon.workspaces
    property alias system: bloxDaemon.system
    property alias todo: todo
    property alias updates: updates
    property alias battery: battery
    property alias powerProfile: powerProfile
    property alias vendorPerformance: vendorPerformance
    property alias gpu: gpu
    property alias monitors: monitors
    property alias audio: audio
    property alias brightness: brightness
    property alias network: network
    property alias bluetooth: bluetooth
    property alias touchpad: touchpad
    property alias privacy: privacy
    property alias caffeine: bloxDaemon.caffeine

    function pluggedIn() {
        const value = battery.json || ({});
        return value.class === "charging" || value.class === "plugged";
    }

    function railInterval(batteryVisible, acVisible, batteryHidden, acHidden) {
        if (barVisible)
            return pluggedIn() ? acVisible : batteryVisible;

        return pluggedIn() ? acHidden : batteryHidden;
    }

    function refreshControl() {
        audio.refresh();
        brightness.refresh();
        bluetooth.refresh();
        network.refresh();
        touchpad.refresh();
        vendorPerformance.refresh();
        gpu.refresh();
        monitors.refresh();
        privacy.refresh();
        battery.refresh();
        powerProfile.refresh();
        caffeine.refresh();
    }

    function refreshPerformance() {
        system.refresh();
        battery.refresh();
        powerProfile.refresh();
        vendorPerformance.refresh();
        gpu.refresh();
        monitors.refresh();
    }

    function updatePolling(refreshVisible) {
        const shouldRefresh = refreshVisible === undefined ? true : refreshVisible;
        const controlPanels = ["audio", "network", "bluetooth", "brightness", "notifications", "privacy"];
        const controlsVisible = controlPanels.indexOf(openPanel) >= 0;
        // Native D-Bus / PipeWire providers do not fork subprocesses.
        audio.interval = controlsVisible ? 2000 : railInterval(30000, 15000, 120000, 60000);
        network.interval = controlsVisible ? 2000 : railInterval(30000, 15000, 120000, 60000);
        bluetooth.interval = controlsVisible ? 2000 : 30000;
        battery.interval = performanceVisible ? 1000 : railInterval(30000, 15000, 60000, 30000);
        powerProfile.interval = performanceVisible ? 2000 : 0;

        // Script-backed providers stay quiet when closed (0 = startup + event/action only).
        brightness.interval = controlsVisible ? 2000 : 0;
        touchpad.interval = controlsVisible ? 2000 : 0;
        vendorPerformance.interval = performanceVisible ? 15000 : 0;
        gpu.interval = performanceVisible ? 15000 : 0;
        monitors.interval = performanceVisible ? 15000 : 0;
        todo.interval = openPanel === "todo" ? 60000 : 0;

        // Rust daemon handles system telemetry in-process with zero forks.
        bloxDaemon.setSystemInterval(performanceVisible ? 1000 : 0);

        if (shouldRefresh && controlsVisible)
            refreshControl();

        if (shouldRefresh && performanceVisible)
            refreshPerformance();

        if (shouldRefresh && openPanel === "caffeine")
            caffeine.refresh();

        if (shouldRefresh && openPanel === "todo")
            todo.refresh();
        else if (shouldRefresh && openPanel === "updates")
            updates.refresh();
    }

    onBarVisibleChanged: updatePolling()
    onOpenPanelChanged: updatePolling()
    onPerformanceVisibleChanged: updatePolling()
    Component.onCompleted: updatePolling()

    BloxDaemon {
        id: bloxDaemon
        onMonitorEvent: monitors.refresh()
    }

    Timer {
        id: caffeineCountdownTimer
        interval: root.openPanel === "caffeine" ? 1000 : 5000
        repeat: true
        running: root.openPanel === "caffeine" || (bloxDaemon.caffeine.json && bloxDaemon.caffeine.json.active === true && bloxDaemon.caffeine.json.mode !== "indefinite")
        onTriggered: bloxDaemon.caffeine.refresh()
    }

    ScriptPoller {
        id: todo
        command: [root.scriptRoot + "/todo/status.sh"]
        interval: 0
    }

    ScriptPoller {
        id: updates
        command: [root.scriptRoot + "/update/status.sh"]
        interval: 3.6e+06
        timeout: 155000
    }

    PowerStatus {
        id: battery

        interval: 30000
        onJsonChanged: root.updatePolling(false)
    }

    PowerProfileStatus {
        id: powerProfile
        batteryStatus: battery.json
        policy: root.settingsController && root.settingsController.settings ? root.settingsController.settings.power : null

        interval: 0
    }

    AudioStatus {
        id: audio

        scriptRoot: root.scriptRoot
        interval: 30000
    }

    BrightnessStatus {
        id: brightness

        scriptRoot: root.scriptRoot
        interval: 0
    }

    NetworkStatus {
        id: network

        interval: 30000
    }

    BluetoothStatus {
        id: bluetooth

        interval: 30000
    }

    TouchpadStatus {
        id: touchpad

        scriptRoot: root.scriptRoot
        interval: 0
    }

    VendorPerformanceStatus {
        id: vendorPerformance

        scriptRoot: root.scriptRoot
        interval: 0
    }

    GpuStatus {
        id: gpu

        scriptRoot: root.scriptRoot
        interval: 0
    }

    MonitorStatus {
        id: monitors

        scriptRoot: root.scriptRoot
        interval: 0
    }

    FileView {
        path: {
            const runtimeDirectory = Quickshell.env("XDG_RUNTIME_DIR");
            return (runtimeDirectory || Quickshell.env("HOME") + "/.cache") + "/quickshell-touchpad-enabled";
        }
        watchChanges: true
        printErrors: false
        onFileChanged: touchpad.refresh()
    }

    NativePrivacyMonitor {
        id: privacy
    }
}
