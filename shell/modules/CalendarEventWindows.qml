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

    function eventEditDisabledReason(event) {
        if (!event)
            return "";
        if (event.busy)
            return "Event update in progress.";
        return event.can_edit ? "" : String(event.capability_reason || "");
    }

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

    CalendarEventDetailWindow {
        id: details
        controller: root.controller
        targetScreen: root.targetScreen
        hostOwner: root
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

        CalendarDeleteConfirmOverlay {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(1)
            controller: root.controller
            embedded: false
            opacity: root.controller.childPositionReady ? 1 : 0
        }
    }

    CalendarEventEditorWindow {
        id: editor
        controller: root.controller
        targetScreen: root.targetScreen
        hostOwner: root
    }
}
