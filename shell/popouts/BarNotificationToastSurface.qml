import qs.services
import qs.shared
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    required property var targetScreen
    required property bool surfaceActive
    required property NotificationController notificationController
    readonly property bool onLeft: Theme.notificationPosition === "top-left" || Theme.notificationPosition === "bottom-left"
    readonly property bool onRight: Theme.notificationPosition === "top-right" || Theme.notificationPosition === "bottom-right"
    readonly property bool onTop: Theme.notificationPosition.indexOf("top") >= 0
    readonly property bool onBottom: Theme.notificationPosition.indexOf("bottom") >= 0

    screen: targetScreen
    implicitWidth: targetScreen ? targetScreen.width : 1
    implicitHeight: targetScreen ? targetScreen.height : 1
    exclusiveZone: 0
    focusable: false
    visible: surfaceActive && notificationController.toastsEnabled && notificationController.toasts.length > 0 && !notificationController.dnd
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "blox-notifications"

    anchors {
        left: true
        right: true
        top: root.onTop
        bottom: root.onBottom
    }

    NotificationToastStack {
        id: notificationToasts

        // Numeric placement clears cleanly when a live preview moves
        // between opposite edges. Conditional anchors can retain both
        // sides for a frame and stretch the stack to the old edge.
        x: root.onLeft ? 12 + Theme.notificationOffsetX : root.onRight ? parent.width - width - 12 + Theme.notificationOffsetX : Math.round((parent.width - width) / 2 + Theme.notificationOffsetX)
        y: root.onTop ? 12 + Theme.notificationOffsetY : parent.height - height - 12 + Theme.notificationOffsetY
        position: Theme.notificationPosition
        visible: root.notificationController.toastsEnabled && root.notificationController.toasts.length > 0 && !root.notificationController.dnd
        toasts: root.notificationController.toasts
        activationLabel: (notification) => {
            return root.notificationController.activationLabel(notification);
        }
        onDismiss: (notification, closeNotification) => {
            root.notificationController.removeToast(notification);
            if (notification && closeNotification)
                notification.dismiss();

        }
        onActivate: (notification) => {
            return root.notificationController.activate(notification);
        }
        onActionInvoked: (notification) => {
            return root.notificationController.focusSource(notification);
        }
    }

    // The full-output surface gives every notification position the same
    // coordinate space. Only the visible cards accept pointer input.
    mask: Region {
        // Bind window-local geometry explicitly so the input region is
        // rebuilt when the hidden toast window appears and the stack's
        // implicit height changes.
        x: notificationToasts.x
        y: notificationToasts.y
        width: notificationToasts.width
        height: notificationToasts.height
    }

}
