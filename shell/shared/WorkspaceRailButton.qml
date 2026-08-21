import "."
import QtQuick

RailButton {
    id: root

    property var item
    property bool blinking: true

    signal activate()

    icon: item ? item.icon : ""
    accent: item && item.urgent ? Theme.red : item && item.active ? Theme.blue : item && item.empty ? Theme.muted : Theme.foreground
    active: !!(item && item.active)
    alert: !!(item && item.urgent) && blinking
    onClicked: root.activate()
}
