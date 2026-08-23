import QtQuick

Item {
    id: root

    property string text: ""
    property bool checked: false

    signal toggled(bool checked)

    implicitHeight: 30
    implicitWidth: box.width + 8 + label.implicitWidth
    activeFocusOnTab: enabled
    opacity: enabled ? 1 : 0.58
    Keys.onSpacePressed: {
        if (enabled)
            toggled(!checked);

    }

    Rectangle {
        id: box

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 19
        height: 19
        radius: Theme.scaledRadius(6)
        color: root.checked ? Theme.withAlpha(Theme.blue, 0.22) : Theme.background
        border.color: root.activeFocus || root.checked ? Theme.blue : hover.hovered ? Theme.withAlpha(Theme.foreground, 0.36) : Theme.border
        border.width: root.activeFocus ? 2 : 1

        Canvas {
            id: tick

            property color strokeColour: Theme.blue

            anchors.centerIn: parent
            visible: root.checked
            width: 13
            height: 13
            onStrokeColourChanged: requestPaint()
            onPaint: {
                const context = getContext("2d");
                context.reset();
                context.strokeStyle = strokeColour;
                context.lineWidth = 2;
                context.lineCap = "round";
                context.lineJoin = "round";
                context.beginPath();
                context.moveTo(2, 6.5);
                context.lineTo(5.2, 9.5);
                context.lineTo(11, 3.2);
                context.stroke();
            }
        }

    }

    Text {
        id: label

        anchors.left: box.right
        anchors.leftMargin: Theme.scaledSpacing(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        color: root.enabled ? Theme.foreground : Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: 11
    }

    HoverHandler {
        id: hover

        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    }

    TapHandler {
        enabled: root.enabled
        onTapped: root.toggled(!root.checked)
    }

}
