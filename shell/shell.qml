//@ pragma IconTheme Adwaita

import Blox.Services 1.0
import qs.modules
import qs.services
import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Scope {
    id: root

    property bool barOpen: true

    SettingsController {
        id: settingsController
        onWidgetsPublished: Theme.reloadWidgets()
    }

    IpcHandler {
        function toggle() : string {
            root.barOpen = !root.barOpen;
            return root.barOpen ? "visible" : "hidden";
        }

        target: "bar"
    }

    Bar {
        id: bar

        settingsController: settingsController
        barOpen: root.barOpen
        fullscreenWidgetOutputs: desktopWidgets.visibleFullscreenOutputs
    }

    Connections {
        function onOsdLevelPreview(kind, value, muted) {
            return osd.preview(kind, value, muted);
        }

        target: bar.controller
    }

    Osd {
        id: osd

        audioStatus: bar.audioStatus
    }

    Wallpaper {
    }

    DesktopWidgets {
        id: desktopWidgets
        occupiedBar: bar.controller.occupiedBar
        externalReservationsByOutput: bar.controller.externalReservationsByOutput
        onActionRequested: (widgetId, action, payload) => widgetActions.dispatch(widgetId, action, payload)
        onApplicationActionRequested: (action, identity, context) => widgetActions.dispatch(identity.widgetId, action, identity, context)
        onApplicationWorkflowReady: identity => widgetActions.workflowReady(identity)
        onApplicationWorkflowCancelled: identity => widgetActions.cancelWorkflow(identity)
    }

    WidgetActionController {
        id: widgetActions
        settingsWindow: settingsGateway
        validateCommandHost: function(identity, context) { return desktopWidgets.validateCommandHost(identity, context); }
        beginCommandWorkflow: function(identity, context) { return desktopWidgets.beginCommandWorkflow(identity, context); }
        finishCommandWorkflow: function(identity) { return desktopWidgets.finishCommandWorkflow(identity); }
        workspaceId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
        openCalendar: function() { return bar.controller.openKeyboardPanel("calendar"); }
    }

    SettingsGateway {
        id: settingsGateway
        settingsController: settingsController
    }

    ShortcutGuide {
    }

    Launcher {
    }
}
