import "."
import QtQuick
import QtQuick.Layouts

Text {
    id: root

    property bool dateMode: false

    signal hovered(real centerY)
    signal exited()
    signal clicked()

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
