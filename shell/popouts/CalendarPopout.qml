import qs.shared
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
    readonly property real monthViewHeight: Math.max(352, content.implicitHeight + 2 * content.anchors.margins)
    readonly property real dayViewHeight: 620
    readonly property real maximumViewHeight: Math.max(monthViewHeight, dayViewHeight)

    signal focusRequested()

    function previousControlLabel() {
        return root.viewIndex ? "Previous day" : "Previous month";
    }

    function viewControlLabel() {
        return root.viewIndex ? "Show calendar" : "Show day";
    }

    function nextControlLabel() {
        return root.viewIndex ? "Next day" : "Next month";
    }

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

    function dismissEventMenu() {
        eventMenu.close();
        controller.eventMenuOpen = false;
    }

    function visibleEvents() {
        var start = viewIndex === 0 ? new Date(shownMonth.getFullYear(), shownMonth.getMonth(), 1) : new Date(controller.selectedDate.getFullYear(), controller.selectedDate.getMonth(), controller.selectedDate.getDate());
        var end = viewIndex === 0 ? new Date(shownMonth.getFullYear(), shownMonth.getMonth() + 1, 1) : new Date(controller.selectedDate.getFullYear(), controller.selectedDate.getMonth(), controller.selectedDate.getDate() + 1);
        return controller.events.filter(function(event) {
            return event.time.kind === "all_day" ? event.time.start_date < Qt.formatDate(end, "yyyy-MM-dd") && event.time.end_date_exclusive > Qt.formatDate(start, "yyyy-MM-dd") : event.time.start_ms < end.getTime() && event.time.end_ms > start.getTime();
        });
    }

    Keys.onEscapePressed: event => {
        event.accepted = root.controller.childWindowOpen;
    }

    width: 360
    height: viewIndex === 0 ? monthViewHeight : dayViewHeight
    radius: Theme.scaledRadius(9)
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
        id: content

        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(12)
        spacing: Theme.scaledSpacing(8)
        opacity: root.transitionOpacity

        RowLayout {
            Layout.fillWidth: true

            BloxButton {
                objectName: "calendar-prev"
                Accessible.role: Accessible.Button
                Accessible.name: root.previousControlLabel()
                compact: true
                iconName: "arrow-left"
                onClicked: root.shift(-1)
                onHoverExited: root.finishNavigation()

                BloxToolTip {
                    shown: parent.hovered
                    text: root.previousControlLabel()
                }

            }

            BloxButton {
                objectName: "calendar-view"
                Accessible.role: Accessible.Button
                Accessible.name: root.viewControlLabel()
                compact: true
                iconName: root.viewIndex ? "calendar-blank" : "clock"
                onClicked: {
                    root.viewIndex = 1 - root.viewIndex;
                    root.controller.refreshViewedDate(root.viewIndex ? root.controller.selectedDate : root.shownMonth, root.viewIndex ? "day" : "month");
                }

                BloxToolTip {
                    shown: parent.hovered
                    text: root.viewControlLabel()
                }

            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(0)

                Text {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: root.viewIndex ? Qt.formatDate(root.controller.selectedDate, "ddd d MMMM") : Qt.formatDate(root.shownMonth, "MMMM yyyy")
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 16
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    Accessible.name: root.viewIndex ? Qt.formatDate(root.controller.selectedDate, "dddd d MMMM") : text

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
                objectName: "calendar-create"
                Accessible.role: Accessible.Button
                Accessible.name: "Create event"
                compact: true
                iconName: "plus"
                accent: Theme.accent
                onClicked: root.controller.createEvent(root.controller.selectedDate, 9, 10)

                BloxToolTip {
                    shown: parent.hovered
                    text: parent.Accessible.name
                }

            }

            BloxButton {
                objectName: "calendar-next"
                Accessible.role: Accessible.Button
                Accessible.name: root.nextControlLabel()
                compact: true
                iconName: "arrow-right"
                onClicked: root.shift(1)
                onHoverExited: root.finishNavigation()

                BloxToolTip {
                    shown: parent.hovered
                    text: root.nextControlLabel()
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

            implicitHeight: monthView.implicitHeight
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            CalendarMonthView {
                id: monthView

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
        objectName: "calendar-event-menu"

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
