import qs.shared
import QtQuick
import QtQuick.Layouts

Text {
    id: root

    property bool dateMode: false

    signal hovered(real centerY)
    signal exited()
    signal clicked()

    activeFocusOnTab: true
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.clicked();
            event.accepted = true;
        }
    }
    opacity: activeFocus ? 0.68 : 1

    Layout.alignment: Qt.AlignHCenter
    color: dateMode ? Theme.foreground : Theme.blue
    font.family: Theme.fontFamily
    font.pixelSize: 16
    horizontalAlignment: Text.AlignHCenter

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hovered(root.y + root.height / 2)
        onExited: root.exited()
        onClicked: (event) => {
            if (event.button === Qt.LeftButton)
                root.clicked();

        }
    }

}
