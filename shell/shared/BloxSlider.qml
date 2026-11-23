import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    property string label: ""
    property real value: 0
    property real from: 0
    property real to: 1
    property int decimals: 2
    property var wheelSession: null
    property bool showHeader: true
    property bool showLabel: true
    property string valueSuffix: ""

    signal moved(real value)

    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight
    opacity: enabled ? 1 : 0.48
    activeFocusOnTab: enabled
    objectName: "slider-" + label
    Keys.onPressed: event => {
        if (root.moveByKey(event.key))
            event.accepted = true;
    }

    function valueAt(position) {
        const ratio = Math.max(0, Math.min(1, position / track.width));
        return from + ratio * (to - from);
    }

    function moveByKey(key) {
        const step = Math.pow(10, -decimals);
        let next = value;
        if (key === Qt.Key_Left || key === Qt.Key_Down)
            next -= step;
        else if (key === Qt.Key_Right || key === Qt.Key_Up)
            next += step;
        else if (key === Qt.Key_PageDown)
            next -= step * 10;
        else if (key === Qt.Key_PageUp)
            next += step * 10;
        else if (key === Qt.Key_Home)
            next = from;
        else if (key === Qt.Key_End)
            next = to;
        else
            return false;

        next = Math.max(from, Math.min(to, next));
        if (next !== value)
            moved(Number(next.toFixed(decimals)));
        return true;
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Theme.scaledSpacing(6)
        RowLayout {
            Layout.fillWidth: true
            visible: root.showHeader
            Label {
                visible: root.showLabel
                text: root.label
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.bold: true
            }
            Item { Layout.fillWidth: true }
            Label {
                text: root.value.toFixed(root.decimals) + root.valueSuffix
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: 11
            }
        }

        Rectangle {
            id: track
            Layout.fillWidth: true
            height: 14
            radius: height / 2
            color: Theme.withAlpha(Theme.foreground, 0.08)
            opacity: root.enabled ? 1 : 0.52

            Rectangle {
                width: parent.width * (root.value - root.from) / (root.to - root.from)
                height: parent.height
                radius: parent.radius
                color: Theme.accent
            }

            Rectangle {
                width: 18
                height: 18
                radius: height / 2
                x: Math.max(0, Math.min(track.width - width,
                    track.width * (root.value - root.from) / (root.to - root.from) - width / 2))
                y: -2
                color: Theme.surfaceAlt
                border.color: Theme.accent
                border.width: 2
            }

            MouseArea {
                anchors.fill: parent
                enabled: root.enabled
                hoverEnabled: true
                preventStealing: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPressed: mouse => root.moved(root.valueAt(mouse.x))
                onPositionChanged: mouse => {
                    if (pressed)
                        root.moved(root.valueAt(mouse.x));
                }
                onWheel: event => {
                    if (root.wheelSession && !root.wheelSession.claimEditorWheel(root)) {
                        event.accepted = false;
                        return;
                    }
                    const pixelDelta = event.pixelDelta.y || 0;
                    const angleDelta = event.angleDelta.y || 0;
                    const delta = pixelDelta !== 0 ? pixelDelta : angleDelta;
                    if (delta === 0) {
                        event.accepted = false;
                        return;
                    }
                    const increment = Math.pow(10, -root.decimals);
                    const nextValue = Math.max(root.from, Math.min(root.to,
                        root.value + (delta > 0 ? increment : -increment)));
                    if (nextValue !== root.value)
                        root.moved(nextValue);
                    event.accepted = true;
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        z: 2
        color: "transparent"
        border.color: Theme.blue
        border.width: 2
        visible: root.activeFocus
        radius: Theme.scaledRadius(5)
    }
}
