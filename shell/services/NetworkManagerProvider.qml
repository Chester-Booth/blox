import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// Read active access point details when Quickshell reports a connected device
// without a connected network.
Scope {
    id: root

    property var networkingService: Networking
    property int interval: 30000
    property bool syncReady: false
    property var pendingWifiEnabled: null
    property int measuredWifiSignal: 0
    property string measuredWifiSsid: ""
    property string pendingWifiStatus: ""
    property string actionError: ""
    readonly property bool providerReady: root.networkingService !== null
    readonly property var deviceValues: root.networkingService && root.networkingService.devices && root.networkingService.devices.values ? root.networkingService.devices.values : []
    readonly property var wifiDevice: root.findDevice(DeviceType.Wifi)
    readonly property var wiredDevice: root.findDevice(DeviceType.Wired)
    readonly property var wifiNetwork: root.findConnectedNetwork(root.wifiDevice)
    readonly property bool actionBusy: root.pendingWifiEnabled !== null
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError
    readonly property var json: state.json

    onWifiDeviceChanged: root.refreshWifiStatus()

    function findDevice(type) {
        const devices = root.deviceValues;
        for (let i = 0; i < devices.length; i++) {
            if (devices[i] && devices[i].type === type)
                return devices[i];
        }
        return null;
    }

    function parseWifiStatus(output) {
        try {
            const status = JSON.parse(String(output || ""));
            if (!status || !Number.isInteger(status.signal) || status.signal < 0 || status.signal > 100 ||
                typeof status.ssid !== "string")
                return null;
            return {
                signal: status.signal,
                ssid: status.ssid
            };
        } catch (error) {
            return null;
        }
    }

    function refreshWifiStatus() {
        if (!root.wifiDevice || root.wifiDevice.connected !== true) {
            root.measuredWifiSignal = 0;
            root.measuredWifiSsid = "";
            return;
        }
        if (root.wifiNetwork) {
            root.measuredWifiSignal = 0;
            root.measuredWifiSsid = "";
            return;
        }
        if (wifiStatusProbe.running)
            return;
        root.pendingWifiStatus = "";
        wifiStatusProbe.running = true;
    }

    function findConnectedNetwork(device) {
        if (!device || !device.networks || !device.networks.values)
            return null;
        const networks = device.networks.values;
        for (let i = 0; i < networks.length; i++) {
            const network = networks[i];
            if (network && (network.connected === true || network.state === ConnectionState.Connected))
                return network;
        }
        return null;
    }

    function syncAction() {
        if (root.pendingWifiEnabled === null)
            return;
        if (!state.canChange) {
            root.pendingWifiEnabled = null;
            actionTimeout.stop();
            root.actionError = "device-removed";
        } else if (state.wifiEnabled === root.pendingWifiEnabled) {
            root.pendingWifiEnabled = null;
            actionTimeout.stop();
        }
    }

    function refresh() {
        root.syncAction();
        state.markChanged();
    }

    function setWifiEnabled(value) {
        if (!state.canChange || root.actionBusy)
            return false;
        root.actionError = "";
        root.pendingWifiEnabled = value === true;
        actionTimeout.restart();
        root.networkingService.wifiEnabled = root.pendingWifiEnabled;
        root.syncAction();
        return true;
    }

    NetworkState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        backendAvailable: root.networkingService && root.networkingService.backend === NetworkBackendType.NetworkManager
        wifiEnabled: root.networkingService ? root.networkingService.wifiEnabled === true : false
        wifiHardwareEnabled: root.networkingService ? root.networkingService.wifiHardwareEnabled === true : false
        wifiConnected: root.wifiDevice ? root.wifiDevice.connected === true : false
        wifiSsid: root.wifiNetwork ? String(root.wifiNetwork.name || "") : root.measuredWifiSsid
        wifiSignal: root.wifiNetwork && root.wifiNetwork.signalStrength !== undefined ? Math.max(0, Math.min(100, Math.round(Number(root.wifiNetwork.signalStrength) * 100))) : root.measuredWifiSignal
        wifiDevice: root.wifiDevice ? String(root.wifiDevice.name || "") : ""
        wiredConnected: root.wiredDevice && root.wiredDevice.network ? root.wiredDevice.network.connected === true : false
        wiredName: root.wiredDevice && root.wiredDevice.network ? String(root.wiredDevice.network.name || "") : ""
        wiredDevice: root.wiredDevice ? String(root.wiredDevice.name || "") : ""
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
        interval: Math.max(15000, root.interval)
        running: root.providerReady && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshWifiStatus()
    }

    Process {
        id: wifiStatusProbe

        command: ["python3", Quickshell.shellDir + "/scripts/network_signal.py", root.wifiDevice ? root.wifiDevice.name : ""]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 || exitStatus !== 0)
                return;
            const status = root.parseWifiStatus(root.pendingWifiStatus);
            if (!status)
                return;
            root.measuredWifiSignal = status.signal;
            root.measuredWifiSsid = status.ssid;
            root.refresh();
        }
        stdout: StdioCollector {
            onStreamFinished: root.pendingWifiStatus = this.text;
        }
    }

    Timer {
        id: actionTimeout

        interval: 5000
        repeat: false
        onTriggered: {
            if (root.pendingWifiEnabled !== null) {
                root.pendingWifiEnabled = null;
                root.actionError = "timeout";
                root.refresh();
            }
        }
    }

    Connections {
        target: root.networkingService
        ignoreUnknownSignals: true

        function onWifiEnabledChanged() { root.refresh(); }
        function onWifiHardwareEnabledChanged() { root.refresh(); }
        function onConnectivityChanged() { root.refresh(); }
        function onBackendChanged() { root.refresh(); }
        function onDevicesChanged() { root.refresh(); }
    }

    Connections {
        target: root.wifiDevice
        ignoreUnknownSignals: true

        function onConnectedChanged() {
            root.refresh();
            root.refreshWifiStatus();
        }
        function onNetworksChanged() {
            root.refresh();
            root.refreshWifiStatus();
        }
        function onStateChanged() { root.refresh(); }
    }

    Connections {
        target: root.wifiNetwork
        ignoreUnknownSignals: true

        function onConnectedChanged() { root.refresh(); }
        function onStateChanged() { root.refresh(); }
        function onSignalStrengthChanged() { root.refresh(); }
        function onNameChanged() { root.refresh(); }
    }

    Connections {
        target: root.wiredDevice && root.wiredDevice.network ? root.wiredDevice.network : null
        ignoreUnknownSignals: true

        function onConnectedChanged() { root.refresh(); }
        function onStateChanged() { root.refresh(); }
        function onNameChanged() { root.refresh(); }
    }
}
