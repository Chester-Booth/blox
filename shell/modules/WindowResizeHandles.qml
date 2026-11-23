import QtQuick
import Quickshell

// Shared four-edge resize handles for frameless FloatingWindow surfaces.
Item {
    id: root

    required property var targetWindow
    property int edgeSize: 7
    property int baseZ: 100

    anchors.fill: parent

    MouseArea {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.edgeSize
        z: root.baseZ
        cursorShape: Qt.SizeHorCursor
        onPressed: root.targetWindow.contentItem.QsWindow.window.startSystemResize(Qt.RightEdge)
    }

    MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.edgeSize
        z: root.baseZ + 1
        cursorShape: Qt.SizeVerCursor
        onPressed: root.targetWindow.contentItem.QsWindow.window.startSystemResize(Qt.BottomEdge)
    }

    MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.edgeSize
        z: root.baseZ + 2
        cursorShape: Qt.SizeHorCursor
        onPressed: root.targetWindow.contentItem.QsWindow.window.startSystemResize(Qt.LeftEdge)
    }

    MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.edgeSize
        z: root.baseZ + 3
        cursorShape: Qt.SizeVerCursor
        onPressed: root.targetWindow.contentItem.QsWindow.window.startSystemResize(Qt.TopEdge)
    }
}
