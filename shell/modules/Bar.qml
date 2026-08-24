import qs.popouts
import qs.services
import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: root

    property bool barOpen: true
    readonly property alias controller: barSurfaceController

    BarSurfaceController {
        id: barSurfaceController

        barOpen: root.barOpen
    }

    UiState {
        id: uiState
    }

    NotificationController {
        id: barNotificationController

        openPanel: barSurfaceController.openPanel
        openPanelY: barSurfaceController.openPanelY
        dnd: uiState.notificationDnd
        actionRunner: barContentController
        persistentState: uiState
        // Machine-specific focus helper. Users opt in through
        // BLOX_NOTIFICATION_FOCUS_SCRIPT; the feature stays off when unset.
        focusScript: Quickshell.env("BLOX_NOTIFICATION_FOCUS_SCRIPT") || ""
        onOpenRequested: (centreY) => {
            return barSurfaceController.openHoverPanel("notifications", centreY);
        }
        onCloseRequested: barSurfaceController.closePanel()
    }

    WorkspaceController {
        id: barWorkspaceController

        scriptRoot: barSurfaceController.scriptRoot
        items: barContentController.workspaces.json.main || []
        special: barContentController.workspaces.json.special || ({
        })
        onStatusRefreshRequested: barContentController.workspaces.refresh()
        onPrivacyRefreshRequested: barContentController.privacy.refresh()
        onFocusedMonitorChanged: barSurfaceController.syncActiveScreenToFocus()
    }

    BarContentController {
        id: barContentController

        scriptRoot: barSurfaceController.scriptRoot
        barVisible: barSurfaceController.barVisible
        openPanel: barSurfaceController.openPanel
    }

    CalendarEventWindows {
        controller: barContentController.calendarController
        targetScreen: barSurfaceController.activeScreen
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: panel

            required property var modelData

            function claimScreen() {
                barSurfaceController.activeScreen = modelData;
            }

            screen: modelData
            implicitWidth: barSurfaceController.horizontalBar ? modelData.width : (barSurfaceController.barVisible || barSurfaceController.barSlide > 0.01 ? Theme.railWidth : 1)
            implicitHeight: barSurfaceController.horizontalBar ? (barSurfaceController.barVisible || barSurfaceController.barSlide > 0.01 ? Theme.railWidth : 1) : modelData.height
            exclusiveZone: barSurfaceController.barPinnedOpen ? Math.round(Theme.railWidth * barSurfaceController.barSlide) : 0
            focusable: false
            visible: Theme.ready
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "blox-bar"

            anchors {
                left: Theme.barPosition === "left"
                right: Theme.barPosition === "right"
                top: Theme.barPosition === "top" || !barSurfaceController.horizontalBar
                bottom: Theme.barPosition === "bottom" || !barSurfaceController.horizontalBar
            }

            MouseArea {
                readonly property int triggerLength: Math.ceil((barSurfaceController.horizontalBar ? parent.width : parent.height) / 5)

                z: -1
                x: barSurfaceController.horizontalBar ? parent.width - width : Theme.barPosition === "right" ? parent.width - width : 0
                y: barSurfaceController.horizontalBar ? Theme.barPosition === "bottom" ? parent.height - height : 0 : parent.height - height
                width: barSurfaceController.horizontalBar ? triggerLength : 1
                height: barSurfaceController.horizontalBar ? 1 : triggerLength
                acceptedButtons: Qt.NoButton
                hoverEnabled: true
                onEntered: {
                    panel.claimScreen();
                    barSurfaceController.enterEdgeTrigger();
                }
                onExited: barSurfaceController.leaveEdgeTrigger()
            }

            Rectangle {
                x: Theme.barPosition === "left" ? Math.round(-Theme.railWidth * (1 - barSurfaceController.barSlide)) : Theme.barPosition === "right" ? Math.round(Theme.railWidth * (1 - barSurfaceController.barSlide)) : 0
                y: Theme.barPosition === "top" ? Math.round(-Theme.railWidth * (1 - barSurfaceController.barSlide)) : Theme.barPosition === "bottom" ? Math.round(Theme.railWidth * (1 - barSurfaceController.barSlide)) : 0
                width: barSurfaceController.horizontalBar ? parent.width : Theme.railWidth
                height: barSurfaceController.horizontalBar ? Theme.railWidth : parent.height
                color: Theme.background

                HoverHandler {
                    onHoveredChanged: {
                        if (hovered)
                            panel.claimScreen();

                        barSurfaceController.railSurfaceHovered = hovered;
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: barSurfaceController.closeBarOverlays()
                }

                Item {
                    id: configuredRail

                    property var verticalTrayToggleItem: null
                    property var horizontalTrayToggleItem: null
                    property string verticalTrayRegion: ""
                    property string horizontalTrayRegion: ""
                    readonly property point verticalTrayPoint: mappedTrayPoint(verticalTrayToggleItem)
                    readonly property point horizontalTrayPoint: mappedTrayPoint(horizontalTrayToggleItem)
                    readonly property real verticalContentStart: {
                        let edge = verticalStartRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && verticalTrayRegion === "start" && verticalTrayToggleItem && verticalTrayToggleItem.trayOpensForward)
                            edge = Math.max(edge, verticalExpandedTray.y + verticalExpandedTray.height);

                        return edge;
                    }
                    readonly property real verticalContentEnd: {
                        let edge = height - verticalEndRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && verticalTrayRegion === "end" && verticalTrayToggleItem && !verticalTrayToggleItem.trayOpensForward)
                            edge = Math.min(edge, verticalExpandedTray.y);

                        return edge;
                    }
                    readonly property real horizontalContentStart: {
                        let edge = horizontalStartRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && horizontalTrayRegion === "start" && horizontalTrayToggleItem && horizontalTrayToggleItem.trayOpensForward)
                            edge = Math.max(edge, horizontalExpandedTray.x + horizontalExpandedTray.width);

                        return edge;
                    }
                    readonly property real horizontalContentEnd: {
                        let edge = width - horizontalEndRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && horizontalTrayRegion === "end" && horizontalTrayToggleItem && !horizontalTrayToggleItem.trayOpensForward)
                            edge = Math.min(edge, horizontalExpandedTray.x);

                        return edge;
                    }

                    function mappedTrayPoint(item) {
                        if (!item)
                            return Qt.point(0, 0);

                        // mapToItem() does not create bindings to ancestor
                        // geometry. Read the full chain so region resizing and
                        // preview rotation both recalculate the drawer point.
                        let geometryDependency = width + height;
                        let ancestor = item;
                        while (ancestor && ancestor !== configuredRail) {
                            geometryDependency += ancestor.x + ancestor.y + ancestor.width + ancestor.height;
                            ancestor = ancestor.parent;
                        }
                        const point = item.mapToItem(configuredRail, 0, 0);
                        return Qt.point(point.x + geometryDependency * 0, point.y);
                    }

                    function registerTrayToggle(item, horizontal, region) {
                        if (item.itemId !== "tray")
                            return ;

                        if (horizontal) {
                            horizontalTrayToggleItem = item;
                            horizontalTrayRegion = region;
                        } else {
                            verticalTrayToggleItem = item;
                            verticalTrayRegion = region;
                        }
                    }

                    function unregisterTrayToggle(item, horizontal) {
                        if (horizontal && horizontalTrayToggleItem === item) {
                            horizontalTrayToggleItem = null;
                            horizontalTrayRegion = "";
                        } else if (!horizontal && verticalTrayToggleItem === item) {
                            verticalTrayToggleItem = null;
                            verticalTrayRegion = "";
                        }
                    }

                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(4)

                    BarRegion {
                        id: verticalStartRegion

                        visible: !barSurfaceController.horizontalBar
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        regionItems: Theme.barStartItems
                        surfaceController: barSurfaceController
                        contentController: barContentController
                        workspaceController: barWorkspaceController
                        notificationController: barNotificationController
                        trayHost: configuredRail
                        horizontal: false
                        panelExtent: panel.height
                        region: "start"
                        maximumExtent: Math.max(0, Math.min(parent.height / 2 - verticalCentreRegion.minimumExtent / 2, parent.height - verticalEndRegion.minimumExtent))
                    }

                    BarRegion {
                        id: verticalCentreRegion

                        visible: !barSurfaceController.horizontalBar
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: Math.max(configuredRail.verticalContentStart, Math.min((parent.height - height) / 2, configuredRail.verticalContentEnd - height))
                        regionItems: Theme.barCentreItems
                        surfaceController: barSurfaceController
                        contentController: barContentController
                        workspaceController: barWorkspaceController
                        notificationController: barNotificationController
                        trayHost: configuredRail
                        horizontal: false
                        panelExtent: panel.height
                        region: "centre"
                        maximumExtent: Math.max(0, configuredRail.verticalContentEnd - configuredRail.verticalContentStart)
                    }

                    BarRegion {
                        id: verticalEndRegion

                        visible: !barSurfaceController.horizontalBar
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        regionItems: Theme.barEndItems
                        surfaceController: barSurfaceController
                        contentController: barContentController
                        workspaceController: barWorkspaceController
                        notificationController: barNotificationController
                        trayHost: configuredRail
                        horizontal: false
                        panelExtent: panel.height
                        region: "end"
                        maximumExtent: Math.max(0, parent.height - Math.max(verticalStartRegion.minimumExtent, parent.height / 2 + verticalCentreRegion.minimumExtent / 2))
                    }

                    BarRegion {
                        id: horizontalStartRegion

                        visible: barSurfaceController.horizontalBar
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        regionItems: Theme.barStartItems
                        surfaceController: barSurfaceController
                        contentController: barContentController
                        workspaceController: barWorkspaceController
                        notificationController: barNotificationController
                        trayHost: configuredRail
                        horizontal: true
                        panelExtent: panel.height
                        region: "start"
                        maximumExtent: Math.max(0, Math.min(parent.width / 2 - horizontalCentreRegion.minimumExtent / 2, parent.width - horizontalEndRegion.minimumExtent))
                    }

                    BarRegion {
                        id: horizontalCentreRegion

                        visible: barSurfaceController.horizontalBar
                        anchors.verticalCenter: parent.verticalCenter
                        x: Math.max(configuredRail.horizontalContentStart, Math.min((parent.width - width) / 2, configuredRail.horizontalContentEnd - width))
                        regionItems: Theme.barCentreItems
                        surfaceController: barSurfaceController
                        contentController: barContentController
                        workspaceController: barWorkspaceController
                        notificationController: barNotificationController
                        trayHost: configuredRail
                        horizontal: true
                        panelExtent: panel.height
                        region: "centre"
                        maximumExtent: Math.max(0, configuredRail.horizontalContentEnd - configuredRail.horizontalContentStart)
                    }

                    BarRegion {
                        id: horizontalEndRegion

                        visible: barSurfaceController.horizontalBar
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        regionItems: Theme.barEndItems
                        surfaceController: barSurfaceController
                        contentController: barContentController
                        workspaceController: barWorkspaceController
                        notificationController: barNotificationController
                        trayHost: configuredRail
                        horizontal: true
                        panelExtent: panel.height
                        region: "end"
                        maximumExtent: Math.max(0, parent.width - Math.max(horizontalStartRegion.minimumExtent, parent.width / 2 + horizontalCentreRegion.minimumExtent / 2))
                    }

                    Column {
                        id: verticalExpandedTray

                        visible: !barSurfaceController.horizontalBar && barSurfaceController.trayOpen && configuredRail.verticalTrayToggleItem
                        z: 100
                        x: configuredRail.verticalTrayPoint.x
                        y: configuredRail.verticalTrayToggleItem && configuredRail.verticalTrayToggleItem.trayOpensForward ? configuredRail.verticalTrayPoint.y + configuredRail.verticalTrayToggleItem.height + spacing : configuredRail.verticalTrayPoint.y - height - spacing
                        spacing: Theme.scaledSpacing(2)

                        HoverHandler {
                            margin: configuredRail.anchors.margins
                            onHoveredChanged: hovered ? barSurfaceController.trayBoundsEntered() : barSurfaceController.trayBoundsExited()
                        }

                        Repeater {
                            model: Theme.barHiddenItems.filter((item) => {
                                return item.id !== "tray";
                            })

                            BarItemDelegate {
                                required property var modelData

                                itemId: modelData.id
                                surfaceController: barSurfaceController
                                contentController: barContentController
                                workspaceController: barWorkspaceController
                                notificationController: barNotificationController
                                horizontal: false
                                panelExtent: panel.height
                            }

                        }

                    }

                    Row {
                        id: horizontalExpandedTray

                        visible: barSurfaceController.horizontalBar && barSurfaceController.trayOpen && configuredRail.horizontalTrayToggleItem
                        z: 100
                        x: configuredRail.horizontalTrayToggleItem && configuredRail.horizontalTrayToggleItem.trayOpensForward ? configuredRail.horizontalTrayPoint.x + configuredRail.horizontalTrayToggleItem.width + spacing : configuredRail.horizontalTrayPoint.x - width - spacing
                        y: configuredRail.horizontalTrayPoint.y
                        spacing: Theme.scaledSpacing(2)

                        HoverHandler {
                            margin: configuredRail.anchors.margins
                            onHoveredChanged: hovered ? barSurfaceController.trayBoundsEntered() : barSurfaceController.trayBoundsExited()
                        }

                        Repeater {
                            model: Theme.barHiddenItems.filter((item) => {
                                return item.id !== "tray";
                            })

                            BarItemDelegate {
                                required property var modelData

                                itemId: modelData.id
                                surfaceController: barSurfaceController
                                contentController: barContentController
                                workspaceController: barWorkspaceController
                                notificationController: barNotificationController
                                horizontal: true
                                panelExtent: panel.height
                            }

                        }

                    }

                }

            }

            PowerOverlayWindow {
                targetScreen: modelData
                open: barSurfaceController.activeScreen === modelData && barSurfaceController.openPanel === "power"
                updateSummary: barContentController.content.updateSummary()
                onAction: (kind) => {
                    return barContentController.run(barContentController.content.powerCommand(kind));
                }
                onClose: barSurfaceController.closePanel()
            }

            BarPopouts {
                panelWindow: panel
                active: barSurfaceController.activeScreen === modelData
                surfaceController: barSurfaceController
                contentController: barContentController
                notificationController: barNotificationController
                persistentState: uiState
            }

            BarNotificationToastSurface {
                targetScreen: modelData
                surfaceActive: barSurfaceController.activeScreen === modelData
                notificationController: barNotificationController
            }

        }

    }

}
