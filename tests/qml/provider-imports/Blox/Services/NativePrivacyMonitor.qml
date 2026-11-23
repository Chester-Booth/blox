import QtQuick

QtObject {
    property bool enabled: true
    property bool ok: true
    property bool active: false
    property int microphoneCount: 0
    property int videoCount: 0
    property real lastUpdatedMs: 0
    property string lastError: ""
    property bool timedOut: false
    property var json: ({
        icon: "󰍹",
        class: "idle",
        active: false,
        microphoneCount: 0,
        videoCount: 0,
        details: "No active microphone, camera or screen capture",
        tooltip: "No active microphone, camera or screen capture",
        capability: {available: true, ready: true, canChange: false, permission: "not-required", reason: null}
    })
    function refresh() {}
}
