import QtQuick

QtObject {
    property int interval: 30000
    property int revision: 4
    property real lastUpdatedMs: 2004
    property string lastError: ""
    property var json: ({
        "schemaVersion": 1,
        "providerRevision": 4,
        "observedAtMs": 2004,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "icon": "󰁹",
        "class": "normal",
        "capacity": 72,
        "status": "Discharging",
        "timeLabel": "2h 5m left",
        "source": "battery",
        "onBattery": true,
        "batteryPresent": true,
        "batteryModel": "Test battery",
        "tooltip": "Charge: 72%",
        "capability": {
            "available": true,
            "ready": true,
            "canChange": false,
            "permission": "not-required",
            "reason": null
        }
    })

    function refresh() {
    }
}
