import qs.services
import qs.shared
import QtQuick

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property NotificationController notificationController
    readonly property bool wantOpen: root.geometry.active && root.surfaceController.openPanel === "notifications"
    property bool loaded: false

    onWantOpenChanged: if (wantOpen) loaded = true
    Component.onCompleted: if (wantOpen) loaded = true

    Loader {
        id: notificationLoader

        active: root.loaded
        asynchronous: false

        sourceComponent: Component {
            HoverPopupWindow {
                anchorWindow: root.geometry.panelWindow
                anchorX: root.geometry.popupX(notificationCenter.width, root.geometry.openPanelX)
                anchorY: root.geometry.popupY(notificationCenter.height, root.geometry.openPanelY)
                contentWidth: notificationCenter.width
                contentHeight: notificationCenter.height
                open: root.wantOpen
                persistentKeyboardFocus: open && root.surfaceController.keyboardPanel === "notifications"
                onDismissRequested: root.surfaceController.closePanel()
                onHoverEntered: root.surfaceController.popoutEntered()
                onHoverExited: root.surfaceController.popoutExited()

                NotificationCenterPopout {
                    id: notificationCenter

                    actionResult: root.notificationController.actionResult
                    notifications: root.notificationController.items || []
                    dnd: root.notificationController.dnd
                    // A horizontal panel is only one bar-thickness tall. Size against the
                    // screen instead, otherwise the notification header consumes the
                    // whole 240px minimum and the list is clipped.
                    maxPopoutHeight: Math.min(720, Math.max(240, root.geometry.screenHeight - 16))
                    onToggleDnd: root.notificationController.toggleDnd()
                    onActivate: (notification) => {
                        return root.notificationController.activate(notification);
                    }
                    onActionInvoked: (notification) => {
                        return root.notificationController.focusSource(notification);
                    }
                }
            }
        }
    }
}
