import "../services"
import "../shared"
import QtQuick

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property NotificationController notificationController

    HoverPopupWindow {
        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(notificationCenter.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(notificationCenter.height, root.geometry.openPanelY)
        contentWidth: notificationCenter.width
        contentHeight: notificationCenter.height
        open: root.geometry.active && root.surfaceController.openPanel === "notifications"
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()

        NotificationCenterPopout {
            id: notificationCenter

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
