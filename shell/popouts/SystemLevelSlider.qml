import qs.shared
import QtQuick
import QtQuick.Layouts

RowLayout {
    id: root

    property int value: 0
    property int maxValue: 100
    property int snapValue: -1
    property int snapDistance: 3
    property bool interactive: true
    property string label: "Level"
    property color accent: Theme.blue
    property color knobColor: Qt.darker(accent, 1.4)
    property color overdriveTrackColor: Qt.rgba(Theme.surface.r * 0.82 + Theme.red.r * 0.18, Theme.surface.g * 0.82 + Theme.red.g * 0.18, Theme.surface.b * 0.82 + Theme.red.b * 0.18, 1)

    signal changed(int value)
    signal dragStarted()
    signal dragFinished()
    signal focusEntered(Item slider)

    activeFocusOnTab: interactive
    Accessible.role: Accessible.Slider
    Accessible.name: label
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down)
            changeBy(-1);
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up)
            changeBy(1);
        else if (event.key === Qt.Key_PageDown)
            changeBy(-10);
        else if (event.key === Qt.Key_PageUp)
            changeBy(10);
        else if (event.key === Qt.Key_Home)
            changeTo(0);
        else if (event.key === Qt.Key_End)
            changeTo(maxValue);
        else
            return;
        event.accepted = true;
    }
    onActiveFocusChanged: {
        if (activeFocus)
            focusEntered(root);
    }

    function changeBy(delta) {
        changeTo(value + delta);
    }

    function changeTo(nextValue) {
        if (!interactive)
            return;
        let next = Math.max(0, Math.min(maxValue, Math.round(nextValue)));
        if (snapValue >= 0 && Math.abs(next - snapValue) <= snapDistance)
            next = snapValue;
        if (next === value)
            return;
        dragStarted();
        changed(next);
        dragFinished();
    }

    spacing: Theme.scaledSpacing(8)
    opacity: interactive ? 1 : 0.55

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 14
        radius: Theme.scaledRadius(7)
        color: Theme.surface
        border.color: root.activeFocus ? root.accent : "transparent"
        border.width: root.activeFocus ? 2 : 0

        Rectangle {
            anchors.right: parent.right
            width: root.snapValue >= 0 && root.snapValue < root.maxValue ? parent.width * (root.maxValue - root.snapValue) / root.maxValue : 0
            height: parent.height
            radius: parent.radius
            color: root.overdriveTrackColor

            Rectangle {
                anchors.left: parent.left
                width: Math.min(parent.radius, parent.width)
                height: parent.height
                color: parent.color
            }

        }

        Rectangle {
            width: parent.width * Math.max(0, Math.min(root.maxValue, root.value)) / root.maxValue
            height: parent.height
            radius: parent.radius
            color: root.accent
        }

        Rectangle {
            width: 18
            height: 18
            radius: Theme.scaledRadius(9)
            x: Math.max(0, Math.min(parent.width - width, parent.width * Math.max(0, Math.min(root.maxValue, root.value)) / root.maxValue - width / 2))
            y: -2
            color: root.knobColor
            border.color: root.accent
            border.width: 2
        }

        MouseArea {
            function valueAt(xPos) {
                const value = Math.round(Math.max(0, Math.min(1, xPos / width)) * root.maxValue);
                if (root.snapValue >= 0 && Math.abs(value - root.snapValue) <= root.snapDistance)
                    return root.snapValue;

                return value;
            }

            anchors.fill: parent
            enabled: root.interactive
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPressed: (mouse) => {
                root.forceActiveFocus();
                root.dragStarted();
                root.changed(valueAt(mouse.x));
            }
            onPositionChanged: (mouse) => {
                if (pressed)
                    root.changed(valueAt(mouse.x));

            }
            onReleased: root.dragFinished()
            onCanceled: root.dragFinished()
        }

    }

}
