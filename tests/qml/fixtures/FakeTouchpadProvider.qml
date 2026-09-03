import QtQuick

QtObject {
    id: root

    property string scriptRoot: ""
    property int interval: 15000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property bool ok: true
    property bool enabled: true
    property int setCalls: 0
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "icon": root.enabled ? "󰟸" : "󰤳",
        "class": root.enabled ? "enabled" : "disabled",
        "device": "fake-touchpad",
        "devices": ["fake-touchpad"],
        "touchpadCount": 1,
        "enabled": root.enabled,
        "details": root.enabled ? "Touchpad enabled" : "Touchpad disabled",
        "tooltip": root.enabled ? "Touchpad enabled" : "Touchpad disabled",
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

    function setEnabled(value) {
        root.enabled = value === true;
        root.setCalls += 1;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }

    function toggle() {
        return root.setEnabled(!root.enabled);
    }
}
