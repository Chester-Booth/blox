import "../shared"
import "CalendarLayout.js" as LayoutMath
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    required property date selectedDate
    required property var events
    property bool editorOpen: false
    property var segments: calculateSegments()
    property var timed: segments.filter(function(x) {
        return !x.allDay;
    })
    property var allDay: segments.filter(function(x) {
        return x.allDay;
    })
    property string movingKey: ""
    property real movingStart: 0
    property real movingDuration: 0
    property real movingScale: 1
    property string resizingKey: ""
    property real resizingEnd: 0
    property real resizingStart: 0
    property real resizingScaleStart: 0
    property real resizingScaleHours: 1
    property bool draftVisible: false
    property bool draftSelecting: false
    property real draftAnchor: 0
    property real draftStart: 0
    property real draftEnd: 0
    property date clockNow: new Date()
    property var displayTimed: buildDisplayTimed()
    property var bounds: LayoutMath.adaptiveBounds(displayTimed)
    property var placements: LayoutMath.lanes(displayTimed, timeline.height / Math.max(1, bounds.end - bounds.start))

    signal selected(date day)
    signal eventOpened(var event)
    signal createRequested(real start, real end)
    signal moveRequested(var event, real start)
    signal resizeRequested(var event, real end)
    signal menuRequested(var event, point position)

    function startOfDay() {
        return new Date(selectedDate.getFullYear(), selectedDate.getMonth(), selectedDate.getDate()).getTime();
    }

    function endOfDay() {
        return new Date(selectedDate.getFullYear(), selectedDate.getMonth(), selectedDate.getDate() + 1).getTime();
    }

    function calculateSegments() {
        var result = [], start = startOfDay(), end = endOfDay();
        for (var i = 0; i < events.length; ++i) {
            var part = LayoutMath.segment(events[i], start, end);
            if (part) {
                part.key = events[i].key;
                result.push(part);
            }
        }
        return result;
    }

    function buildDisplayTimed() {
        var result = [];
        for (var i = 0; i < timed.length; ++i) {
            var part = Object.assign({
            }, timed[i]);
            if (part.key === movingKey) {
                part.start = movingStart;
                part.end = movingStart + movingDuration;
            }
            if (part.key === resizingKey)
                part.end = resizingEnd;

            result.push(part);
        }
        if (draftVisible)
            result.push({
            "key": "draft",
            "start": draftStart,
            "end": draftEnd,
            "event": null,
            "draft": true
        });

        return result;
    }

    function weekDate(index) {
        var day = new Date(selectedDate);
        day.setDate(day.getDate() - ((day.getDay() + 6) % 7) + index);
        return day;
    }

    function time12(value) {
        var minute = Math.round((value - Math.floor(value)) * 60), h = Math.floor(value), shown = h % 12 || 12;
        return shown + (minute ? (":" + (minute < 10 ? "0" : "") + minute) : "") + (h < 12 ? "am" : "pm");
    }

    function snappedTime(y, start, end) {
        return Math.max(0, Math.min(24, Math.round(LayoutMath.yToTime(y, start, end, timeline.height) * 4) / 4));
    }

    function shownPart(key) {
        return displayTimed.filter(function(x) {
            return x.key === key;
        })[0];
    }

    function syncEventModel(model, items) {
        var wanted = {};
        for (var i = 0; i < items.length; ++i)
            wanted[items[i].key] = true;
        for (var oldIndex = model.count - 1; oldIndex >= 0; --oldIndex) {
            if (!wanted[model.get(oldIndex).segment.key])
                model.remove(oldIndex);
        }
        for (var target = 0; target < items.length; ++target) {
            var found = -1;
            for (var current = target; current < model.count; ++current) {
                if (model.get(current).segment.key === items[target].key) {
                    found = current;
                    break;
                }
            }
            if (found < 0) {
                model.insert(target, {"segment": items[target]});
            } else {
                if (found !== target)
                    model.move(found, target, 1);
                if (JSON.stringify(model.get(target).segment) !== JSON.stringify(items[target]))
                    model.setProperty(target, "segment", items[target]);
            }
        }
    }

    onTimedChanged: syncEventModel(timedEventModel, timed)
    onAllDayChanged: syncEventModel(allDayEventModel, allDay)
    Component.onCompleted: {
        syncEventModel(timedEventModel, timed);
        syncEventModel(allDayEventModel, allDay);
    }

    ListModel { id: timedEventModel; dynamicRoles: true }
    ListModel { id: allDayEventModel; dynamicRoles: true }

    spacing: Theme.scaledSpacing(5)
    onEditorOpenChanged: {
        if (!editorOpen && !draftSelecting) {
            draftVisible = false;
        }
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.clockNow = new Date()
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.preferredHeight: 36
        Layout.minimumHeight: 36
        Layout.maximumHeight: 36
        spacing: Theme.scaledSpacing(3)

        Repeater {
            model: 7

            Rectangle {
                required property int index
                property date day: root.weekDate(index)
                property bool chosen: day.toDateString() === root.selectedDate.toDateString()

                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Theme.scaledRadius(5)
                color: chosen ? Theme.accent : Theme.surface

                Column {
                    anchors.centerIn: parent

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDate(parent.parent.day, "ddd")
                        color: parent.parent.chosen ? Theme.selectionForeground : Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: parent.parent.day.getDate()
                        color: parent.parent.chosen ? Theme.selectionForeground : Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        font.bold: true
                    }

                }

                TapHandler {
                    onTapped: root.selected(parent.day)
                }

            }

        }

    }

    Column {
        Layout.fillWidth: true
        Layout.preferredHeight: root.allDay.length ? root.allDay.length * 27 - 3 : 0
        visible: root.allDay.length > 0
        spacing: Theme.scaledSpacing(3)

        Repeater {
            model: allDayEventModel

            CalendarEventBlock {
                required property var segment

                width: parent.width
                height: 24
                event: segment.event
                shownStart: 0
                shownEnd: 24
                onOpened: function(event) {
                    root.eventOpened(event);
                }
                onMenuRequested: function(event, position) {
                    root.menuRequested(event, mapToItem(root, position.x, position.y));
                }
            }

        }

    }

    Item {
        id: timeline

        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        Repeater {
            model: root.bounds.end - root.bounds.start + 1

            Item {
                required property int index

                x: 0
                y: index * timeline.height / (root.bounds.end - root.bounds.start)
                width: timeline.width
                height: 1

                Text {
                    x: 0
                    y: index === 0 ? 0 : (index === root.bounds.end - root.bounds.start ? -10 : -5)
                    width: 30
                    text: root.time12(root.bounds.start + index)
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 9
                }

                Rectangle {
                    x: 32
                    width: parent.width - 32
                    height: 1
                    color: Theme.surfaceAlt
                }

            }

        }

        MouseArea {
            function update(y) {
                var current = root.snappedTime(y, root.bounds.start, root.bounds.end);
                root.draftStart = Math.min(root.draftAnchor, current);
                root.draftEnd = Math.min(24, Math.max(root.draftAnchor, current) + 0.25);
            }

            x: 32
            width: parent.width - 32
            height: parent.height
            cursorShape: Qt.CrossCursor
            z: 1
            onPressed: function(mouse) {
                root.draftAnchor = root.snappedTime(mouse.y, root.bounds.start, root.bounds.end);
                root.draftStart = root.draftAnchor;
                root.draftEnd = Math.min(24, root.draftAnchor + 0.5);
                root.draftSelecting = true;
                root.draftVisible = true;
                mouse.accepted = true;
            }
            onPositionChanged: function(mouse) {
                if (pressed)
                    update(mouse.y);

            }
            onReleased: {
                root.draftSelecting = false;
                root.createRequested(root.draftStart, root.draftEnd);
            }
            onCanceled: {
                root.draftSelecting = false;
                root.draftVisible = false;
            }
        }

        Rectangle {
            property var place: root.placements.draft || ({
                "lane": 0,
                "lanes": 1
            })
            property real area: timeline.width - 32 - 12 - 4
            property real laneWidth: (area - 2 * (place.lanes - 1)) / place.lanes

            visible: root.draftVisible
            x: root.draftSelecting ? 32 : 34 + place.lane * (laneWidth + 2)
            width: root.draftSelecting ? timeline.width - 32 : laneWidth
            y: LayoutMath.timeToY(root.draftStart, root.bounds.start, root.bounds.end, timeline.height)
            height: Math.max(12, LayoutMath.timeToY(root.draftEnd - root.draftStart, 0, root.bounds.end - root.bounds.start, timeline.height))
            radius: Theme.scaledRadius(5)
            color: Theme.withAlpha(Theme.accent, 0.18)
            border.color: Theme.accent
            z: 8

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.scaledSpacing(5)
                anchors.top: parent.top
                anchors.topMargin: Theme.scaledSpacing(3)
                text: root.time12(root.draftStart) + "–" + root.time12(root.draftEnd)
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 9
            }

        }

        Repeater {
            model: timedEventModel

            CalendarEventBlock {
                required property var segment
                property var shown: root.shownPart(segment.key) || segment
                property var place: root.placements[segment.key] || ({
                    "lane": 0,
                    "lanes": 1
                })
                property real area: timeline.width - 32 - 12 - 4
                property real laneWidth: (area - 2 * (place.lanes - 1)) / place.lanes

                x: root.movingKey === segment.key ? 32 : 34 + place.lane * (laneWidth + 2)
                y: LayoutMath.timeToY(shown.start, root.bounds.start, root.bounds.end, timeline.height)
                width: root.movingKey === segment.key ? timeline.width - 32 : laneWidth
                height: Math.max(16, LayoutMath.timeToY(shown.end - shown.start, 0, root.bounds.end - root.bounds.start, timeline.height))
                z: root.movingKey === segment.key ? 10 : 2
                event: segment.event
                shownStart: shown.start
                shownEnd: shown.end
                directManipulation: !segment.continuesBefore && !segment.continuesAfter
                pixelsPerHour: timeline.height / (root.bounds.end - root.bounds.start)
                moving: root.movingKey === segment.key
                resizing: root.resizingKey === segment.key
                onOpened: function(event) {
                    root.eventOpened(event);
                }
                onMenuRequested: function(event, position) {
                    root.menuRequested(event, mapToItem(root, position.x, position.y));
                }
                onMoveStarted: function() {
                    root.movingKey = segment.key;
                    root.movingStart = segment.start;
                    root.movingDuration = segment.end - segment.start;
                    root.movingScale = timeline.height / (root.bounds.end - root.bounds.start);
                    root.draftVisible = false;
                }
                onMoveChanged: function(event, delta) {
                    root.movingStart = Math.max(0, Math.min(24 - root.movingDuration, segment.start + delta));
                }
                onMoveFinished: function(event, cancelled) {
                    var value = root.movingStart;
                    root.movingKey = "";
                    if (!cancelled && Math.abs(value - segment.start) >= 0.25)
                        root.moveRequested(event, value);

                }
                onResizeStarted: function(event, pointerY) {
                    root.resizingKey = segment.key;
                    root.resizingStart = segment.start;
                    root.resizingEnd = segment.end;
                    root.resizingScaleStart = root.bounds.start;
                    root.resizingScaleHours = root.bounds.end - root.bounds.start;
                }
                onResizeChanged: function(event, pointerY) {
                    root.resizingEnd = Math.max(segment.start + 0.25, Math.min(24, root.snappedTime(pointerY, root.resizingScaleStart, root.resizingScaleStart + root.resizingScaleHours)));
                }
                onResizeFinished: function(event, cancelled) {
                    var value = root.resizingEnd;
                    root.resizingKey = "";
                    if (!cancelled && Math.abs(value - segment.end) >= 0.25)
                        root.resizeRequested(event, value);

                }
            }

        }

        Rectangle {
            visible: root.clockNow.toDateString() === root.selectedDate.toDateString()
            x: 32
            width: parent.width - 32
            height: 1
            color: Theme.red
            y: LayoutMath.timeToY(root.clockNow.getHours() + root.clockNow.getMinutes() / 60, root.bounds.start, root.bounds.end, timeline.height)
            z: 12

            Rectangle {
                anchors.right: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 7
                height: 7
                radius: Theme.scaledRadius(4)
                color: Theme.red
            }

        }

    }

}
