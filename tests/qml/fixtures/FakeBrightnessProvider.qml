import QtQuick

QtObject {
    id: root

    property string scriptRoot: ""
    property int interval: 30000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property bool ok: true
    property int percent: 62
    property int setCalls: 0
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "icon": "󰃝",
        "percent": root.percent,
        "blueLightMode": "auto",
        "blueLightActive": false,
        "device": "amdgpu_bl1",
        "backlightCount": 1,
        "backlights": ["amdgpu_bl1"],
        "ddcAvailable": false,
        "ddcDisplayCount": 0,
        "ddcReason": "command-unavailable",
        "details": "Brightness: " + root.percent + "%",
        "tooltip": "Brightness: " + root.percent + "%",
        "capability": {
            "available": true,
            "ready": true,
            "canChange": true,
            "permission": "granted",
            "reason": null
        }
    })

    function refresh() {
    }

    function setBrightness(value) {
        root.percent = Math.round(Number(value));
        root.setCalls += 1;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }
}
