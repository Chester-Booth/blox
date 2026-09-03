import QtQuick
import Quickshell
import Quickshell.Services.UPower

// Native UPower adapter. It only reads power state; optional action owners for
// profiles and display devices remain separate from this battery projection.
Scope {
    id: root

    property var upowerService: UPower
    property int interval: 30000
    property bool syncReady: false
    property string actionError: ""
    readonly property bool providerReady: root.upowerService !== null
    readonly property var deviceValues: root.upowerService && root.upowerService.devices && root.upowerService.devices.values ? root.upowerService.devices.values : []
    readonly property var displayDevice: root.upowerService ? root.upowerService.displayDevice : null
    readonly property var batteryDevice: root.displayDevice && root.displayDevice.isPresent === true ? root.displayDevice : root.findDevice(UPowerDeviceType.Battery)
    readonly property var linePowerDevice: root.findDevice(UPowerDeviceType.LinePower)
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError
    property var json: ({
    })

    function findDevice(type) {
        const devices = root.deviceValues;
        for (let i = 0; i < devices.length; i++) {
            if (devices[i] && devices[i].type === type && devices[i].isPresent !== false)
                return devices[i];
        }
        return null;
    }

    function stateName(device) {
        if (!device)
            return "unknown";
        if (device.state === UPowerDeviceState.Charging)
            return "charging";
        if (device.state === UPowerDeviceState.Discharging)
            return "discharging";
        if (device.state === UPowerDeviceState.FullyCharged)
            return "fully-charged";
        if (device.state === UPowerDeviceState.PendingCharge)
            return "pending-charge";
        if (device.state === UPowerDeviceState.PendingDischarge)
            return "pending-discharge";
        if (device.state === UPowerDeviceState.Empty)
            return "empty";
        return "not-charging";
    }

    function percentage(device) {
        if (!device)
            return 0;
        const value = Number(device.percentage || 0);
        return value >= 0 && value <= 1 ? value * 100 : value;
    }

    function refresh() {
        state.markChanged();
    }

    PowerState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        batteryPresent: root.batteryDevice !== null
        linePowerPresent: root.linePowerDevice !== null
        onBattery: root.upowerService ? root.upowerService.onBattery === true : false
        percentage: root.percentage(root.batteryDevice)
        batteryState: root.stateName(root.batteryDevice)
        timeToEmpty: root.batteryDevice ? Number(root.batteryDevice.timeToEmpty || 0) : 0
        timeToFull: root.batteryDevice ? Number(root.batteryDevice.timeToFull || 0) : 0
        batteryModel: root.batteryDevice ? String(root.batteryDevice.model || "") : ""
        batteryPath: root.batteryDevice ? String(root.batteryDevice.nativePath || "") : ""
        actionError: root.actionError
    }

    Timer {
        id: initialSync

        interval: 1000
        repeat: false
        running: root.providerReady && !root.syncReady
        onTriggered: {
            root.syncReady = true;
            root.refresh();
        }
    }

    Timer {
        id: poll

        interval: Math.max(1000, root.interval)
        running: root.providerReady && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Connections {
        target: state
        ignoreUnknownSignals: true

        function onJsonChanged() { root.json = state.json; }
    }

    Connections {
        target: root.upowerService
        ignoreUnknownSignals: true

        function onOnBatteryChanged() { root.refresh(); }
    }

    Connections {
        target: root.upowerService && root.upowerService.devices ? root.upowerService.devices : null
        ignoreUnknownSignals: true

        function onValuesChanged() { root.refresh(); }
    }

    Connections {
        target: root.batteryDevice
        ignoreUnknownSignals: true

        function onPercentageChanged() { root.refresh(); }
        function onStateChanged() { root.refresh(); }
        function onTimeToEmptyChanged() { root.refresh(); }
        function onTimeToFullChanged() { root.refresh(); }
        function onIsPresentChanged() { root.refresh(); }
        function onModelChanged() { root.refresh(); }
        function onNativePathChanged() { root.refresh(); }
    }

    Connections {
        target: root.linePowerDevice
        ignoreUnknownSignals: true

        function onIsPresentChanged() { root.refresh(); }
    }

    Component.onCompleted: root.json = state.json
}
