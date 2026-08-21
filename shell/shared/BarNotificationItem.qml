import QtQuick

PanelRailButton {
    id: root

    required property BarItemContext context

    icon: context.notificationController.status().icon || "󰂜"
    accent: context.notificationController.dnd ? Theme.yellow : context.notificationController.status().count > 0 ? Theme.blue : Theme.foreground
    panel: "notifications"
    active: context.surfaceController.openPanel === panel
    onPanelClicked: (panel, centre) => {
        context.publishNotificationPosition();
        context.surfaceController.closeBarOverlays();
        context.surfaceController.openHoverPanel(panel, context.mappedCentre(this, centre));
    }
    onPanelHovered: (panel, centre, source) => {
        context.publishNotificationPosition();
        return context.surfaceController.hoverButtonEntered(panel, context.mappedCentre(this, centre), source);
    }
    onPanelExited: (source) => {
        return context.surfaceController.hoverButtonExited(source);
    }
    onRightClicked: context.notificationController.clear()
}
