import QtQuick

Item {
    id: root

    required property BarItemContext context

    implicitWidth: workspaceFlow.implicitWidth
    implicitHeight: workspaceFlow.implicitHeight

    Flow {
        id: workspaceFlow

        flow: root.context.horizontal ? Flow.TopToBottom : Flow.LeftToRight
        width: root.context.horizontal ? implicitWidth : Theme.buttonSize
        height: root.context.horizontal ? Theme.buttonSize : implicitHeight

        Repeater {
            model: root.context.workspaceController.items

            WorkspaceRailButton {
                item: modelData
                blinking: (modelData.urgent || root.context.workspaceController.hasAlert(modelData.id)) && root.context.workspaceController.blinkOn
                onActivate: {
                    root.context.surfaceController.closeBarOverlays();
                    root.context.workspaceController.focusWorkspace(modelData.id);
                    root.context.workspaceController.refresh();
                }
            }

        }

        SpecialWorkspaceRailButton {
            workspace: root.context.workspaceController.special
            onActivate: {
                root.context.surfaceController.closeBarOverlays();
                root.context.workspaceController.toggleSpecialWorkspace("magic");
                root.context.workspaceController.refresh();
            }
        }

    }

}
