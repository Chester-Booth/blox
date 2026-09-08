import QtQuick

QtObject {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property bool ok: true
    property string profile: "quiet"
    property bool fanCurveAvailable: false
    property bool fanCurveEnabled: false
    property int setCalls: 0
    property int fanCurveSetCalls: 0
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "vendor": "asusctl",
        "profile": root.profile,
        "profileLabel": root.profile.charAt(0).toUpperCase() + root.profile.slice(1),
        "profiles": ["quiet", "balanced", "performance"],
        "profileControlDomain": "platform-profile",
        "fanCurveEnabled": root.fanCurveEnabled,
        "fanCurveCapability": {
            "available": root.fanCurveAvailable,
            "ready": true,
            "canChange": root.fanCurveAvailable,
            "permission": "not-required",
            "reason": root.fanCurveAvailable ? null : "fan-curves-unsupported"
        },
        "details": "Vendor profile: " + root.profile,
        "tooltip": "Vendor profile: " + root.profile,
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
        root.setCalls += 1;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }

    function setFanCurvesEnabled(value) {
        if (!root.fanCurveAvailable)
            return false;
        root.fanCurveEnabled = value === true;
        root.fanCurveSetCalls += 1;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }
}
