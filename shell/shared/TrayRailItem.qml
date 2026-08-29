import qs.shared
import QtQuick

Rectangle {
    id: root

    property var item

    signal openMenu(var item, real centerY)
    signal hovered()
    signal exited()

    implicitWidth: Theme.buttonSize
    implicitHeight: Theme.buttonSize
    width: implicitWidth
    height: implicitHeight
    radius: Theme.barRadius
    color: trayMouse.containsMouse ? Theme.surfaceAlt : "transparent"
    clip: true

    Image {
        anchors.centerIn: parent
        width: 17
        height: 17
        source: root.item ? root.item.icon : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    MouseArea {
        id: trayMouse

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hovered()
        onExited: root.exited()
        onPressed: (event) => {
            if (event.button !== Qt.RightButton)
                return ;

            event.accepted = true;
            root.openMenu(root.item, root.y + root.height / 2);
        }
        onClicked: (event) => {
            if (event.button === Qt.RightButton) {
                event.accepted = true;
                return ;
            } else if (event.button === Qt.MiddleButton) {
                root.item.secondaryActivate();
            } else {
                root.item.activate();
            }
        }
    }

}
