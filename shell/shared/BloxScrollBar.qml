import QtQuick
import QtQuick.Controls

ScrollBar {
    id: root

    implicitWidth: orientation === Qt.Vertical ? 8 : 32
    implicitHeight: orientation === Qt.Vertical ? 32 : 8
    interactive: true
    minimumSize: 0.12

    background: Rectangle {
        implicitWidth: root.orientation === Qt.Vertical ? 8 : 32
        implicitHeight: root.orientation === Qt.Vertical ? 32 : 8
        radius: Theme.scaledRadius(3)
        color: root.hovered || root.pressed
            ? Theme.withAlpha(Theme.foreground, 0.09)
            : Theme.withAlpha(Theme.foreground, 0.04)
    }

    contentItem: Rectangle {
        implicitWidth: root.orientation === Qt.Vertical ? 4 : 32
        implicitHeight: root.orientation === Qt.Vertical ? 32 : 4
        radius: Theme.scaledRadius(3)
        color: root.pressed ? Theme.blue
            : root.hovered ? Theme.foreground
            : Theme.muted

        Behavior on color {
            ColorAnimation {
                duration: 110
                easing.type: Easing.OutCubic
            }
        }
    }
}
