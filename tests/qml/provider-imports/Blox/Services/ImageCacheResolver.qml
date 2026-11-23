import QtQuick

// Component tests keep their fixture images. Native cache and decoder behaviour
// have separate integration coverage against the real plugin and helper.
QtObject {
    property url source: ""
    property string sourceId: ""
    property int pixelWidth: 0
    property int pixelHeight: 0
    property string fit: "cover"
    property bool active: true
    readonly property url readySource: active ? source : ""
    readonly property string status: !active || !source.toString().length ? "idle" : "ready"
    readonly property string error: ""
}
