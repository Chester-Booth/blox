import qs.shared

RailButton {
    id: root

    property string panel: ""
    property string source: panel
    property real centerOffset: 0

    signal panelClicked(string panel, real centerY)
    signal panelHovered(string panel, real centerY, string source)
    signal panelExited(string source)

    onClicked: (centerY) => {
        return root.panelClicked(root.panel, centerY + root.centerOffset);
    }
    onHovered: (centerY) => {
        return root.panelHovered(root.panel, centerY + root.centerOffset, root.source);
    }
    onExited: root.panelExited(root.source)
}
