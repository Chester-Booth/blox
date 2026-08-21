import QtQuick

Item {
    id: root

    required property BarItemContext context
    readonly property bool showIcon: context.batteryDisplay !== "numeric"
    readonly property bool showCapacity: context.batteryDisplay === "numeric" || context.batteryDisplay === "toggle" && context.contentController.batteryExpanded

    implicitWidth: context.horizontal && showIcon && showCapacity ? Theme.buttonSize * 2 : Theme.buttonSize
    implicitHeight: !context.horizontal && showIcon && showCapacity ? Theme.buttonSize * 2 : Theme.buttonSize
    width: implicitWidth
    height: implicitHeight

    BatteryRailButton {
        id: batteryButton

        x: 0
        y: 0
        visible: root.showIcon
        status: root.context.contentController.battery.json
        popupY: root.context.panelExtent - 24
        onToggleExpanded: {
            if (root.context.batteryDisplay !== "toggle")
                return ;

            const expanded = !root.context.contentController.batteryExpanded;
            root.context.surfaceController.closeBarOverlays();
            root.context.contentController.batteryExpanded = expanded;
        }
        onSystemPanelRequested: (centre) => {
            return root.context.surfaceController.openHoverPanel("system", root.context.mappedCentre(this, centre));
        }
        onSystemPanelHovered: (centre) => {
            return root.context.surfaceController.hoverButtonEntered("system", root.context.mappedCentre(this, centre), "battery");
        }
        onSystemPanelExited: root.context.surfaceController.hoverButtonExited("battery")
    }

    BatteryCapacityTile {
        x: root.context.horizontal && root.showIcon ? batteryButton.width : 0
        y: !root.context.horizontal && root.showIcon ? batteryButton.height : 0
        status: root.context.contentController.battery.json
        expanded: root.showCapacity
        collapsible: root.context.batteryDisplay === "toggle"
        onCollapse: root.context.contentController.batteryExpanded = false
        onPanelHovered: (centre) => {
            return root.context.surfaceController.hoverButtonEntered("system", root.context.mappedCentre(this, centre), "battery");
        }
        onPanelExited: root.context.surfaceController.hoverButtonExited("battery")
    }

}
