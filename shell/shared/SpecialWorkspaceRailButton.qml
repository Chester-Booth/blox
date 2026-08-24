import qs.shared

RailButton {
    id: root

    property var workspace

    signal activate()

    icon: workspace && workspace.icon ? workspace.icon : "󰘼"
    accent: workspace && workspace.active ? Theme.blue : Theme.muted
    active: !!(workspace && workspace.active)
    visible: !!(workspace && (workspace.active || workspace.occupied))
    onClicked: root.activate()
}
