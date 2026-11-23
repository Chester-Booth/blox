import qs.services
import qs.shared
import QtQuick
import Quickshell

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    readonly property bool wantOpen: root.geometry.active && root.surfaceController.openPanel === "calendar"
    readonly property bool externalChildWindowOpen: root.contentController.calendarController.detailsOpen
        || root.contentController.calendarController.editorOpen
        || root.contentController.calendarController.confirmDeleteOpen
    property bool loaded: false

    function dismissPopup() {
        if (root.contentController.calendarController.eventMenuOpen && calendarLoader.item)
            calendarLoader.item.dismissEventMenu();
        root.surfaceController.closePanel();
    }

    function updateChildAnchor() {
        if (!root.geometry.active || !calendarLoader.item)
            return;

        const popup = calendarLoader.item;
        root.contentController.calendarController.popoutScreenName = root.geometry.panelWindow.screen.name;
        root.contentController.calendarController.popoutRect = Qt.rect(popup.anchorX, popup.anchorY + popup.cardY, popup.popoutWidth, popup.popoutHeight);
    }

    onWantOpenChanged: {
        if (wantOpen) {
            loaded = true;
            if (root.geometry.panelWindow)
                root.contentController.calendarController.open(root.contentController.now, root.geometry.panelWindow.screen);
        }
    }
    onExternalChildWindowOpenChanged: {
        if (externalChildWindowOpen)
            loaded = true;
    }
    Component.onCompleted: {
        if (wantOpen || externalChildWindowOpen)
            loaded = true;
    }

    // Construct the calendar popup lazily on first open and retain its Wayland/EGL surface.
    Loader {
        id: calendarLoader

        active: root.loaded
        asynchronous: false

        sourceComponent: Component {
            HoverPopupWindow {
                id: calendarWindow
                objectName: "calendar-popup-window"

                readonly property bool verticalBar: Theme.barPosition === "left" || Theme.barPosition === "right"
                readonly property real backingHeight: verticalBar ? calendarPopout.maximumViewHeight : calendarPopout.height
                readonly property real cardY: verticalBar ? root.geometry.popupY(calendarPopout.height, root.geometry.openPanelY) - root.geometry.popupY(backingHeight, root.geometry.openPanelY) : 0
                readonly property real popoutWidth: calendarPopout.width
                readonly property real popoutHeight: calendarPopout.height

                function dismissEventMenu() {
                    calendarPopout.dismissEventMenu();
                }

                anchorWindow: root.geometry.panelWindow
                anchorX: root.geometry.popupX(calendarPopout.width, root.geometry.openPanelX)
                anchorY: root.geometry.popupY(backingHeight, root.geometry.openPanelY)
                contentWidth: calendarPopout.width
                // Keep the Wayland surface stable while the card shrinks. This lets Qt
                // damage and clear the area formerly occupied by the day view.
                contentHeight: backingHeight
                open: root.wantOpen
                persistentKeyboardFocus: open && root.surfaceController.keyboardPanel === "calendar" && !root.contentController.calendarController.childWindowOpen
                dismissOnFocusClear: root.contentController.calendarController.eventMenuOpen && !root.externalChildWindowOpen
                onDismissRequested: root.dismissPopup()
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
        }
    }

    Connections {
        function onChildWindowOpenChanged() {
            if (root.geometry.active) {
                if (root.contentController.calendarController.childWindowOpen) {
                    root.updateChildAnchor();
                    const controller = root.contentController.calendarController;
                    if ((controller.detailsOpen || controller.editorOpen || controller.confirmDeleteOpen) && calendarLoader.item)
                        calendarLoader.item.releaseKeyboardFocus();
                }

                root.surfaceController.setInputPopupLocked(root.contentController.calendarController.childWindowOpen);
            }
        }

        target: root.contentController.calendarController
    }
}
