import qs.services
import qs.shared
import QtQuick
import Quickshell

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property BarContentController contentController

    function updateChildAnchor() {
        if (!root.geometry.active)
            return;

        root.contentController.calendarController.popoutScreenName = root.geometry.panelWindow.screen.name;
        root.contentController.calendarController.popoutRect = Qt.rect(calendarWindow.anchorX, calendarWindow.anchorY + calendarWindow.cardY, calendarPopout.width, calendarPopout.height);
    }

    HoverPopupWindow {
        id: calendarWindow

        readonly property bool verticalBar: Theme.barPosition === "left" || Theme.barPosition === "right"
        readonly property real backingHeight: verticalBar ? calendarPopout.maximumViewHeight : calendarPopout.height
        readonly property real cardY: verticalBar ? root.geometry.popupY(calendarPopout.height, root.geometry.openPanelY) - root.geometry.popupY(backingHeight, root.geometry.openPanelY) : 0

        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(calendarPopout.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(backingHeight, root.geometry.openPanelY)
        contentWidth: calendarPopout.width
        // Keep the Wayland surface stable while the card shrinks. This lets Qt
        // damage and clear the area formerly occupied by the day view.
        contentHeight: backingHeight
        open: root.geometry.active && root.surfaceController.openPanel === "calendar"
        onOpenChanged: {
            if (open) {
                root.contentController.calendarController.open(root.contentController.now, root.geometry.panelWindow.screen);
            }
        }
        onHoverEntered: {
            root.surfaceController.popoutEntered();
            root.contentController.calendarController.refreshOnHover();
        }
        onHoverExited: root.surfaceController.popoutExited()
        onVisibleChanged: {
            if (!visible && root.geometry.active && !root.contentController.calendarController.childWindowOpen)
                root.surfaceController.setInputPopupLocked(false);

        }

        CalendarPopout {
            id: calendarPopout

            y: calendarWindow.cardY
            controller: root.contentController.calendarController
            onFocusRequested: calendarWindow.requestKeyboardFocus()
        }

        mask: Region {
            y: calendarPopout.y
            width: calendarPopout.width
            height: calendarPopout.height
        }

    }

    Connections {
        function onChildWindowOpenChanged() {
            if (root.geometry.active) {
                if (root.contentController.calendarController.childWindowOpen)
                    root.updateChildAnchor();

                root.surfaceController.setInputPopupLocked(root.contentController.calendarController.childWindowOpen);
            }

        }

        target: root.contentController.calendarController
    }

}
