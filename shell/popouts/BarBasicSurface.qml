import qs.services
import qs.shared
import QtQuick

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    required property NotificationController notificationController

    function runAction(command, keepOpen) {
        if (command === "__refresh_updates") {
            contentController.updates.refresh();
            return ;
        }
        if (command === "__clear_notifications") {
            notificationController.clear();
            if (!keepOpen)
                surfaceController.closePanel();

            return ;
        }
        contentController.run(command);
        if (!keepOpen)
            surfaceController.closePanel();

    }

    HoverPopupWindow {
        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(basicPopout.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(basicPopout.height, root.geometry.openPanelY)
        contentWidth: 320
        contentHeight: basicPopout.height
        open: root.geometry.active && ["updates", "privacy", "caffeine"].indexOf(root.surfaceController.openPanel) >= 0
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()

        BasicPopout {
            id: basicPopout

            width: 320
            title: root.contentController.content.panelTitle()
            subtitle: root.contentController.content.panelSubtitle()
            body: root.contentController.content.panelBody()
            statusError: root.contentController.statusError(root.surfaceController.openPanel)
            actions: root.contentController.content.panelActions()
            currentId: root.surfaceController.openPanel === "caffeine" ? (root.contentController.caffeine.json.mode || "off") : ""
            headerActionIcon: root.contentController.content.panelHeaderActionIcon()
            headerActionCommand: root.contentController.content.panelHeaderActionCommand()
            headerStatus: root.contentController.content.panelHeaderStatus()
            onAction: (command, keepOpen) => {
                root.runAction(command, keepOpen);
            }
        }

    }

}
