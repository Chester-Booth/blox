import QtQuick

QtObject {
    id: root

    property int interval: 30000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property bool enabled: false
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "icon": "󰂯",
        "class": "on",
        "summary": "Bluetooth on",
        "enabled": root.enabled,
        "details": "No connected devices",
        "tooltip": "Bluetooth on",
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

    function setBluetoothEnabled(value) {
        root.enabled = value === true;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }
}
