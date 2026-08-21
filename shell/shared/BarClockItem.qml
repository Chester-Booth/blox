import QtQuick

Item {
    id: root

    required property BarItemContext context

    implicitWidth: root.context.horizontal ? Math.ceil(horizontalClock.implicitWidth) + 16 : verticalClock.implicitWidth
    implicitHeight: root.context.horizontal ? Theme.buttonSize : verticalClock.implicitHeight

    RailClock {
        id: verticalClock

        anchors.horizontalCenter: parent.horizontalCenter
        visible: !root.context.horizontal
        text: root.context.contentController.railClockText(root.context.horizontal)
        dateMode: root.context.contentController.clockDateMode
        onHovered: (centre) => {
            return root.context.surfaceController.hoverButtonEntered("calendar", root.context.mappedCentre(this, centre), "calendar");
        }
        onExited: root.context.surfaceController.hoverButtonExited("calendar")
        onClicked: root.context.contentController.clockDateMode = !root.context.contentController.clockDateMode
    }

    Text {
        id: horizontalClock

        anchors.centerIn: parent
        visible: root.context.horizontal
        text: String(root.context.contentController.railClockText(root.context.horizontal))
        color: root.context.contentController.clockDateMode ? Theme.foreground : Theme.blue
        font.family: Theme.fontFamily
        font.pixelSize: 14
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    MouseArea {
        anchors.fill: parent
        visible: root.context.horizontal
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: {
            const point = mapToItem(null, width / 2, height / 2);
            root.context.surfaceController.hoverButtonEntered("calendar", root.context.horizontal ? point.x : point.y, "calendar");
        }
        onExited: root.context.surfaceController.hoverButtonExited("calendar")
        onClicked: root.context.contentController.clockDateMode = !root.context.contentController.clockDateMode
    }

}
