import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root

    property string label: ""
    property real value: 0
    property real from: 0
    property real to: 1
    property int decimals: 2
    property var wheelSession: null

    signal moved(real value)

    spacing: Theme.scaledSpacing(6)
    opacity: enabled ? 1 : 0.48

    function valueAt(position) {
        const ratio = Math.max(0, Math.min(1, position / track.width));
        return from + ratio * (to - from);
    }

    RowLayout {
        Layout.fillWidth: true

        Label {
            text: root.label
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.bold: true
        }

        Item {
            Layout.fillWidth: true
        }

        Label {
            text: root.value.toFixed(root.decimals)
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
            x: Math.max(0, Math.min(track.width - width, track.width * (root.value - root.from) / (root.to - root.from) - width / 2))
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
                const nextValue = Math.max(root.from, Math.min(root.to, root.value + (delta > 0 ? increment : -increment)));
                if (nextValue !== root.value)
                    root.moved(nextValue);
                event.accepted = true;
            }
        }
    }
}
