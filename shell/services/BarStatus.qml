import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string scriptRoot: ""
    property bool barVisible: true
    property string openPanel: ""
    property bool performanceVisible: false
    property alias workspaces: workspaces
    property alias system: systemInfo
    property alias todo: todo
    property alias updates: updates
    property alias battery: battery
    property alias powerProfile: powerProfile
    property alias vendorPerformance: vendorPerformance
    property alias gpu: gpu
    property alias audio: audio
    property alias brightness: brightness
    property alias network: network
    property alias bluetooth: bluetooth
    property alias touchpad: touchpad
    property alias privacy: privacy
    property alias caffeine: caffeine

    function pluggedIn() {
        const value = battery.json || {
        };
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
        privacy.refresh();
        battery.refresh();
        powerProfile.refresh();
        caffeine.refresh();
    }

    function refreshPerformance() {
        systemInfo.refresh();
        battery.refresh();
        powerProfile.refresh();
        vendorPerformance.refresh();
        gpu.refresh();
    }

    function updatePolling(refreshVisible) {
        const shouldRefresh = refreshVisible === undefined ? true : refreshVisible;
        const controlPanels = ["audio", "network", "bluetooth", "brightness", "notifications", "privacy"];
        const controlsVisible = controlPanels.indexOf(openPanel) >= 0;
        audio.interval = controlsVisible ? 2000 : railInterval(30000, 15000, 120000, 60000);
        brightness.interval = controlsVisible ? 2000 : 30000;
        bluetooth.interval = controlsVisible ? 2000 : 30000;
        network.interval = controlsVisible ? 2000 : railInterval(30000, 15000, 120000, 60000);
        touchpad.interval = controlsVisible ? 2000 : 15000;
        vendorPerformance.interval = performanceVisible ? 2000 : 60000;
        gpu.interval = performanceVisible ? 2000 : 60000;
        privacy.interval = controlsVisible ? 5000 : 30000;
        caffeine.interval = openPanel === "caffeine" ? 1000 : caffeine.json.active ? 5000 : 30000;
        workspaces.interval = railInterval(300000, 120000, 600000, 300000);
        systemInfo.interval = performanceVisible ? 1000 : 60000;
        battery.interval = performanceVisible ? 1000 : railInterval(30000, 15000, 60000, 30000);
        powerProfile.interval = performanceVisible ? 1000 : 60000;
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

    ScriptPoller {
        id: workspaces

        command: [root.scriptRoot + "/workspaces/status.py"]
        interval: 300000
    }

    ScriptPoller {
        id: systemInfo

        command: [root.scriptRoot + "/status/system.sh"]
        interval: 60000
    }

    ScriptPoller {
        id: todo

        command: [root.scriptRoot + "/todo/status.sh"]
        interval: 60000
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

        interval: 60000
    }

    AudioStatus {
        id: audio

        scriptRoot: root.scriptRoot
        interval: 30000
    }

    BrightnessStatus {
        id: brightness

        scriptRoot: root.scriptRoot
        interval: 30000
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
        interval: 15000
    }

    VendorPerformanceStatus {
        id: vendorPerformance

        scriptRoot: root.scriptRoot
        interval: 60000
    }

    GpuStatus {
        id: gpu

        scriptRoot: root.scriptRoot
        interval: 60000
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

    ScriptPoller {
        id: privacy

        command: [root.scriptRoot + "/status/privacy.py"]
        interval: 30000
    }

    ScriptPoller {
        id: caffeine

        command: [root.scriptRoot + "/status/caffeine.sh"]
        interval: 30000
    }

}
