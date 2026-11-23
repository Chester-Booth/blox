import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property var settingsController: null

    property int caffeineObservationRevision: 0
    property string scriptRoot: ""
    property bool barVisible: true
    property string openPanel: ""
    property bool batteryExpanded: false
    property bool clockDateMode: false
    property alias status: barStatus
    property alias actions: barActions
    property alias content: barContent
    property alias workspaces: barStatus.workspaces
    property alias systemInfo: barStatus.system
    property alias todo: barStatus.todo
    property alias updates: barStatus.updates
    property alias battery: barStatus.battery
    property alias powerProfile: barStatus.powerProfile
    property alias vendorPerformance: barStatus.vendorPerformance
    property alias gpu: barStatus.gpu
    property alias monitors: barStatus.monitors
    property alias audio: barStatus.audio
    property alias brightness: barStatus.brightness
    property alias network: barStatus.network
    property alias bluetooth: barStatus.bluetooth
    property alias touchpad: barStatus.touchpad
    property alias privacy: barStatus.privacy
    property alias caffeine: barStatus.caffeine
    property alias calendarController: calendarController
    readonly property date now: clock.date

    function caffeineStatus() {
        const result = barActions.caffeineResult;
        const actionObserved = result.data && Number(result.data.observedAtMs || 0);
        return Object.assign({}, root.caffeine.json, {
            schemaVersion: 1,
            providerRevision: root.caffeineObservationRevision + barActions.caffeineRevision,
            observedAtMs: Math.max(root.caffeine.lastUpdatedMs, actionObserved || 0),
            stale: !root.caffeine.ok || root.caffeine.lastUpdatedMs === 0,
            busy: barActions.caffeineBusy,
            errorCode: result.ok === false ? result.code : root.caffeine.timedOut ? "timeout" : !root.caffeine.ok ? "failed" : null,
            lastAction: result
        });
    }

    Connections {
        target: root.caffeine
        function onJsonChanged() { root.caffeineObservationRevision += 1; }
    }

    function run(command) {
        barActions.run(command);
    }

    function runArgs(args) {
        barActions.runArgs(args);
    }

    function runPerformance(command) {
        barActions.runPerformance(command);
    }

    function runPower(command) {
        barActions.runPower(command);
    }

    function setPerformancePolling(visible) {
        barStatus.performanceVisible = visible;
    }

    function updateIcon() {
        return barContent.updateIcon();
    }

    function railClockText(horizontal) {
        return barContent.railClockText(horizontal);
    }

    function statusSnapshot() {
        return barContent.statusSnapshot();
    }

    function audioAction(operation, value) {
        return audio.action(operation, value);
    }

    function networkAction(operation, value) {
        return network.action(operation, value);
    }

    function bluetoothAction(operation, value) {
        return bluetooth.action(operation, value);
    }

    function gpuAction(operation, value) {
        return gpu.action(operation, value);
    }

    function monitorAction(operation, monitor, rate) {
        return monitors.action(operation, monitor, rate);
    }

    function previousTodo() {
        run(scriptRoot + "/todo/cycle.sh -1");
        todoRefreshDelay.restart();
    }

    function nextTodo() {
        run(scriptRoot + "/todo/cycle.sh 1");
        todoRefreshDelay.restart();
    }

    function statusError(panel) {
        if (panel === "system") {
            const systemPollers = [systemInfo, vendorPerformance, gpu];
            for (const candidate of systemPollers) {
                if (candidate && !candidate.ok)
                    return candidate.lastError;
            }
            return "";
        }
        const pollers = {
            "audio": audio,
            "network": network,
            "bluetooth": bluetooth,
            "brightness": brightness,
            "privacy": privacy,
            "caffeine": caffeine,
            "updates": updates,
            "todo": todo,
            "system": systemInfo
        };
        const poller = pollers[panel];
        return poller && !poller.ok ? poller.lastError : "";
    }

    NightLightStatus { id: nightLightOwner; scriptRoot: root.scriptRoot }

    BarStatus {
        id: barStatus
        settingsController: root.settingsController

        scriptRoot: root.scriptRoot
        barVisible: root.barVisible
        openPanel: root.openPanel
    }

    BarActions {
        id: barActions

        scriptRoot: root.scriptRoot
        onControlRefreshRequested: barStatus.refreshControl()
        onPerformanceRefreshRequested: barStatus.refreshPerformance()
        onTodoRefreshRequested: todoRefreshDelay.restart()
    }

    CalendarController {
        id: calendarController

        scriptRoot: root.scriptRoot
    }

    BarContent {
        id: barContent

        openPanel: root.openPanel
        scriptRoot: root.scriptRoot
        now: clock.date
        clockDateMode: root.clockDateMode
        updates: root.updates.json
        battery: root.battery.json
        powerProfile: root.powerProfile.json
        vendorPerformance: root.vendorPerformance.json
        gpu: root.gpu.json
        monitors: root.monitors.json
        touchpad: root.touchpad.json
        updatesLastUpdatedMs: root.updates.lastUpdatedMs
        bluetooth: root.bluetooth.json
        audio: root.audio.json
        brightness: root.brightness.json
        network: root.network.json
        privacy: root.privacy.json
        caffeine: root.caffeineStatus()
    }

    MediaKeyController {
        audio: root.audio
        brightness: root.brightness
    }

    IpcHandler {
        function status() : string {
            return JSON.stringify(root.statusSnapshot());
        }

        function audio(operation: string, value: string) : string {
            return JSON.stringify(root.audioAction(operation, value));
        }

        function network(operation: string, value: string) : string {
            return JSON.stringify(root.networkAction(operation, value));
        }

        function bluetooth(operation: string, value: string) : string {
            return JSON.stringify(root.bluetoothAction(operation, value));
        }

        function gpu(operation: string, value: string) : string {
            return JSON.stringify(root.gpuAction(operation, value));
        }

        function monitor(operation: string, monitor: string, rate: string) : string {
            return JSON.stringify(root.monitorAction(operation, monitor, rate));
        }

        function brightness(operation: string, value: string) : string {
            return JSON.stringify(root.brightness.action(operation, value));
        }

        function touchpad(operation: string, value: string) : string {
            return JSON.stringify(root.touchpad.action(operation, value));
        }

        function vendor(operation: string, value: string) : string {
            return JSON.stringify(root.vendorPerformance.action(operation, value));
        }

        function powerProfile(operation: string, value: string) : string {
            return JSON.stringify(root.powerProfile.action(operation, value));
        }

        function caffeine(operation: string, value: string) : string {
            return JSON.stringify(operation === "set" ? barActions.runCaffeine(value) :
                barActions.actionResult(false, "invalid-data", "Unknown Awake operation", null));
        }

        function nightLight(operation: string, value: string) : string {
            return JSON.stringify(nightLightOwner.action(operation, value));
        }

        target: "blox"
    }

    Timer {
        id: todoRefreshDelay

        interval: 120
        repeat: false
        onTriggered: barStatus.todo.refresh()
    }

    SystemClock {
        id: clock

        enabled: root.barVisible || root.openPanel === "calendar" || root.openPanel === "updates"
        precision: SystemClock.Minutes
    }

}
