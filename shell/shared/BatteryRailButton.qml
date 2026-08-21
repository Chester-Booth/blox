import "."

RailButton {
    id: root

    property var status
    property real popupY: 0

    signal toggleExpanded()
    signal systemPanelRequested(real centerY)
    signal systemPanelHovered(real centerY)
    signal systemPanelExited()

    icon: status && status.icon ? status.icon : "󰁹"
    accent: status && status.class === "critical" ? Theme.red : status && status.class === "charging" ? Theme.green : Theme.muted
    active: false
    onClicked: root.toggleExpanded()
    onHovered: (centerY) => {
        return root.systemPanelHovered(centerY);
    }
    onExited: root.systemPanelExited()
    onRightClicked: root.systemPanelRequested(popupY)
}
