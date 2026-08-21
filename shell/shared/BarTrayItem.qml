import QtQuick
import Quickshell.Services.SystemTray

Item {
    id: root

    required property string itemId
    required property BarItemContext context

    implicitWidth: loader.item ? loader.item.implicitWidth : 0
    implicitHeight: loader.item ? loader.item.implicitHeight : 0

    Loader {
        id: loader

        sourceComponent: root.itemId === "tray" ? trayToggleComponent : applicationTrayComponent
    }

    Component {
        id: trayToggleComponent

        Flow {
            flow: root.context.horizontal ? Flow.LeftToRight : Flow.TopToBottom
            width: root.context.horizontal ? implicitWidth : Theme.buttonSize
            height: root.context.horizontal ? Theme.buttonSize : implicitHeight

            TrayToggleButton {
                horizontal: root.context.horizontal
                opensForward: root.context.trayOpensForward
                active: root.context.surfaceController.trayOpen
                onToggle: root.context.surfaceController.toggleTray()
                onOpenRequested: {
                    root.context.surfaceController.openTray();
                    root.context.surfaceController.trayEntered();
                }
                onExited: root.context.surfaceController.trayExited()
            }

        }

    }

    Component {
        id: applicationTrayComponent

        Item {
            readonly property int trayCount: trayRepeater.count

            implicitWidth: root.context.horizontal ? trayCount * Theme.buttonSize : Theme.buttonSize
            implicitHeight: root.context.horizontal ? Theme.buttonSize : trayCount * Theme.buttonSize
            width: implicitWidth
            height: implicitHeight

            HoverHandler {
                onHoveredChanged: {
                    if (hovered)
                        root.context.surfaceController.trayEntered();
                    else
                        root.context.surfaceController.trayExited();
                }
            }

            Flow {
                anchors.fill: parent
                flow: root.context.horizontal ? Flow.LeftToRight : Flow.TopToBottom

                Repeater {
                    id: trayRepeater

                    model: SystemTray.items

                    TrayRailItem {
                        item: modelData
                        onHovered: root.context.surfaceController.trayItemEntered()
                        onOpenMenu: (item, centre) => {
                            return root.context.surfaceController.openTrayMenu(item, root.context.mappedCentre(this, centre));
                        }
                    }

                }

            }

        }

    }

}
