import "../shared"
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    required property var controller
    property int viewIndex: 0
    property date shownMonth: controller.selectedDate
    property real transitionOpacity: 1
    property date pendingNavigationDate: controller.selectedDate
    property string pendingNavigationKind: "day"
    readonly property real monthViewHeight: 352
    readonly property real dayViewHeight: 620
    readonly property real maximumViewHeight: Math.max(monthViewHeight, dayViewHeight)

    signal focusRequested()

    function shift(amount) {
        var d = new Date(controller.selectedDate);
        if (viewIndex === 0) {
            d = new Date(shownMonth.getFullYear(), shownMonth.getMonth() + amount, 1);
            shownMonth = d;
            pendingNavigationKind = "month";
        } else {
            d.setDate(d.getDate() + amount);
            controller.selectedDate = d;
            pendingNavigationKind = "day";
        }
        pendingNavigationDate = d;
        controller.snapshot(d);
        keyboardNavigation.restart();
    }

    function finishNavigation() {
        keyboardNavigation.stop();
        controller.finishNavigation(pendingNavigationDate, pendingNavigationKind);
    }

    function visibleEvents() {
        var start = viewIndex === 0 ? new Date(shownMonth.getFullYear(), shownMonth.getMonth(), 1) : new Date(controller.selectedDate.getFullYear(), controller.selectedDate.getMonth(), controller.selectedDate.getDate());
        var end = viewIndex === 0 ? new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 1) : new Date(controller.selectedDate.getFullYear(), controller.selectedDate.getMonth(), controller.selectedDate.getDate() + 1);
        return controller.events.filter(function(event) {
            return event.time.kind === "all_day" ? event.time.start_date < Qt.formatDate(end, "yyyy-MM-dd") && event.time.end_date_exclusive > Qt.formatDate(start, "yyyy-MM-dd") : event.time.start_ms < end.getTime() && event.time.end_ms > start.getTime();
        });
    }

    width: 360
    height: viewIndex === 0 ? monthViewHeight : dayViewHeight
    radius: 9
    color: Theme.background
    border.color: Theme.surfaceAlt
    clip: true
    onViewIndexChanged: viewFade.restart()

    NumberAnimation {
        id: viewFade

        target: root
        property: "transitionOpacity"
        from: 0.35
        to: 1
        duration: 120
        easing.type: Easing.OutCubic
    }

    Timer {
        id: keyboardNavigation

        interval: 250
        onTriggered: root.finishNavigation()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8
        opacity: root.transitionOpacity

        RowLayout {
            Layout.fillWidth: true

            BloxButton {
                compact: true
                iconName: "arrow-left"
                onClicked: root.shift(-1)
                onHoverExited: root.finishNavigation()

                BloxToolTip {
                    shown: parent.hovered
                    text: root.viewIndex ? "Previous day" : "Previous month"
                }

            }

            BloxButton {
                compact: true
                iconName: root.viewIndex ? "calendar-blank" : "clock"
                onClicked: {
                    root.viewIndex = 1 - root.viewIndex;
                    root.controller.refreshViewedDate(root.viewIndex ? root.controller.selectedDate : root.shownMonth, root.viewIndex ? "day" : "month");
                }

                BloxToolTip {
                    shown: parent.hovered
                    text: root.viewIndex ? "Show calendar" : "Show day"
                }

            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: root.viewIndex ? Qt.formatDate(root.controller.selectedDate, "dddd d MMMM") : Qt.formatDate(root.shownMonth, "MMMM yyyy")
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 16
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter

                    TapHandler {
                        onTapped: {
                            var now = new Date();
                            root.controller.selectedDate = now;
                            root.shownMonth = now;
                            root.controller.snapshot();
                            root.controller.refresh(true);
                        }
                    }

                }

                Text {
                    Layout.fillWidth: true
                    text: root.controller.refreshing ? "Refreshing…" : root.visibleEvents().length + " events"
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 9
                    horizontalAlignment: Text.AlignHCenter
                }

            }

            BloxButton {
                compact: true
                iconName: "plus"
                accent: Theme.accent
                onClicked: root.controller.createEvent(root.controller.selectedDate, 9, 10)

                BloxToolTip {
                    shown: parent.hovered
                    text: "Create event"
                }

            }

            BloxButton {
                compact: true
                iconName: "arrow-right"
                onClicked: root.shift(1)
                onHoverExited: root.finishNavigation()

                BloxToolTip {
                    shown: parent.hovered
                    text: root.viewIndex ? "Next day" : "Next month"
                }

            }

        }

        CalendarNotice {
            Layout.fillWidth: true
            visible: !!root.controller.popoutNotice && root.controller.popoutNotice.phase === "failed"
            notice: root.controller.popoutNotice
            actionText: root.controller.popoutNotice && root.controller.popoutNotice.retryable ? "Retry" : ""
            onActionTriggered: root.controller.retryNotice()
        }

        Item {
            id: viewArea

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            CalendarMonthView {
                anchors.fill: parent
                visible: root.viewIndex === 0
                enabled: visible
                shownMonth: root.shownMonth
                selectedDate: root.controller.selectedDate
                events: root.controller.events
                calendars: root.controller.calendars
                onSelected: function(day) {
                    root.controller.selectedDate = day;
                    root.viewIndex = 1;
                    root.controller.refreshViewedDate(day, "day");
                }
            }

            CalendarDayView {
                id: dayView

                anchors.fill: parent
                visible: root.viewIndex === 1
                enabled: visible
                selectedDate: root.controller.selectedDate
                events: root.controller.events
                editorOpen: root.controller.editorOpen
                onSelected: function(day) {
                    root.controller.selectedDate = day;
                    root.controller.refreshViewedDate(day, "day");
                }
                onEventOpened: function(event) {
                    root.controller.showDetails(event);
                }
                onCreateRequested: function(start, end) {
                    root.controller.createEvent(root.controller.selectedDate, start, end);
                }
                onMoveRequested: function(event, start) {
                    root.controller.moveEventTime(event, root.controller.selectedDate, start);
                }
                onResizeRequested: function(event, end) {
                    root.controller.resizeEventTime(event, root.controller.selectedDate, end);
                }
                onMenuRequested: function(event, position) {
                    var anchor = dayView.mapToItem(root, position.x, position.y);
                    var pointerGap = 6;
                    root.focusRequested();
                    root.controller.eventMenuOpen = true;
                    eventMenu.event = event;
                    eventMenu.x = Math.max(6, Math.min(root.width - eventMenu.width - 6, anchor.x + pointerGap));
                    eventMenu.y = Math.max(6, Math.min(root.height - eventMenu.height - 6, anchor.y + pointerGap));
                    eventMenu.open();
                }
            }

        }

    }

    CalendarEventMenu {
        id: eventMenu

        onOpened: root.controller.eventMenuOpen = true
        onClosed: root.controller.eventMenuOpen = false
        onEditRequested: function(event) {
            root.controller.editEvent(event);
        }
        onColourRequested: function(event, colourId) {
            root.controller.changeEventColour(event, colourId);
        }
        onDeleteRequested: function(event) {
            root.controller.requestDelete(event, false);
        }
    }

}
