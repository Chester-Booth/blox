import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.modules
import qs.popouts
import qs.services
import qs.shared
import Blox.Widgets 1.0 as Widgets

Scope {
    id: fixture
    readonly property string surface: Quickshell.env("BLOX_TEST_SURFACE") || "system"
    readonly property var outputScreen: Quickshell.screens.length ? Quickshell.screens[0] : null
    readonly property int shortHeight: Number(Quickshell.env("BLOX_TEST_MAX_HEIGHT") || 420)

    QtObject {
        id: focusOwner
        function requestKeyboardFocus() { systemPopup.requestKeyboardFocus(); }
    }
    QtObject {
        id: fakeActionProvider
        function action(operation, value) { return {ok: true, code: "ok", message: "", data: {operation: operation, value: value}}; }
    }
    QtObject {
        id: fakePowerActions
        property bool powerBusy: false
        property string powerError: "Fixture power action failed: permission denied"
        signal powerFinished(bool success)
    }
    QtObject {
        id: fakeNotification
        property string summary: "Fixture notification"
        property string body: "This notification is provided by the isolated interaction fixture."
        property string appName: "Blox fixture"
        property int urgency: 1
        property double bloxReceivedAt: Date.now()
        property var actions: []
        function dismiss() {}
    }

    ClipboardController { id: clipboardController }

    PanelWindow {
        id: host
        screen: fixture.outputScreen
        visible: fixture.surface !== "clipboard"
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }

        Loader {
            anchors.fill: parent
            sourceComponent: fixture.surface === "widget" ? widgetSurface : null
        }
    }

    HoverPopupWindow {
        id: systemPopup
        anchorWindow: host
        anchorX: Math.max(8, Math.round((host.width - contentWidth) / 2))
        anchorY: Math.max(8, Math.round((host.height - contentHeight) / 2))
        contentWidth: 330
        contentHeight: systemDetails.height
        open: fixture.surface === "system"
        SystemPopout {
            id: systemDetails
            width: 330
            keyboardFocusWindow: systemPopup
            mode: "audio"
            title: "Audio"
            audioVolume: 68
            audioIcon: "󰕾"
            audioCanChange: true
            audioProvider: fakeActionProvider
            micCanChange: true
            micMuted: false
            onAction: (command, keepOpen) => {}
            onLevelPreview: (kind, value, muted) => {}
        }
    }

    HoverPopupWindow {
        id: performancePopup
        anchorWindow: host
        anchorX: Math.max(8, Math.round((host.width - contentWidth) / 2))
        anchorY: Math.max(8, Math.round((host.height - contentHeight) / 2))
        contentWidth: performanceDetails.width
        contentHeight: performanceDetails.height
        open: fixture.surface === "performance"
        PerformancePopout {
            id: performanceDetails
            maxWidth: Math.min(420, host.width - 24)
            maxHeight: Math.min(fixture.shortHeight, host.height - 24)
            status: ({cpuName: "Fixture CPU", uptimeLabel: "2h 14m", fan1Rpm: 1180, fan2Rpm: 920, powerW: 42, vramTotal: 8192, vramUsed: 3584})
            batteryStatus: ({icon: "󰁹", timeLabel: "3h 20m", class: "normal"})
            powerProfileStatus: ({profile: "balanced", capability: {ready: false, canChange: false}, profiles: []})
            vendorPerformanceStatus: ({profile: "balanced", capability: {canChange: false}, fanCurveCapability: {canChange: false}, fanCurveEnabled: false, profiles: []})
            gpuStatus: ({mode: "hybrid", label: "Hybrid", capability: {canChange: false}, supportedModes: []})
            monitorStatus: ({monitors: []})
            statusError: "Fixture status error for visual review"
        }
    }

    HoverPopupWindow {
        id: notificationsPopup
        anchorWindow: host
        anchorX: Math.max(8, Math.round((host.width - contentWidth) / 2))
        anchorY: Math.max(8, Math.round((host.height - contentHeight) / 2))
        contentWidth: notifications.width
        contentHeight: notifications.height
        open: fixture.surface.indexOf("notifications") === 0
        NotificationCenterPopout {
            id: notifications
            maxPopoutHeight: Math.min(640, host.height - 24)
            notifications: fixture.surface === "notifications-empty" ? [] : [fakeNotification]
            onActivate: notification => {}
            onActionInvoked: notification => {}
            onToggleDnd: {}
        }
    }

    PowerOverlayWindow {
        targetScreen: fixture.outputScreen
        open: fixture.surface === "power"
        actions: fakePowerActions
        updateSummary: "4 updates"
        onAction: command => {}
        onClose: {}
    }

    Component {
        id: widgetSurface
        Item {
            Widgets.WidgetHost {
                placementBounds: Qt.rect(0, 0, parent.width, parent.height)
                widget: ({id: "fixture-notes", kind: "notes", name: "Fixture notes", enabled: true,
                    placement: {anchor: "centre", x: 0, y: 0, width: 360, height: 220},
                    workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
                    appearance: {backgroundOpacity: 0.94, scrollbars: "auto"},
                    fullscreen: {enabled: false, mode: "native"},
                    settings: {title: "Simulated notes", text: Array.from({length: 40}, (_, index) => "Simulated widget line " + (index + 1)).join("\n")}})
            }
        }
    }

    ClipboardPicker {
        targetScreen: fixture.outputScreen
        controller: clipboardController
        positionReady: true
        watcherHealthy: false
        open: fixture.surface === "clipboard"
    }
    Timer {
        interval: 700
        running: fixture.surface === "clipboard"
        repeat: false
        onTriggered: clipboardController.error = "Fixture clipboard history is unavailable"
    }
}
