import qs.shared
import QtQuick

Rectangle {
    id: root
    objectName: "system-section-" + label.toLowerCase()

    property string icon: ""
    property string label: ""
    property bool active: false

    signal clicked()

    width: 34
    height: 34
    radius: Theme.scaledRadius(8)
    color: active ? Theme.withAlpha(Theme.surfaceAlt, 0.33) : mouseArea.containsMouse ? Theme.surfaceAlt : "transparent"
    border.color: activeFocus ? Theme.blue : "transparent"
    border.width: activeFocus ? 2 : 0
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: label
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    Keys.onSpacePressed: clicked()

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

    BloxToolTip {
        shown: mouseArea.containsMouse
        text: root.label
    }

}
