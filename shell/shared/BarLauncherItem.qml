import QtQuick

Item {
    id: root

    required property string itemId
    required property BarItemContext context

    implicitWidth: loader.item ? loader.item.implicitWidth : 0
    implicitHeight: loader.item ? loader.item.implicitHeight : 0

    Loader {
        id: loader

        sourceComponent: root.itemId === "power" ? powerComponent : notesComponent
    }

    Component {
        id: powerComponent

        RailButton {
            icon: "󰤆"
            accent: Theme.foreground
            active: root.context.surfaceController.openPanel === "power"
            onClicked: (centre) => {
                return root.context.surfaceController.openHoverPanel("power", root.context.mappedCentre(this, centre));
            }
        }

    }

    Component {
        id: notesComponent

        PanelRailButton {
            icon: "󰺦"
            accent: Theme.foreground
            panel: "todo"
            active: root.context.surfaceController.openPanel === "todo"
            onPanelClicked: (panel, centre) => {
                return root.context.surfaceController.openHoverPanel(panel, root.context.mappedCentre(this, centre));
            }
            onPanelHovered: (panel, centre, source) => {
                return root.context.surfaceController.hoverButtonEntered(panel, root.context.mappedCentre(this, centre), source);
            }
            onPanelExited: (source) => {
                return root.context.surfaceController.hoverButtonExited(source);
            }
            onRightClicked: root.context.contentController.run(root.context.contentController.scriptRoot + "/todo/open.sh")
        }

    }

}
