import QtQuick
import Quickshell
import Quickshell.Bluetooth

// Native BlueZ adapter. It exposes names and state only, never device
// addresses, and owns the adapter power action.
Scope {
    id: root

    property var bluetoothService: Bluetooth
    property int interval: 30000
    property bool syncReady: false
    property var pendingEnabled: null
    property string actionError: ""
    readonly property bool providerReady: root.bluetoothService !== null
    readonly property var adapter: root.bluetoothService ? root.bluetoothService.defaultAdapter : null
    readonly property var deviceValues: root.bluetoothService && root.bluetoothService.devices && root.bluetoothService.devices.values ? root.bluetoothService.devices.values : []
    readonly property bool actionBusy: root.pendingEnabled !== null
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError
    readonly property var json: state.json

    function deviceName(device) {
        if (!device)
            return "";
        const name = String(device.name || device.deviceName || "");
        return name.length > 0 ? name : "Bluetooth device";
    }

    function connectedDeviceNames() {
        const names = [];
        const devices = root.deviceValues;
        for (let i = 0; i < devices.length; i++) {
            const device = devices[i];
            if (device && (device.connected === true || device.state === BluetoothDeviceState.Connected))
                names.push(root.deviceName(device));
        }
        return names;
    }

    function syncAction() {
        if (root.pendingEnabled === null)
            return;
        if (!state.canChange) {
            root.pendingEnabled = null;
            actionTimeout.stop();
            root.actionError = "device-removed";
        } else if (state.adapterEnabled === root.pendingEnabled) {
            root.pendingEnabled = null;
            actionTimeout.stop();
        }
    }

    function refresh() {
        root.syncAction();
        state.markChanged();
    }

    function setBluetoothEnabled(value) {
        if (!state.canChange || root.actionBusy)
            return false;
        root.actionError = "";
        root.pendingEnabled = value === true;
        actionTimeout.restart();
        root.adapter.enabled = root.pendingEnabled;
        root.syncAction();
        return true;
    }

    BluetoothState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        adapterAvailable: root.adapter !== null
        adapterEnabled: root.adapter ? root.adapter.enabled === true : false
        adapterBlocked: root.adapter ? root.adapter.state === BluetoothAdapterState.Blocked : false
        connectedNames: root.connectedDeviceNames()
        busy: root.actionBusy
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

    Timer {
        id: actionTimeout

        interval: 5000
        repeat: false
        onTriggered: {
            if (root.pendingEnabled !== null) {
                root.pendingEnabled = null;
                root.actionError = "timeout";
                root.refresh();
            }
        }
    }

    Connections {
        target: root.bluetoothService
        ignoreUnknownSignals: true

        function onDefaultAdapterChanged() { root.refresh(); }
    }

    Connections {
        target: root.adapter
        ignoreUnknownSignals: true

        function onEnabledChanged() { root.refresh(); }
        function onStateChanged() { root.refresh(); }
        function onDevicesChanged() { root.refresh(); }
    }

    Connections {
        target: root.bluetoothService && root.bluetoothService.devices ? root.bluetoothService.devices : null
        ignoreUnknownSignals: true

        function onValuesChanged() { root.refresh(); }
    }
}
