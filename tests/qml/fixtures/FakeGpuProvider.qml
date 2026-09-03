import QtQuick

QtObject {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property bool ok: true
    property string mode: "eco"
    property int setCalls: 0
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "devices": [{"id": "card0", "vendor": "amd", "driver": "amdgpu", "kind": "integrated", "bootVga": true}],
        "deviceCount": 1,
        "discreteCount": 0,
        "backend": "drm",
        "mode": root.mode,
        "label": "AMD graphics",
        "gpuOn": false,
        "gpuUtil": "10",
        "gpuTemp": "42",
        "vramUsed": "",
        "vramTotal": "",
        "controlReason": null,
        "tooltip": "AMD graphics",
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

    function setMode(value) {
        root.mode = String(value);
        root.setCalls += 1;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }
}
