import QtQuick

QtObject {
    id: root

    property int interval: 60000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property string profile: "balanced"
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "profile": root.profile,
        "onBattery": false,
        "profileServiceAvailable": true,
        "degradationReason": "none",
        "profiles": ["power-saver", "balanced", "performance"],
        "tooltip": "Power profile: " + root.profile,
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

    function setProfile(value) {
        root.profile = String(value);
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }
}
