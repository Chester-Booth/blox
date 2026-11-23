import QtQuick
import QtQuick.Controls

Button {
    id: root
    property color foreground: "#cdd6f4"
    property color accent: "#89b4fa"
    property real rounding: 1
    property real density: 1
    property string fontFamily: "Sans Serif"
    property real pixelSize: 14
    property string iconName: ""
    property url iconRoot: ""
    readonly property bool hasIcon: iconName !== "" && String(iconRoot) !== ""
    implicitWidth: hasIcon ? implicitHeight : Math.max(34 * density, label.implicitWidth + 12 * density)
    implicitHeight: Math.max(28 * density, pixelSize + 10 * density)
    Accessible.name: text
    contentItem: Item {
        implicitWidth: label.implicitWidth
        implicitHeight: label.implicitHeight
        opacity: root.enabled ? 1 : 0.4
        Text {
            id: label
            anchors.fill: parent
            visible: !root.hasIcon
            text: root.text
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.pixelSize
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            fontSizeMode: Text.Fit
            minimumPixelSize: 10
            elide: Text.ElideRight
        }
        NativeIcon {
            anchors.centerIn: parent
            visible: root.hasIcon
            width: Math.min(parent.width, root.pixelSize)
            height: width
            name: root.iconName
            iconRoot: root.iconRoot
            tint: root.foreground
        }
    }
    background: Rectangle {
        radius: Math.min(width / 2, height / 2, 5 * root.rounding)
        color: root.down ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.23)
            : root.hovered ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: root.accent
    }
}
