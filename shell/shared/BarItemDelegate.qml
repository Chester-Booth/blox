import qs.shared
import qs.services
import QtQuick

Item {
    id: root

    required property string itemId
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    required property WorkspaceController workspaceController
    required property NotificationController notificationController
    property bool horizontal: false
    property real panelExtent: 0
    property real maximumExtent: Number.POSITIVE_INFINITY
    property bool trayOpensForward: false
    readonly property var itemConfig: Theme.barItems.find((item) => {
        return item.id === root.itemId;
    }) || ({
    })
    readonly property string batteryDisplay: itemConfig.display || "toggle"
    readonly property string itemVisibility: itemConfig.visibility || "normal"
    readonly property bool capabilitySuppressed: {
        const sources = {
            "wifi": contentController.network.json,
            "sound": contentController.audio.json,
            "display": contentController.brightness.json,
            "bt": contentController.bluetooth.json,
            "privacy": contentController.privacy.json,
            "awake": contentController.caffeine.json,
            "updates": contentController.updates.json,
            "touchpad": contentController.touchpad.json,
            "fan": contentController.vendorPerformance.json,
            "gpu": contentController.gpu.json
        };
        const status = sources[root.itemId];
        return !!(status && status.capability && status.capability.available === false);
    }
    function suppressForRuntimeState() {
        return itemId === "privacy" ? contentController.privacy.json.active !== true : itemId === "touchpad" ? contentController.touchpad.json.enabled !== false : itemId === "fan" ? contentController.vendorPerformance.json.profile === undefined || contentController.vendorPerformance.json.profile === "quiet" : itemId === "gpu" ? contentController.gpu.json.mode === undefined || contentController.gpu.json.mode === "eco" : false;
    }
    readonly property bool runtimeSuppressed: itemVisibility === "always" ? false : (capabilitySuppressed || suppressForRuntimeState())
    readonly property bool contentVisible: contentLoader.item !== null && !runtimeSuppressed

    function mappedCentre(item, centre) {
        return itemContext.mappedCentre(item, centre);
    }

    function publishNotificationPosition() {
        if (itemId !== "notifications" || horizontal !== surfaceController.horizontalBar || !contentLoader.item)
            return ;

        notificationController.panelY = mappedCentre(contentLoader.item, contentLoader.item.height / 2);
    }

    onXChanged: publishNotificationPosition()
    onYChanged: publishNotificationPosition()
    onWidthChanged: publishNotificationPosition()
    onHeightChanged: publishNotificationPosition()
    onHorizontalChanged: publishNotificationPosition()
    Component.onCompleted: publishNotificationPosition()
    // Keep the cross-axis extent stable. Content such as the expandable battery
    // percentage must only grow along the bar, otherwise a click recentres the
    // whole vertical section and makes neighbouring icons jump sideways.
    visible: contentVisible
    implicitWidth: !contentVisible ? 0 : root.horizontal && contentLoader.item ? Math.max(Theme.buttonSize, contentLoader.item.implicitWidth) : Theme.buttonSize
    implicitHeight: !contentVisible ? 0 : !root.horizontal && contentLoader.item ? Math.max(Theme.buttonSize, contentLoader.item.implicitHeight) : Theme.buttonSize
    width: implicitWidth
    height: implicitHeight

    Connections {
        function onHorizontalBarChanged() {
            root.publishNotificationPosition();
        }

        target: root.surfaceController
    }

    BarItemContext {
        id: itemContext

        surfaceController: root.surfaceController
        contentController: root.contentController
        workspaceController: root.workspaceController
        notificationController: root.notificationController
        horizontal: root.horizontal
        panelExtent: root.panelExtent
        maximumExtent: root.maximumExtent
        trayOpensForward: root.trayOpensForward
        batteryDisplay: root.batteryDisplay
        notificationPositionPublisher: () => {
            return root.publishNotificationPosition();
        }
    }

    Loader {
        id: contentLoader

        anchors.fill: parent
        onLoaded: root.publishNotificationPosition()
        sourceComponent: {
            if (["power", "notes"].indexOf(root.itemId) >= 0)
                return launcherComponent;

            if (root.itemId === "workspaces")
                return workspacesComponent;

            if (root.itemId === "clock")
                return clockComponent;

            if (root.itemId === "active-window-title")
                return activeWindowTitleComponent;

            if (root.itemId === "battery")
                return batteryComponent;

            if (root.itemId === "notifications")
                return notificationsComponent;

            if (["wifi", "sound", "privacy", "awake", "display", "bt", "updates", "fan", "gpu", "touchpad"].indexOf(root.itemId) >= 0)
                return statusComponent;

            if (["tray", "application-tray"].indexOf(root.itemId) >= 0)
                return trayComponent;

            return null;
        }
    }

    Component {
        id: launcherComponent

        BarLauncherItem {
            itemId: root.itemId
            context: itemContext
        }

    }

    Component {
        id: workspacesComponent

        BarWorkspaceItem {
            context: itemContext
        }

    }

    Component {
        id: clockComponent

        BarClockItem {
            context: itemContext
        }

    }

    Component {
        id: batteryComponent

        BarBatteryItem {
            context: itemContext
        }

    }

    Component {
        id: activeWindowTitleComponent

        BarActiveWindowTitleItem {
            context: itemContext
        }

    }

    Component {
        id: notificationsComponent

        BarNotificationItem {
            context: itemContext
        }

    }

    Component {
        id: statusComponent

        BarStatusItem {
            itemId: root.itemId
            context: itemContext
        }

    }

    Component {
        id: trayComponent

        BarTrayItem {
            itemId: root.itemId
            context: itemContext
        }

    }

}
