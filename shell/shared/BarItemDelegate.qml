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
    property string region: ""
    property Item panelAnchorSource: null
    property var anchorScreen: null
    property string registeredAnchorPanel: ""
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
        const status = root.itemId === "fan" ? contentController.vendorPerformance.json.fanCurveCapability : sources[root.itemId] && sources[root.itemId].capability;
        return !!(status && status.available === false);
    }
    function suppressForRuntimeState() {
        return itemId === "privacy" ? contentController.privacy.json.active !== true : itemId === "touchpad" ? contentController.touchpad.json.enabled !== false : itemId === "fan" ? contentController.vendorPerformance.json.fanCurveEnabled !== true : itemId === "gpu" ? contentController.gpu.json.mode === undefined || contentController.gpu.json.mode === itemVisibility : false;
    }
    readonly property bool runtimeSuppressed: capabilitySuppressed || (itemVisibility === "always" ? false : suppressForRuntimeState())
    readonly property bool contentVisible: contentLoader.item !== null && !runtimeSuppressed
    readonly property string anchorPanel: {
        const panels = {
            "power": "power",
            "notes": "todo",
            "clock": "calendar",
            "battery": "system",
            "notifications": "notifications",
            "wifi": "network",
            "sound": "audio",
            "privacy": "privacy",
            "awake": "caffeine",
            "display": "brightness",
            "bt": "bluetooth",
            "updates": "updates",
            "fan": "system",
            "gpu": "system"
        };
        return panels[itemId] || "";
    }
    readonly property real panelAnchorCentre: {
        const source = panelAnchorSource || root;
        // mapToItem() does not bind to ancestor geometry, so read the full
        // chain to keep keyboard-opened popouts aligned during bar movement.
        let geometryDependency = 0;
        let ancestor = source;
        while (ancestor) {
            geometryDependency += Number(ancestor.x || 0) + Number(ancestor.y || 0)
                + Number(ancestor.width || 0) + Number(ancestor.height || 0);
            ancestor = ancestor.parent;
        }
        const point = source.mapToItem(null, source.width / 2, source.height / 2);
        return (horizontal ? point.x : point.y) + geometryDependency * 0;
    }
    readonly property bool panelAnchorAvailable: {
        if (!anchorPanel || !contentVisible || horizontal !== surfaceController.horizontalBar)
            return false;

        if (region === "hidden")
            return !!panelAnchorSource;

        let ancestor = root;
        while (ancestor) {
            if (ancestor.visible === false)
                return false;
            ancestor = ancestor.parent;
        }
        return true;
    }

    function mappedCentre(item, centre) {
        return itemContext.mappedCentre(item, centre);
    }

    function publishPanelAnchor() {
        if (registeredAnchorPanel && registeredAnchorPanel !== anchorPanel) {
            surfaceController.unregisterPanelAnchor(registeredAnchorPanel, root);
            registeredAnchorPanel = "";
        }

        if (!panelAnchorAvailable) {
            if (registeredAnchorPanel) {
                surfaceController.unregisterPanelAnchor(registeredAnchorPanel, root);
                registeredAnchorPanel = "";
            }
            return ;
        }

        surfaceController.registerPanelAnchor(anchorPanel, root, panelAnchorCentre, region === "hidden" ? 0 : 1, anchorScreen);
        registeredAnchorPanel = anchorPanel;
    }

    function publishNotificationPosition() {
        if (itemId !== "notifications" || horizontal !== surfaceController.horizontalBar || !contentLoader.item)
            return ;

        notificationController.panelY = panelAnchorCentre;
    }

    onXChanged: { publishNotificationPosition(); publishPanelAnchor(); }
    onYChanged: { publishNotificationPosition(); publishPanelAnchor(); }
    onWidthChanged: { publishNotificationPosition(); publishPanelAnchor(); }
    onHeightChanged: { publishNotificationPosition(); publishPanelAnchor(); }
    onHorizontalChanged: { publishNotificationPosition(); publishPanelAnchor(); }
    onRegionChanged: publishPanelAnchor()
    onPanelAnchorSourceChanged: publishPanelAnchor()
    onAnchorScreenChanged: publishPanelAnchor()
    onPanelAnchorCentreChanged: { publishNotificationPosition(); publishPanelAnchor(); }
    onAnchorPanelChanged: publishPanelAnchor()
    onPanelAnchorAvailableChanged: publishPanelAnchor()
    onContentVisibleChanged: publishPanelAnchor()
    onVisibleChanged: publishPanelAnchor()
    Component.onCompleted: { publishNotificationPosition(); publishPanelAnchor(); }
    Component.onDestruction: surfaceController.unregisterPanelAnchor(registeredAnchorPanel, root)
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
            root.publishPanelAnchor();
        }

        target: root.surfaceController
    }

    BarItemContext {
        id: itemContext

        surfaceController: root.surfaceController
        contentController: root.contentController
        workspaceController: root.workspaceController
        notificationController: root.notificationController
        panelAnchorOwner: root.region === "hidden" ? null : root
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
        onLoaded: {
            root.publishNotificationPosition();
            root.publishPanelAnchor();
        }
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
