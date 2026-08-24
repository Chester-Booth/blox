import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Scope {
    id: root

    required property var controller
    required property var targetScreen
    property string pendingTitlePattern: ""
    property int pendingWidth: 0
    property int pendingHeight: 0

    function floatWindow(pattern, width, height) {
        pendingTitlePattern = pattern;
        pendingWidth = width;
        pendingHeight = height;
        resizeTimer.restart();
    }

    function startDate() {
        var t = controller.activeEvent && controller.activeEvent.time;
        return t && t.kind === "all_day" ? new Date(t.start_date + "T00:00:00") : new Date(t && t.start_ms || Date.now());
    }

    function endDate() {
        var t = controller.activeEvent && controller.activeEvent.time;
        return t && t.kind === "all_day" ? new Date(t.end_date_exclusive + "T00:00:00") : new Date(t && t.end_ms || Date.now() + 3.6e+06);
    }

    function durationText() {
        var mins = Math.max(15, Math.round((endDate() - startDate()) / 60000));
        return mins < 60 ? mins + " min" : (mins / 60) + " hr" + (mins === 60 ? "" : "s");
    }

    Timer {
        id: resizeTimer

        interval: 30
        onTriggered: {
            var popout = root.controller.popoutRect;
            placementProcess.command = [root.controller.scriptRoot + "/calendar/place-window.sh", root.pendingTitlePattern, String(root.pendingWidth), String(root.pendingHeight), root.controller.popoutScreenName, String(Math.round(popout.x)), String(Math.round(popout.y)), String(Math.round(popout.width))];
            placementProcess.running = true;
        }
    }

    Process {
        id: placementProcess

        onExited: root.controller.childPositionReady = true
    }

    FloatingWindow {
        id: details

        screen: root.targetScreen
        visible: root.controller.detailsOpen
        title: "Blox Calendar Event Details"
        implicitWidth: 320
        implicitHeight: Math.min(420, 176 + (detailsDescription.visible ? Math.min(120, detailsDescription.contentHeight) : 0) + (detailsLocation.visible ? 24 : 0))
        minimumSize: Qt.size(280, 176)
        color: "transparent"
        onClosed: root.controller.closeChildren()
        onVisibleChanged: {
            if (visible)
                root.floatWindow("Blox Calendar Event Details", 320, implicitHeight);

        }

        Shortcut {
            sequence: "Escape"
            onActivated: root.controller.closeChildren()
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(1)
            radius: Theme.scaledRadius(12)
            color: Theme.surface
            border.color: Theme.border
            clip: true
            opacity: root.controller.childPositionReady ? 1 : 0

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(14)
                spacing: Theme.scaledSpacing(10)

                RowLayout {
                    Layout.fillWidth: true
                    Layout.minimumHeight: 34
                    Layout.preferredHeight: 34
                    Layout.maximumHeight: 34

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34

                        Text {
                            anchors.fill: parent
                            text: root.controller.activeEvent ? root.controller.activeEvent.title : "Event details"
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 18
                            font.bold: true
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.SizeAllCursor
                            onPressed: details.contentItem.QsWindow.window.startSystemMove()
                        }

                    }

                    BloxButton {
                        Layout.preferredWidth: 64
                        Layout.maximumWidth: 64
                        text: "Edit"
                        iconName: "pencil-simple"
                        accent: Theme.accent
                        enabled: !!root.controller.activeEvent && root.controller.activeEvent.can_edit
                        onClicked: root.controller.editEvent(root.controller.activeEvent)
                    }

                    BloxButton {
                        compact: true
                        iconName: "x"
                        onClicked: root.controller.closeChildren()
                    }

                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.minimumHeight: 1
                    Layout.preferredHeight: 1
                    Layout.maximumHeight: 1
                    color: Theme.border
                }

                RowLayout {
                    Layout.fillWidth: true

                    PhosphorIcon {
                        Layout.preferredWidth: 17
                        Layout.preferredHeight: 17
                        Layout.maximumWidth: 17
                        Layout.maximumHeight: 17
                        iconName: "calendar-blank"
                        iconColor: Theme.accent
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.controller.activeEvent ? (root.controller.activeEvent.time.kind === "all_day" ? root.controller.activeEvent.time.start_date : Qt.formatDateTime(root.startDate(), "dddd d MMMM · h:mm ap") + "–" + Qt.formatTime(root.endDate(), "h:mm ap")) : ""
                        color: Theme.accent
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }

                }

                RowLayout {
                    id: detailsLocation

                    Layout.fillWidth: true
                    visible: !!(root.controller.activeEvent && root.controller.activeEvent.location)

                    PhosphorIcon {
                        Layout.preferredWidth: 17
                        Layout.preferredHeight: 17
                        Layout.maximumWidth: 17
                        Layout.maximumHeight: 17
                        iconName: "map-pin"
                        iconColor: Theme.muted
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.controller.activeEvent ? root.controller.activeEvent.location : ""
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }

                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: !!(root.controller.activeEvent && root.controller.activeEvent.recurrence && root.controller.activeEvent.recurrence.summary)

                    PhosphorIcon {
                        Layout.preferredWidth: 17
                        Layout.preferredHeight: 17
                        Layout.maximumWidth: 17
                        Layout.maximumHeight: 17
                        iconName: "arrows-clockwise"
                        iconColor: Theme.muted
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.controller.activeEvent && root.controller.activeEvent.recurrence ? root.controller.activeEvent.recurrence.summary : ""
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                    }

                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    Text {
                        id: detailsDescription

                        width: parent.width
                        text: root.controller.activeEvent ? root.controller.activeEvent.description : ""
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }

                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.minimumHeight: implicitHeight
                    Layout.preferredHeight: implicitHeight
                    Layout.maximumHeight: implicitHeight

                    Rectangle {
                        width: 8
                        height: 8
                        radius: Theme.scaledRadius(4)
                        color: root.controller.activeEvent && root.controller.activeEvent.colour ? root.controller.activeEvent.colour.display : Theme.accent
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.controller.activeEvent && root.controller.activeEvent.calendar ? root.controller.activeEvent.calendar.summary : ""
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                }

            }

            Loader {
                anchors.fill: parent
                active: root.controller.confirmDeleteOpen && !root.controller.deleteStandalone
                sourceComponent: confirmOverlay
            }

            MouseArea {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 7
                z: 90
                cursorShape: Qt.SizeHorCursor
                onPressed: details.contentItem.QsWindow.window.startSystemResize(Qt.RightEdge)
            }

            MouseArea {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 7
                z: 91
                cursorShape: Qt.SizeVerCursor
                onPressed: details.contentItem.QsWindow.window.startSystemResize(Qt.BottomEdge)
            }

            MouseArea {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 7
                z: 92
                cursorShape: Qt.SizeHorCursor
                onPressed: details.contentItem.QsWindow.window.startSystemResize(Qt.LeftEdge)
            }

            MouseArea {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 7
                z: 93
                cursorShape: Qt.SizeVerCursor
                onPressed: details.contentItem.QsWindow.window.startSystemResize(Qt.TopEdge)
            }

        }

    }

    FloatingWindow {
        id: deleteWindow

        screen: root.targetScreen
        visible: root.controller.confirmDeleteOpen && root.controller.deleteStandalone
        title: "Blox Calendar Delete Event"
        implicitWidth: 300
        implicitHeight: (root.controller.deleteEvent && root.controller.deleteEvent.recurrence && root.controller.deleteEvent.recurrence.master_id ? 184 : 142) + (root.controller.deleteNotice ? 74 : 0)
        minimumSize: Qt.size(300, implicitHeight)
        color: "transparent"
        onVisibleChanged: {
            if (visible) {
                root.controller.childPositionReady = false;
                root.floatWindow("Blox Calendar Delete Event", 300, implicitHeight);
            }
        }
        onClosed: root.controller.cancelDelete()

        Shortcut {
            sequence: "Escape"
            onActivated: root.controller.cancelDelete()
        }

        Loader {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(1)
            active: true
            sourceComponent: confirmOverlay
            opacity: root.controller.childPositionReady ? 1 : 0
            onLoaded: item.embedded = false
        }

    }

    FloatingWindow {
        id: editor

        property date chosenDate: root.startDate()
        property date chosenStart: root.startDate()
        property date chosenEnd: root.endDate()
        property string chosenColourId: root.controller.activeEvent && root.controller.activeEvent.colour ? (root.controller.activeEvent.colour.event_id || "") : ""
        property string selectedCalendarId: root.controller.activeEvent && root.controller.activeEvent.calendar ? root.controller.activeEvent.calendar.id : ""
        property bool allDay: root.controller.activeEvent && root.controller.activeEvent.time.kind === "all_day"
        property string recurrenceRule: ""
        property date pickerMonth: chosenDate
        property string startText: Qt.formatTime(chosenStart, "h:mm AP")
        property string endText: Qt.formatTime(chosenEnd, "h:mm AP")
        property bool suppressRepeatActivation: false

        function startOptions() {
            var result = [];
            var parsed = parseTime(startText);
            var start = parsed >= 0 ? parsed : chosenStart.getHours() * 60 + chosenStart.getMinutes();
            for (var minutes = Math.ceil(start / 15) * 15; minutes < 1440; minutes += 15) result.push(minutes)
            return result;
        }

        function endOptions() {
            var result = [], start = chosenStart.getHours() * 60 + chosenStart.getMinutes();
            for (var m = start + 15; m <= 1440; m += 15) result.push(m)
            return result;
        }

        function setStart(minutes) {
            var duration = Math.max(15, (chosenEnd - chosenStart) / 60000);
            chosenStart = new Date(chosenDate.getFullYear(), chosenDate.getMonth(), chosenDate.getDate(), Math.floor(minutes / 60), minutes % 60);
            chosenEnd = new Date(chosenStart.getTime() + Math.min(duration, 1440 - minutes) * 60000);
        }

        function durationLabel(minutes) {
            var d = minutes - (chosenStart.getHours() * 60 + chosenStart.getMinutes());
            var hours = Math.round(d / 60 * 100) / 100;
            return d < 60 ? d + " min" : hours + " hr" + (d === 60 ? "" : "s");
        }

        function parseTime(value) {
            var text = String(value).trim().toUpperCase(), match = text.match(/^(\d{1,2})(?::([0-5]?\d)?)?\s*(AM|PM)?$/);
            if (!match)
                return -1;

            var hour = Number(match[1]), minute = match[2] ? Number(match[2]) : 0, suffix = match[3] || "";
            if (suffix) {
                if (hour < 1 || hour > 12)
                    return -1;

                hour = hour % 12 + (suffix === "PM" ? 12 : 0);
            } else if (hour > 23) {
                return -1;
            }
            return hour * 60 + minute;
        }

        function previewStartText() {
            var value = parseTime(startText);
            if (value < 0)
                return ;

            setStart(value);
            endText = Qt.formatTime(chosenEnd, "h:mm AP");
        }

        function acceptStartText() {
            var value = parseTime(startText);
            if (value < 0) {
                startText = Qt.formatTime(chosenStart, "h:mm AP");
                return ;
            }
            setStart(value);
            startText = Qt.formatTime(chosenStart, "h:mm AP");
            endText = Qt.formatTime(chosenEnd, "h:mm AP");
        }

        function acceptEndText() {
            var value = parseTime(endText);
            if (value < 0) {
                endText = Qt.formatTime(chosenEnd, "h:mm AP");
                return ;
            }
            setEnd(value);
            endText = Qt.formatTime(chosenEnd, "h:mm AP");
        }

        function previewEndText() {
            var value = parseTime(endText);
            if (value >= 0)
                setEnd(value);

        }

        function setEnd(value) {
            var start = chosenStart.getHours() * 60 + chosenStart.getMinutes();
            if (value <= start)
                value += 1440;

            chosenEnd = new Date(chosenDate.getFullYear(), chosenDate.getMonth(), chosenDate.getDate() + (value >= 1440 ? 1 : 0), Math.floor(value / 60) % 24, value % 60);
        }

        screen: root.targetScreen
        visible: root.controller.editorOpen
        title: root.controller.activeEvent && root.controller.activeEvent.id ? "Blox Calendar Edit Event" : "Blox Calendar New Event"
        implicitWidth: 320
        implicitHeight: 428 + (root.controller.editorNotice ? 74 : 0)
        minimumSize: Qt.size(320, implicitHeight)
        color: "transparent"
        onClosed: root.controller.closeChildren()
        onVisibleChanged: {
            if (visible) {
                chosenDate = root.startDate();
                chosenStart = root.startDate();
                chosenEnd = root.endDate();
                startText = Qt.formatTime(chosenStart, "h:mm AP");
                endText = Qt.formatTime(chosenEnd, "h:mm AP");
                pickerMonth = chosenDate;
                allDay = root.controller.activeEvent.time.kind === "all_day";
                selectedCalendarId = root.controller.activeEvent.calendar.id;
                recurrenceRule = root.controller.activeEvent.recurrence && root.controller.activeEvent.recurrence.rules && root.controller.activeEvent.recurrence.rules.length ? root.controller.activeEvent.recurrence.rules[0] : "";
                chosenColourId = root.controller.activeEvent.colour ? (root.controller.activeEvent.colour.event_id || "") : "";
                root.floatWindow(root.controller.activeEvent && root.controller.activeEvent.id ? "Blox Calendar Edit Event" : "Blox Calendar New Event", 320, 428);
                Qt.callLater(function() {
                    if (editor.visible)
                        titleField.focusEditor(false);

                });
            } else {
                suppressRepeatActivation = false;
                dateMenuGuard.stop();
            }
        }

        Timer {
            id: dateMenuGuard

            interval: 180
            onTriggered: editor.suppressRepeatActivation = false
        }

        Shortcut {
            sequence: "Escape"
            onActivated: {
                if (dateMenu.opened || durationMenu.opened || startMenu.opened || repeatMenu.opened || calendarMenu.opened) {
                    dateMenu.close();
                    durationMenu.close();
                    startMenu.close();
                    repeatMenu.close();
                    calendarMenu.close();
                } else {
                    root.controller.closeChildren();
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(1)
            radius: Theme.scaledRadius(12)
            color: Theme.surface
            border.color: Theme.border
            clip: true
            opacity: root.controller.childPositionReady ? 1 : 0

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(14)
                spacing: Theme.scaledSpacing(9)
                enabled: !root.controller.editorSaving

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34

                    Text {
                        Layout.fillWidth: true
                        text: root.controller.activeEvent && root.controller.activeEvent.id ? "Edit event" : "New event"
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 18
                        font.bold: true

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.SizeAllCursor
                            onPressed: editor.contentItem.QsWindow.window.startSystemMove()
                        }

                    }

                    BloxButton {
                        id: closeButton

                        compact: true
                        iconName: "x"
                        enabled: !root.controller.editorSaving
                        onClicked: root.controller.closeChildren()

                        BloxToolTip {
                            shown: closeButton.hovered
                            text: "Close"
                        }

                    }

                }

                CalendarNotice {
                    Layout.fillWidth: true
                    visible: !!root.controller.editorNotice
                    notice: root.controller.editorNotice
                    actionText: root.controller.editorNotice && root.controller.editorNotice.code === "etag_conflict" ? "Reload" : root.controller.editorNotice && root.controller.editorNotice.code === "reconciliation_failed" ? "Retry" : ""
                    onActionTriggered: {
                        if (root.controller.editorNotice.code === "etag_conflict")
                            root.controller.reloadEditorEvent();
                        else
                            root.controller.retrySurfaceNotice("editor");
                    }
                }

                BloxTextField {
                    id: titleField

                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    placeholderText: "Add title"
                    text: root.controller.activeEvent ? root.controller.activeEvent.title : ""
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 80
                    z: 20

                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: Theme.scaledSpacing(4)

                        BloxButton {
                            id: dateButton

                            Layout.preferredWidth: 114
                            Layout.minimumWidth: 114
                            Layout.maximumWidth: 114
                            compact: true
                            text: Qt.formatDate(editor.chosenDate, "d MMM yyyy")
                            iconName: "calendar-blank"
                            onClicked: dateMenu.open()
                        }

                        BloxTextField {
                            id: startButton

                            Layout.preferredWidth: 76
                            text: editor.allDay ? "—" : editor.startText
                            enabled: !editor.allDay
                            onEditorFocusedChanged: {
                                if (editorFocused) {
                                    startMenu.open();
                                    Qt.callLater(function() {
                                        startOptionsList.positionViewAtBeginning();
                                    });
                                } else {
                                    editor.acceptStartText();
                                    startMenu.close();
                                }
                            }
                            onTextEdited: function(value) {
                                editor.startText = value;
                                editor.previewStartText();
                                startMenu.open();
                                Qt.callLater(function() {
                                    startOptionsList.positionViewAtBeginning();
                                });
                            }
                            onAccepted: {
                                editor.acceptStartText();
                                startMenu.close();
                            }
                        }

                        Text {
                            text: "to"
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                        }

                        BloxTextField {
                            id: endButton

                            Layout.preferredWidth: 76
                            text: editor.allDay ? "—" : editor.endText
                            enabled: !editor.allDay
                            onEditorFocusedChanged: {
                                if (editorFocused) {
                                    durationMenu.open();
                                    Qt.callLater(function() {
                                        durationOptionsList.positionViewAtBeginning();
                                    });
                                } else {
                                    editor.acceptEndText();
                                    durationMenu.close();
                                }
                            }
                            onTextEdited: function(value) {
                                editor.endText = value;
                                editor.previewEndText();
                                durationMenu.open();
                                Qt.callLater(function() {
                                    durationOptionsList.positionViewAtBeginning();
                                });
                            }
                            onAccepted: {
                                editor.acceptEndText();
                                durationMenu.close();
                            }
                        }

                    }

                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        spacing: Theme.scaledSpacing(8)

                        Rectangle {
                            width: 18
                            height: 18
                            radius: Theme.scaledRadius(3)
                            color: editor.allDay ? Theme.accent : "transparent"
                            border.color: editor.allDay ? Theme.accent : Theme.muted
                            border.width: 2

                            Text {
                                anchors.centerIn: parent
                                visible: editor.allDay
                                text: "✓"
                                color: Theme.selectionForeground
                                font.pixelSize: 12
                            }

                            HoverHandler {
                                cursorShape: Qt.ArrowCursor
                            }

                            TapHandler {
                                onTapped: editor.allDay = !editor.allDay
                            }

                        }

                        Text {
                            text: "All day"
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        BloxButton {
                            id: repeatButton

                            activationEnabled: !editor.suppressRepeatActivation
                            text: editor.recurrenceRule ? "Repeats" : "Does not repeat"
                            iconName: "caret-down"
                            onClicked: repeatMenu.open()
                        }

                    }

                    Popup {
                        id: durationMenu

                        parent: endButton
                        popupType: Popup.Item
                        modal: true
                        dim: false
                        x: endButton.width - width
                        y: endButton.height + 4
                        width: 190
                        padding: Theme.scaledSpacing(4)
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                        background: Rectangle {
                            radius: Theme.scaledRadius(7)
                            color: Theme.background
                            border.color: Theme.border
                        }

                        contentItem: ListView {
                            id: durationOptionsList

                            implicitHeight: Math.min(144, contentHeight)
                            model: editor.endOptions()
                            clip: true

                            delegate: BloxButton {
                                required property int modelData

                                width: ListView.view.width
                                text: (modelData === 1440 ? "12:00 am" : Qt.formatTime(new Date(2000, 0, 1, Math.floor(modelData / 60), modelData % 60), "h:mm ap")) + "  (" + editor.durationLabel(modelData) + ")"
                                onClicked: {
                                    editor.chosenEnd = new Date(editor.chosenDate.getFullYear(), editor.chosenDate.getMonth(), editor.chosenDate.getDate() + (modelData === 1440 ? 1 : 0), Math.floor(modelData / 60) % 24, modelData % 60);
                                    editor.endText = Qt.formatTime(editor.chosenEnd, "h:mm AP");
                                    durationMenu.close();
                                }
                            }

                        }

                    }

                    Popup {
                        id: startMenu

                        parent: startButton
                        popupType: Popup.Item
                        modal: true
                        dim: false
                        y: startButton.height + 4
                        width: 120
                        padding: Theme.scaledSpacing(4)
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                        background: Rectangle {
                            radius: Theme.scaledRadius(7)
                            color: Theme.background
                            border.color: Theme.border
                        }

                        contentItem: ListView {
                            id: startOptionsList

                            implicitHeight: 144
                            model: editor.startOptions()
                            clip: true

                            delegate: BloxButton {
                                required property int modelData

                                width: ListView.view.width
                                text: Qt.formatTime(new Date(2000, 0, 1, Math.floor(modelData / 60), modelData % 60), "h:mm ap")
                                onClicked: {
                                    editor.setStart(modelData);
                                    editor.startText = Qt.formatTime(editor.chosenStart, "h:mm AP");
                                    editor.endText = Qt.formatTime(editor.chosenEnd, "h:mm AP");
                                    startMenu.close();
                                }
                            }

                        }

                    }

                    Popup {
                        id: repeatMenu

                        parent: repeatButton
                        popupType: Popup.Item
                        modal: true
                        dim: false
                        x: repeatButton.width - width
                        y: repeatButton.height + 4
                        width: 190
                        padding: Theme.scaledSpacing(4)
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                        background: Rectangle {
                            radius: Theme.scaledRadius(7)
                            color: Theme.background
                            border.color: Theme.border
                        }

                        contentItem: Column {
                            Repeater {
                                model: [{
                                    "n": "Does not repeat",
                                    "r": ""
                                }, {
                                    "n": "Daily",
                                    "r": "RRULE:FREQ=DAILY"
                                }, {
                                    "n": "Weekdays",
                                    "r": "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
                                }, {
                                    "n": "Weekly",
                                    "r": "RRULE:FREQ=WEEKLY"
                                }, {
                                    "n": "Monthly",
                                    "r": "RRULE:FREQ=MONTHLY"
                                }, {
                                    "n": "Annually",
                                    "r": "RRULE:FREQ=YEARLY"
                                }]

                                BloxButton {
                                    required property var modelData

                                    width: parent.width
                                    text: modelData.n
                                    onClicked: {
                                        editor.recurrenceRule = modelData.r;
                                        repeatMenu.close();
                                    }
                                }

                            }

                        }

                    }

                    Popup {
                        id: dateMenu

                        parent: dateButton
                        popupType: Popup.Item
                        modal: true
                        dim: false
                        y: dateButton.height + 4
                        width: 206
                        padding: Theme.scaledSpacing(8)
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                        onOpened: {
                            dateMenuGuard.stop();
                            editor.suppressRepeatActivation = true;
                        }
                        onClosed: dateMenuGuard.restart()

                        background: Rectangle {
                            radius: Theme.scaledRadius(7)
                            color: Theme.background
                            border.color: Theme.border
                        }

                        contentItem: ColumnLayout {
                            spacing: Theme.scaledSpacing(4)

                            RowLayout {
                                Layout.fillWidth: true

                                BloxButton {
                                    compact: true
                                    iconName: "arrow-left"
                                    onClicked: editor.pickerMonth = new Date(editor.pickerMonth.getFullYear(), editor.pickerMonth.getMonth() - 1, 1)
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: Qt.formatDate(editor.pickerMonth, "MMMM yyyy")
                                    color: Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 12
                                    font.bold: true
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                BloxButton {
                                    compact: true
                                    iconName: "arrow-right"
                                    onClicked: editor.pickerMonth = new Date(editor.pickerMonth.getFullYear(), editor.pickerMonth.getMonth() + 1, 1)
                                }

                            }

                            GridLayout {
                                columns: 7
                                rowSpacing: 2
                                columnSpacing: 2

                                Repeater {
                                    model: ["M", "T", "W", "T", "F", "S", "S"]

                                    Text {
                                        required property string modelData

                                        Layout.preferredWidth: 24
                                        text: modelData
                                        color: Theme.muted
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 9
                                        horizontalAlignment: Text.AlignHCenter
                                    }

                                }

                                Repeater {
                                    model: 42

                                    Rectangle {
                                        required property int index
                                        readonly property bool hovered: dayHover.hovered
                                        property date day: {
                                            var first = new Date(editor.pickerMonth.getFullYear(), editor.pickerMonth.getMonth(), 1);
                                            first.setDate(first.getDate() - ((first.getDay() + 6) % 7) + index);
                                            return first;
                                        }

                                        Layout.preferredWidth: 24
                                        Layout.preferredHeight: 23
                                        radius: Theme.scaledRadius(5)
                                        color: Qt.formatDate(day, "yyyyMMdd") === Qt.formatDate(editor.chosenDate, "yyyyMMdd") ? Theme.accent : hovered ? Theme.surfaceAlt : Theme.surface
                                        border.color: hovered ? Theme.withAlpha(Theme.foreground, 0.34) : "transparent"
                                        border.width: hovered ? 1 : 0

                                        Text {
                                            anchors.centerIn: parent
                                            text: parent.day.getDate()
                                            opacity: parent.day.getMonth() === editor.pickerMonth.getMonth() ? 1 : 0.35
                                            color: parent.color === Theme.accent ? Theme.selectionForeground : Theme.foreground
                                            font.family: Theme.bodyFontFamily
                                            font.pixelSize: 10
                                        }

                                        TapHandler {
                                            onTapped: {
                                                editor.chosenDate = parent.day;
                                                dateMenu.close();
                                            }
                                        }

                                        HoverHandler {
                                            id: dayHover

                                            cursorShape: Qt.PointingHandCursor
                                        }

                                    }

                                }

                            }

                        }

                    }

                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36

                    PhosphorIcon {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        Layout.maximumWidth: 18
                        Layout.maximumHeight: 18
                        iconName: "map-pin"
                        iconColor: Theme.muted
                    }

                    BloxTextField {
                        id: locationField

                        Layout.fillWidth: true
                        placeholderText: "Add location"
                        text: root.controller.activeEvent ? root.controller.activeEvent.location : ""
                    }

                }

                TextArea {
                    id: descriptionField

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 45
                    placeholderText: "Add description"
                    placeholderTextColor: Theme.muted
                    text: root.controller.activeEvent ? root.controller.activeEvent.description : ""
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    padding: Theme.scaledSpacing(10)
                    wrapMode: TextEdit.Wrap
                    Keys.onTabPressed: function(event) {
                        calendarButton.forceActiveFocus();
                        event.accepted = true;
                    }
                    Keys.onBacktabPressed: function(event) {
                        locationField.focusEditor(false);
                        event.accepted = true;
                    }

                    background: Rectangle {
                        radius: Theme.scaledRadius(8)
                        color: Theme.background
                        border.color: Theme.border
                    }

                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 58

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.scaledSpacing(4)

                        Text {
                            text: "Calendar"
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 10
                        }

                        BloxButton {
                            id: calendarButton

                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            elideText: true
                            text: {
                                var c = root.controller.calendars.filter(function(x) {
                                    return x.id === editor.selectedCalendarId;
                                })[0];
                                return c ? c.summary : "Calendar";
                            }
                            onClicked: calendarMenu.open()

                            BloxToolTip {
                                shown: calendarButton.hovered
                                text: calendarButton.text
                            }

                        }

                        Popup {
                            id: calendarMenu

                            parent: calendarButton
                            popupType: Popup.Item
                            modal: true
                            dim: false
                            y: -height - 4
                            width: 180
                            padding: Theme.scaledSpacing(4)
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                            background: Rectangle {
                                radius: Theme.scaledRadius(7)
                                color: Theme.background
                                border.color: Theme.border
                            }

                            contentItem: Column {
                                Repeater {
                                    model: root.controller.calendars

                                    BloxButton {
                                        id: calendarChoice

                                        required property var modelData

                                        width: parent.width
                                        elideText: true
                                        text: modelData.summary
                                        enabled: modelData.write_allowed
                                        onClicked: {
                                            editor.selectedCalendarId = modelData.id;
                                            calendarMenu.close();
                                        }

                                        BloxToolTip {
                                            shown: calendarChoice.hovered
                                            text: calendarChoice.text
                                        }

                                    }

                                }

                            }

                        }

                    }

                    ColumnLayout {
                        Layout.preferredWidth: 112
                        spacing: Theme.scaledSpacing(4)

                        Text {
                            text: "Colour"
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 10
                        }

                        GridLayout {
                            columns: 5
                            rowSpacing: 3
                            columnSpacing: 4

                            Repeater {
                                model: [{
                                    "id": "9",
                                    "c": "#5484ed",
                                    "n": "Blueberry"
                                }, {
                                    "id": "3",
                                    "c": "#dbadff",
                                    "n": "Grape"
                                }, {
                                    "id": "7",
                                    "c": "#46d6db",
                                    "n": "Peacock"
                                }, {
                                    "id": "5",
                                    "c": "#fbd75b",
                                    "n": "Banana"
                                }, {
                                    "id": "11",
                                    "c": "#dc2127",
                                    "n": "Tomato"
                                }, {
                                    "id": "1",
                                    "c": "#a4bdfc",
                                    "n": "Lavender"
                                }, {
                                    "id": "10",
                                    "c": "#51b749",
                                    "n": "Basil"
                                }, {
                                    "id": "2",
                                    "c": "#7ae7bf",
                                    "n": "Sage"
                                }, {
                                    "id": "6",
                                    "c": "#ffb878",
                                    "n": "Tangerine"
                                }, {
                                    "id": "4",
                                    "c": "#ff887c",
                                    "n": "Flamingo"
                                }]

                                Rectangle {
                                    id: colourChoice

                                    required property var modelData

                                    Layout.preferredWidth: 18
                                    Layout.preferredHeight: 18
                                    radius: Theme.scaledRadius(9)
                                    color: modelData.c
                                    border.color: activeFocus || editor.chosenColourId === modelData.id ? Theme.foreground : Theme.withAlpha(Theme.foreground, 0.2)
                                    border.width: activeFocus || editor.chosenColourId === modelData.id ? 3 : 1
                                    activeFocusOnTab: true
                                    Accessible.role: Accessible.RadioButton
                                    Accessible.name: modelData.n
                                    Accessible.checked: editor.chosenColourId === modelData.id
                                    Keys.onSpacePressed: editor.chosenColourId = modelData.id
                                    Keys.onReturnPressed: editor.chosenColourId = modelData.id
                                    Keys.onEnterPressed: editor.chosenColourId = modelData.id

                                    BloxToolTip {
                                        shown: colourHover.hovered
                                        text: colourChoice.modelData.n
                                    }

                                    HoverHandler {
                                        id: colourHover

                                        cursorShape: Qt.PointingHandCursor
                                    }

                                    TapHandler {
                                        onTapped: editor.chosenColourId = parent.modelData.id
                                    }

                                }

                            }

                        }

                    }

                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36

                    BloxButton {
                        visible: !!(root.controller.activeEvent && root.controller.activeEvent.id)
                        text: "Delete"
                        iconName: "trash"
                        destructive: true
                        enabled: !root.controller.editorSaving && !(root.controller.editorNotice && root.controller.editorNotice.code === "reconciliation_failed")
                        onClicked: root.controller.requestDelete(root.controller.activeEvent)
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    BloxButton {
                        text: root.controller.editorSaving ? "Saving…" : root.controller.activeEvent && root.controller.activeEvent.id ? "Save" : "Create"
                        iconName: "floppy-disk"
                        accent: Theme.accent
                        enabled: !root.controller.editorSaving && !(root.controller.editorNotice && root.controller.editorNotice.code === "reconciliation_failed")
                        onClicked: root.controller.saveEvent(titleField.text, descriptionField.text, locationField.text, editor.chosenDate, editor.chosenStart, editor.chosenEnd, editor.chosenColourId, editor.allDay, editor.selectedCalendarId, editor.recurrenceRule)
                    }

                }

            }

            Loader {
                anchors.fill: parent
                active: root.controller.confirmDeleteOpen && !root.controller.deleteStandalone
                sourceComponent: confirmOverlay
            }

            MouseArea {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 7
                z: 90
                cursorShape: Qt.SizeHorCursor
                onPressed: editor.contentItem.QsWindow.window.startSystemResize(Qt.RightEdge)
            }

            MouseArea {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 7
                z: 91
                cursorShape: Qt.SizeVerCursor
                onPressed: editor.contentItem.QsWindow.window.startSystemResize(Qt.BottomEdge)
            }

            MouseArea {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 7
                z: 92
                cursorShape: Qt.SizeHorCursor
                onPressed: editor.contentItem.QsWindow.window.startSystemResize(Qt.LeftEdge)
            }

            MouseArea {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 7
                z: 93
                cursorShape: Qt.SizeVerCursor
                onPressed: editor.contentItem.QsWindow.window.startSystemResize(Qt.TopEdge)
            }

        }

    }

    Component {
        id: confirmOverlay

        Rectangle {
            id: confirmation

            property bool embedded: true
            readonly property bool recurring: !!(root.controller.deleteEvent && root.controller.deleteEvent.recurrence && root.controller.deleteEvent.recurrence.master_id)

            color: embedded ? Theme.withAlpha(Theme.background, 0.86) : Theme.surface
            radius: embedded ? 0 : Theme.scaledRadius(12)
            border.color: embedded ? "transparent" : Theme.border
            z: 100

            Rectangle {
                anchors.centerIn: parent
                width: confirmation.embedded ? parent.width - 28 : parent.width
                height: confirmation.embedded ? (confirmation.recurring ? 184 : 142) + (root.controller.deleteNotice ? 74 : 0) : parent.height
                radius: confirmation.embedded ? Theme.scaledRadius(10) : confirmation.radius
                color: confirmation.embedded ? Theme.surface : "transparent"
                border.color: confirmation.embedded ? Theme.border : "transparent"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(14)
                    spacing: Theme.scaledSpacing(9)

                    Text {
                        Layout.fillWidth: true
                        text: "Delete “" + (root.controller.deleteEvent ? root.controller.deleteEvent.title : "event") + "”?"
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 14
                        font.bold: true
                        wrapMode: Text.Wrap
                    }

                    CalendarNotice {
                        Layout.fillWidth: true
                        visible: !!root.controller.deleteNotice
                        notice: root.controller.deleteNotice
                        actionText: root.controller.deleteNotice && root.controller.deleteNotice.retryable ? "Retry" : ""
                        onActionTriggered: root.controller.retrySurfaceNotice("delete")
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "This cannot be undone here."
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: confirmation.recurring

                        BloxButton {
                            Layout.fillWidth: true
                            text: "This event"
                            checked: root.controller.deleteScope === "instance"
                            onClicked: root.controller.deleteScope = "instance"
                        }

                        BloxButton {
                            Layout.fillWidth: true
                            text: "Following"
                            checked: root.controller.deleteScope === "following"
                            onClicked: root.controller.deleteScope = "following"
                        }

                        BloxButton {
                            Layout.fillWidth: true
                            text: "Series"
                            checked: root.controller.deleteScope === "series"
                            onClicked: root.controller.deleteScope = "series"
                        }

                    }

                    Item {
                        Layout.fillHeight: true
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        Item {
                            Layout.fillWidth: true
                        }

                        BloxButton {
                            text: "Cancel"
                            enabled: !root.controller.deleteSaving
                            onClicked: root.controller.cancelDelete()
                        }

                        BloxButton {
                            text: root.controller.deleteSaving ? "Deleting…" : "Delete"
                            enabled: !root.controller.deleteSaving && !(root.controller.deleteNotice && root.controller.deleteNotice.code === "reconciliation_failed")
                            destructive: true
                            onClicked: root.controller.confirmDelete()
                        }

                    }

                }

            }

        }

    }

}
