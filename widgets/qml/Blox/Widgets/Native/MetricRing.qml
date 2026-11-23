import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property real value: -1
    property string label: ""
    property string detail: ""
    property color stroke: "#89b4fa"
    property color foreground: "#cdd6f4"
    property color muted: "#a6adc8"
    property string fontFamily: "Sans Serif"
    property real textScale: 1
    readonly property real ringRadius: Math.max(0, Math.min(width, height) / 2 - 8)
    readonly property real lineWidth: Math.max(3, Math.min(width, height) * 0.045)
    Shape {
        anchors.fill: parent
        asynchronous: false
        antialiasing: true
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(root.stroke.r, root.stroke.g, root.stroke.b, 0.15)
            strokeWidth: root.lineWidth
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.width / 2; centerY: root.height / 2
                radiusX: root.ringRadius; radiusY: root.ringRadius
                startAngle: 126; sweepAngle: 288
            }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.value > 0 ? root.stroke : "transparent"
            strokeWidth: root.lineWidth
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.width / 2; centerY: root.height / 2
                radiusX: root.ringRadius; radiusY: root.ringRadius
                startAngle: 126; sweepAngle: 288 * Math.max(0, Math.min(1, root.value))
            }
        }
    }
    Column {
        anchors.centerIn: parent
        width: parent.width * 0.85
        spacing: 4
        Text { width: parent.width; text: root.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Math.min(root.width * 0.18, 27 * root.textScale); horizontalAlignment: Text.AlignHCenter; fontSizeMode: Text.Fit; minimumPixelSize: 8 }
        Text { width: parent.width; text: root.detail; color: root.muted; font.family: root.fontFamily; font.pixelSize: Math.min(root.width * 0.105, 13 * root.textScale); horizontalAlignment: Text.AlignHCenter; fontSizeMode: Text.Fit; minimumPixelSize: 8 }
    }
}
