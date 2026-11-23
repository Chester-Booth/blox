import QtQuick

QtObject {
    id: root

    property int revision: 1
    property real lastUpdatedMs: 1000
    property bool ok: true
    property string lastError: ""
    property int volume: 42
    property bool muted: false
    property bool micMuted: false
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "volume": root.volume,
        "muted": root.muted,
        "micMuted": root.micMuted,
        "micCanChange": true,
        "capability": {
            "available": true,
            "ready": true,
            "canChange": true,
            "permission": "not-required",
            "reason": null
        }
    })

    function changed() {
        root.revision += 1;
        root.lastUpdatedMs += 1;
    }

    function refresh() {
    }

    function setVolume(value) {
        root.volume = Number(value);
        root.changed();
        return true;
    }

    function toggleMute() {
        root.muted = !root.muted;
        root.changed();
        return true;
    }

    function setMicMuted(value) {
        root.micMuted = value === true;
        root.changed();
        return true;
    }
}
