import "../shared"
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray

Rectangle {
    id: root

    property var menuHandle: null
    property string title: ""

    signal triggered()

    width: 240
    height: Math.min(420, Math.max(44, trayMenuContent.implicitHeight + 16))
    radius: Theme.scaledRadius(8)
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1
    clip: true

    QsMenuOpener {
        id: trayMenuOpener

        menu: root.menuHandle
    }

    Column {
        id: trayMenuContent

        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(8)
        spacing: Theme.scaledSpacing(2)

        Text {
            width: parent.width
            text: root.title
            color: Theme.blue
            font.family: Theme.bodyFontFamily
            font.pixelSize: 14
            font.bold: true
            elide: Text.ElideRight
            visible: text.length > 0
        }

        Repeater {
            model: trayMenuOpener.children

            Rectangle {
                width: parent.width
                height: modelData.isSeparator ? 7 : 28
                radius: Theme.scaledRadius(5)
                color: !modelData.isSeparator && trayEntryMouse.containsMouse && modelData.enabled ? Theme.surfaceAlt : "transparent"
                opacity: modelData.enabled ? 1 : 0.45

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 1
                    color: Theme.surfaceAlt
                    visible: modelData.isSeparator
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.scaledSpacing(8)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaledSpacing(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.text || ""
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 13
                    elide: Text.ElideRight
                    visible: !modelData.isSeparator
                }

                MouseArea {
                    id: trayEntryMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: modelData.enabled && !modelData.isSeparator ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (!modelData.enabled || modelData.isSeparator)
                            return ;

                        modelData.triggered();
                        root.triggered();
                    }
                }

            }

        }

    }

}
