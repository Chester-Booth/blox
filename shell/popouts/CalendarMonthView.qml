import "../shared"
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    required property date shownMonth
    required property date selectedDate
    required property var events
    required property var calendars

    signal selected(date day)

    function firstMonday() {
        var first = new Date(shownMonth.getFullYear(), shownMonth.getMonth(), 1);
        first.setDate(first.getDate() - ((first.getDay() + 6) % 7));
        return first;
    }

    function dateAt(index) {
        var d = firstMonday();
        d.setDate(d.getDate() + index);
        return d;
    }

    function sameDate(a, b) {
        return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }

    function coloursFor(date) {
        var start = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime(), end = start + 8.64e+07, result = [];
        for (var i = 0; i < events.length && result.length < 3; ++i) {
            var t = events[i].time, hit = t.kind === "all_day" ? Qt.formatDate(date, "yyyy-MM-dd") >= t.start_date && Qt.formatDate(date, "yyyy-MM-dd") < t.end_date_exclusive : t.start_ms < end && t.end_ms > start;
            if (hit)
                result.push(events[i].colour.display);

        }
        return result;
    }

    function visibleCalendars() {
        var start = new Date(shownMonth.getFullYear(), shownMonth.getMonth(), 1).getTime();
        var end = new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 1).getTime();
        var used = {
        };
        for (var i = 0; i < events.length; ++i) {
            var event = events[i], time = event.time;
            var hit = time.kind === "all_day" ? new Date(time.start_date + "T00:00:00").getTime() < end && new Date(time.end_date_exclusive + "T00:00:00").getTime() > start : time.start_ms < end && time.end_ms > start;
            if (hit && event.calendar)
                used[event.calendar.id] = true;

        }
        return calendars.filter(function(calendar) {
            return used[calendar.id];
        });
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.scaledSpacing(6)

        GridLayout {
            id: grid

            // Derive the columns from the view, not GridLayout's implicit width.
            // Whole-pixel widths avoid clipping; wider columns use the remainder.
            property real cellSize: Math.floor((root.width - columnSpacing * 6) / 7)
            property int widerColumns: Math.round(root.width - columnSpacing * 6 - cellSize * 7)

            function cellWidth(column) {
                return cellSize + (column < widerColumns ? 1 : 0);
            }

            Layout.fillWidth: true
            columns: 7
            columnSpacing: 4
            rowSpacing: 4

            Repeater {
                model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

                Text {
                    required property int index
                    required property string modelData

                    Layout.preferredWidth: grid.cellWidth(index)
                    Layout.preferredHeight: 18
                    text: modelData
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                }

            }

            Repeater {
                model: 42

                Rectangle {
                    required property int index
                    property date day: root.dateAt(index)
                    property bool inMonth: day.getMonth() === root.shownMonth.getMonth()
                    property bool chosen: root.sameDate(day, root.selectedDate)
                    property var marks: root.coloursFor(day)

                    Layout.preferredWidth: grid.cellWidth(index % 7)
                    Layout.preferredHeight: 34
                    radius: Theme.scaledRadius(6)
                    color: chosen ? Theme.accent : hover.hovered ? Theme.surfaceAlt : Theme.surface
                    opacity: inMonth ? 1 : 0.38

                    Text {
                        anchors.centerIn: parent
                        text: parent.day.getDate()
                        color: parent.chosen ? Theme.selectionForeground : Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        font.bold: parent.chosen
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Theme.scaledSpacing(3)
                        spacing: Theme.scaledSpacing(2)

                        Repeater {
                            model: parent.parent.marks

                            Rectangle {
                                required property var modelData

                                width: 4
                                height: 4
                                radius: Theme.scaledRadius(2)
                                color: modelData
                            }

                        }

                    }

                    HoverHandler {
                        id: hover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: root.selected(parent.day)
                    }

                }

            }

        }

        Flow {
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            spacing: Theme.scaledSpacing(7)

            Repeater {
                model: root.visibleCalendars()

                Row {
                    required property var modelData

                    spacing: Theme.scaledSpacing(4)
                    height: 12
                    width: Math.min(implicitWidth, root.width)

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7
                        height: 7
                        radius: Theme.scaledRadius(4)
                        color: modelData.colour
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, root.width - 11)
                        text: modelData.summary
                        elide: Text.ElideRight
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 10
                    }

                }

            }

        }

    }

}
