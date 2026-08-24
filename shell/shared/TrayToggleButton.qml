import qs.shared

RailButton {
    id: root

    property bool horizontal: false
    property bool opensForward: false

    signal toggle()
    signal openRequested()

    icon: horizontal ? "󰅂" : "󰅀"
    // The collapsed arrow points towards the concealed tray items (outwards
    // from the toggle). Once expanded it points back towards the toggle.
    iconRotation: active === opensForward ? 180 : 0
    accent: Theme.foreground
    onClicked: root.toggle()
    onHovered: root.openRequested()
}
