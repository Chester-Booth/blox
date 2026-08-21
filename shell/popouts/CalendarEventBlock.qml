import "../shared"
import QtQuick

Item {
    id: root

    required property var event
    property bool directManipulation: false
    property real pixelsPerHour: 1
    property real shownStart: 0
    property real shownEnd: 0
    property bool moving: false
    property bool resizing: false
    property bool interacting: bodyDrag.active || resizeArea.pressed || bodyTap.pressed
    readonly property bool updatePending: !!root.event && root.event.pending === true && root.event.busy === true

    signal opened(var event)
    signal menuRequested(var event, point position)
    signal moveStarted(var event)
    signal moveChanged(var event, real deltaHours)
    signal moveFinished(var event, bool cancelled)
    signal resizeStarted(var event, real pointerY)
    signal resizeChanged(var event, real pointerY)
    signal resizeFinished(var event, bool cancelled)

    function time12(value) {
        var minutes = Math.round((value - Math.floor(value)) * 60), h = Math.floor(value), shown = h % 12 || 12;
        return shown + (minutes ? (":" + (minutes < 10 ? "0" : "") + minutes) : "") + (h < 12 ? "am" : "pm");
    }

    function timeText() {
        return time12(shownStart) + "–" + time12(shownEnd);
    }

    Canvas {
        property color eventColour: root.event && root.event.colour ? root.event.colour.display : Theme.accent
        property color calendarColour: root.event && root.event.colour ? root.event.colour.calendar_fallback : eventColour

        anchors.fill: parent
        onEventColourChanged: requestPaint()
        onCalendarColourChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var c = getContext("2d"), w = width, h = height, r = Math.min(5, h / 2), edge = String(eventColour).toLowerCase() !== String(calendarColour).toLowerCase();
            c.reset();
            c.beginPath();
            c.roundedRect(0.5, 0.5, w - 1, h - 1, r, r);
            c.fillStyle = Theme.withAlpha(eventColour, 0.22);
            c.fill();
            c.strokeStyle = eventColour;
            c.stroke();
            if (edge) {
                c.save();
                c.beginPath();
                c.roundedRect(0.5, 0.5, w - 1, h - 1, r, r);
                c.clip();
                c.fillStyle = Theme.withAlpha(calendarColour, 0.3);
                c.fillRect(0, 0, 6, h);
                c.restore();
            }
        }
    }

    Column {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 4
        anchors.topMargin: 2

        Text {
            width: parent.width
            text: root.event ? root.event.title : ""
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 10
            font.bold: true
            elide: Text.ElideRight
        }

        Text {
            visible: root.height >= 28
            width: parent.width
            text: root.timeText()
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 8
            elide: Text.ElideRight
        }

    }

    HoverHandler {
        id: hover

        cursorShape: directManipulation && event && event.can_edit ? Qt.PointingHandCursor : Qt.ArrowCursor
    }

    BloxToolTip {
        shown: hover.hovered && !root.interacting
        text: (root.event ? root.event.title : "") + "\n" + root.timeText() + "\n" + (root.event && root.event.calendar ? root.event.calendar.summary : "")
    }

    Item {
        anchors.fill: parent
        anchors.bottomMargin: root.directManipulation && root.event && root.event.can_edit ? 8 : 0

        TapHandler {
            id: bodyTap

            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onTapped: function(eventPoint, button) {
                if (button === Qt.RightButton)
                    root.menuRequested(root.event, eventPoint.position);
                else
                    root.opened(root.event);
            }
        }

        DragHandler {
            id: bodyDrag

            property real lastDelta: 0

            target: null
            acceptedButtons: Qt.LeftButton
            enabled: root.directManipulation && root.event && root.event.can_edit && !root.event.busy
            xAxis.enabled: false
            onActiveChanged: {
                if (active) {
                    lastDelta = 0;
                    root.moveStarted(root.event);
                } else {
                    root.moveFinished(root.event, false);
                }
            }
            onTranslationChanged: {
                if (active) {
                    lastDelta = Math.round(translation.y / root.pixelsPerHour * 4) / 4;
                    root.moveChanged(root.event, lastDelta);
                }
            }
            onCanceled: root.moveFinished(root.event, true)
        }

    }

    MouseArea {
        id: resizeArea

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 8
        z: 8
        enabled: root.directManipulation && root.event && root.event.can_edit && !root.event.busy
        cursorShape: Qt.SizeVerCursor
        onPressed: function(mouse) {
            var p = mapToItem(root.parent, 0, mouse.y);
            root.resizeStarted(root.event, p.y);
            mouse.accepted = true;
        }
        onPositionChanged: function(mouse) {
            if (pressed) {
                var p = mapToItem(root.parent, 0, mouse.y);
                root.resizeChanged(root.event, p.y);
            }
        }
        onReleased: root.resizeFinished(root.event, false)
        onCanceled: root.resizeFinished(root.event, true)
    }

    SequentialAnimation on opacity {
        running: root.updatePending
        loops: Animation.Infinite
        onRunningChanged: {
            if (!running)
                root.opacity = 1;

        }

        NumberAnimation {
            from: 0.45
            to: 1
            duration: 550
        }

        NumberAnimation {
            from: 1
            to: 0.45
            duration: 550
        }

    }

}
