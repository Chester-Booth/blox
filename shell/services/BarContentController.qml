import "."
import QtQuick
import Quickshell

Scope {
    id: root

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
    property alias audio: barStatus.audio
    property alias brightness: barStatus.brightness
    property alias network: barStatus.network
    property alias bluetooth: barStatus.bluetooth
    property alias touchpad: barStatus.touchpad
    property alias privacy: barStatus.privacy
    property alias caffeine: barStatus.caffeine
    property alias calendarController: calendarController
    readonly property date now: clock.date

    function run(command) {
        barActions.run(command);
    }

    function runArgs(args) {
        barActions.runArgs(args);
    }

    function runPerformance(command) {
        barActions.runPerformance(command);
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

    function previousTodo() {
        run(scriptRoot + "/todo/cycle.sh -1");
        todoRefreshDelay.restart();
    }

    function nextTodo() {
        run(scriptRoot + "/todo/cycle.sh 1");
        todoRefreshDelay.restart();
    }

    function statusError(panel) {
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

    BarStatus {
        id: barStatus

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
        updatesLastUpdatedMs: root.updates.lastUpdatedMs
        bluetooth: root.bluetooth.json
        audio: root.audio.json
        brightness: root.brightness.json
        network: root.network.json
        privacy: root.privacy.json
        caffeine: root.caffeine.json
    }

    IpcHandler {
        function status() : string {
            return JSON.stringify(root.statusSnapshot());
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

        precision: SystemClock.Seconds
    }

}
