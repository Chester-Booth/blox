import QtQuick

// Pure UPower projection. The native adapter supplies primitive values so
// battery, AC-only and service-loss states stay deterministic in tests.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool batteryPresent: false
    property bool linePowerPresent: false
    property bool onBattery: false
    property real percentage: 0
    property string batteryState: "unknown"
    property real timeToEmpty: 0
    property real timeToFull: 0
    property string batteryModel: ""
    property string batteryPath: ""
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady
    property var json: ({
    })

    function clampedPercentage() {
        if (!root.batteryPresent)
            return "";
        const value = Number(root.percentage);
        if (!isFinite(value))
            return 0;
        return Math.max(0, Math.min(100, Math.round(value)));
    }

    function durationLabel(minutes, suffix) {
        const value = Number(minutes);
        if (!isFinite(value) || value <= 0)
            return "N/A";
        const totalMinutes = Math.max(1, Math.round(value / 60));
        const hours = Math.floor(totalMinutes / 60);
        const remaining = totalMinutes % 60;
        const label = hours > 0 ? hours + "h " + remaining + "m" : remaining + "m";
        return label + suffix;
    }

    function batteryIcon(state, capacity) {
        if (state === "charging") {
            const chargingIcons = ["󰢟", "󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"];
            return chargingIcons[Math.min(10, Math.floor(capacity / 10))];
        }
        if (["fully-charged", "not-charging"].indexOf(state) >= 0)
            return "󰂅";
        if (capacity <= 10)
            return "󰂃";
        const normalIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"];
        return normalIcons[Math.min(9, Math.floor(capacity / 10))];
    }

    function capability() {
        let reason = null;
        let permission = "not-required";
        if (!root.providerReady) {
            reason = "provider-not-ready";
            permission = "unknown";
        } else if (!root.syncReady) {
            reason = "provider-loading";
            permission = "unknown";
        }
        return {
            "available": root.providerReady,
            "ready": root.providerReady && root.syncReady,
            "canChange": false,
            "permission": permission,
            "reason": reason
        };
    }

    function buildStatus() {
        const capability = root.capability();
        let icon = "󰚥";
        let statusClass = "unavailable";
        let status = "Unknown";
        let timeLabel = "N/A";
        let tooltip = "Power provider unavailable";
        let source = "unknown";
        const capacity = root.clampedPercentage();

        if (root.providerReady && !root.syncReady) {
            statusClass = "loading";
            status = "Loading";
            tooltip = "Waiting for UPower";
        } else if (root.ready && root.batteryPresent) {
            const value = Number(capacity);
            const state = root.batteryState;
            icon = root.batteryIcon(state, value);
            statusClass = state === "charging" ? "charging" : state === "fully-charged" || state === "not-charging" ? "plugged" : value <= 10 ? "critical" : "normal";
            status = state === "charging" ? "Charging" : state === "discharging" ? "Discharging" : state === "fully-charged" ? "Fully charged" : state === "not-charging" ? "Not charging" : "Unknown";
            timeLabel = state === "charging" ? root.durationLabel(root.timeToFull, " to full") : state === "discharging" ? root.durationLabel(root.timeToEmpty, " left") : state === "fully-charged" || state === "not-charging" ? "Full" : "N/A";
            tooltip = "Charge: " + capacity + "%\n" + status + "\n" + timeLabel;
            if (root.batteryModel.length > 0)
                tooltip += "\n" + root.batteryModel;
            source = root.onBattery ? "battery" : "ac";
        } else if (root.ready && root.linePowerPresent) {
            icon = "󰂅";
            statusClass = "plugged";
            status = "AC power";
            timeLabel = "Plugged in";
            tooltip = "AC power\nNo battery detected";
            source = "ac";
        } else if (root.ready) {
            status = "No power source";
            tooltip = "No battery or AC source detected";
        }

        if (root.actionError.length > 0)
            tooltip += "\nAction error: " + root.actionError;
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": false,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "icon": icon,
            "class": statusClass,
            "capacity": capacity,
            "status": status,
            "timeLabel": timeLabel,
            "source": source,
            "onBattery": root.onBattery,
            "batteryPresent": root.batteryPresent,
            "batteryModel": root.batteryModel,
            "tooltip": tooltip,
            "capability": capability
        };
    }

    function markChanged() {
        root.revision += 1;
        root.observedAtMs = Date.now();
        root.json = root.buildStatus();
    }

    onProviderReadyChanged: root.markChanged()
    onSyncReadyChanged: root.markChanged()
    onBatteryPresentChanged: root.markChanged()
    onLinePowerPresentChanged: root.markChanged()
    onOnBatteryChanged: root.markChanged()
    onPercentageChanged: root.markChanged()
    onBatteryStateChanged: root.markChanged()
    onTimeToEmptyChanged: root.markChanged()
    onTimeToFullChanged: root.markChanged()
    onBatteryModelChanged: root.markChanged()
    onBatteryPathChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
