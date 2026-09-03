import QtQuick

QtObject {
    id: root

    property int interval: 30000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property bool wifiEnabled: false
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "icon": "󰤥",
        "class": "wifi",
        "summary": "Test Wi-Fi",
        "ssid": "Test Wi-Fi",
        "signal": 78,
        "device": "wlp2s0",
        "wifiEnabled": root.wifiEnabled,
        "details": "Signal: 78%\nwlp2s0",
        "tooltip": "Test Wi-Fi",
        "capability": {
            "available": true,
            "ready": true,
            "canChange": true,
            "permission": "not-required",
            "reason": null
        }
    })

    function refresh() {
    }

    function setWifiEnabled(value) {
        root.wifiEnabled = value === true;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }
}
