import qs.shared
import QtQuick

Rectangle {
    id: root

    property string icon: ""
    property bool active: false

    signal clicked()

    width: 34
    height: 34
    radius: Theme.scaledRadius(8)
    color: active ? Theme.withAlpha(Theme.surfaceAlt, 0.33) : mouseArea.containsMouse ? Theme.surfaceAlt : "transparent"

    Text {
        anchors.centerIn: parent
        text: root.icon
        color: root.active ? Theme.blue : Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: 17
    }

    MouseArea {
        id: mouseArea

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

}
