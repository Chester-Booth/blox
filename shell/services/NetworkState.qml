import QtQuick

// Pure network projection. The native adapter supplies only primitive values,
// which keeps missing-device and service-loss cases safe to test.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool backendAvailable: false
    property bool wifiEnabled: false
    property bool wifiHardwareEnabled: false
    property bool wifiConnected: false
    property string wifiSsid: ""
    property int wifiSignal: 0
    property string wifiDevice: ""
    property bool wiredConnected: false
    property string wiredName: ""
    property string wiredDevice: ""
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady && root.backendAvailable
    readonly property bool canChange: root.ready && root.wifiHardwareEnabled
    readonly property var json: root.buildStatus()

    function capability() {
        let reason = null;
        let permission = "not-required";
        if (!root.providerReady) {
            reason = "provider-not-ready";
            permission = "unknown";
        } else if (!root.syncReady) {
            reason = "provider-loading";
            permission = "unknown";
        } else if (!root.backendAvailable) {
            reason = "backend-unavailable";
            permission = "unknown";
        } else if (!root.wifiHardwareEnabled) {
            reason = "no-wifi-hardware";
        }
        return {
            "available": root.providerReady && (!root.syncReady || root.backendAvailable),
            "ready": root.ready,
            "canChange": root.canChange,
            "permission": permission,
            "reason": reason
        };
    }

    function wifiIcon(signal) {
        if (signal < 20)
            return "󰤯";
        if (signal < 40)
            return "󰤟";
        if (signal < 60)
            return "󰤢";
        if (signal < 80)
            return "󰤥";
        return "󰤨";
    }

    function buildStatus() {
        const capability = root.capability();
        let icon = "󰤩";
        let statusClass = "unavailable";
        let summary = "Network unavailable";
        let details = "NetworkManager is unavailable";
        if (!root.syncReady && root.providerReady) {
            statusClass = "loading";
            summary = "Network loading";
            details = "Waiting for NetworkManager";
        } else if (capability.available) {
            if (root.wiredConnected) {
                icon = "󰈀";
                statusClass = "wired";
                summary = root.wiredName || "Wired network";
                details = "Connected via " + (root.wiredDevice || "wired device");
            } else if (!root.wifiHardwareEnabled) {
                icon = "󰤩";
                statusClass = "unavailable";
                summary = "Wi-Fi unavailable";
                details = "No Wi-Fi hardware was found";
            } else if (!root.wifiEnabled) {
                icon = "󰤭";
                statusClass = "disabled";
                summary = "Wi-Fi disabled";
                details = "Wi-Fi is disabled";
            } else if (root.wifiConnected) {
                icon = root.wifiIcon(root.wifiSignal);
                statusClass = "wifi";
                summary = root.wifiSsid || "Wi-Fi connected";
                details = "Signal: " + root.wifiSignal + "%\n" + (root.wifiDevice || "Wi-Fi device");
            } else {
                statusClass = "disconnected";
                summary = "Wi-Fi disconnected";
                details = "No active network connection";
            }
        }
        if (root.actionError.length > 0)
            details += "\nAction error: " + root.actionError;
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": root.busy,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "icon": icon,
            "class": statusClass,
            "summary": summary,
            "ssid": root.wifiSsid,
            "signal": root.wifiSignal,
            "device": root.wifiDevice,
            "wifiEnabled": root.wifiEnabled,
            "details": details,
            "tooltip": summary + "\n" + details,
            "capability": capability
        };
    }

    function markChanged() {
        root.revision += 1;
        root.observedAtMs = Date.now();
    }

    onProviderReadyChanged: root.markChanged()
    onSyncReadyChanged: root.markChanged()
    onBackendAvailableChanged: root.markChanged()
    onWifiEnabledChanged: root.markChanged()
    onWifiHardwareEnabledChanged: root.markChanged()
    onWifiConnectedChanged: root.markChanged()
    onWifiSsidChanged: root.markChanged()
    onWifiSignalChanged: root.markChanged()
    onWifiDeviceChanged: root.markChanged()
    onWiredConnectedChanged: root.markChanged()
    onWiredNameChanged: root.markChanged()
    onWiredDeviceChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
