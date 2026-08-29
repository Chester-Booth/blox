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

            readonly property int barInset: Math.max(0, Theme.barEdgeInset)
            // Reserve the bar and one equal inset on each side of the bar.
            // This keeps the gap from the screen edge to the bar equal to the
            // gap from the bar to the window area.
            readonly property int barDepth: Theme.railWidth + barInset * 2
            // Keep a smaller inset at the two open ends of the bar.
            readonly property int barEndInset: Math.round(barInset / 2)

            screen: modelData
            implicitWidth: barSurfaceController.horizontalBar ? modelData.width : (barSurfaceController.barVisible || barSurfaceController.barSlide > 0.01 ? barDepth : 1)
            implicitHeight: barSurfaceController.horizontalBar ? (barSurfaceController.barVisible || barSurfaceController.barSlide > 0.01 ? barDepth : 1) : modelData.height
            exclusiveZone: barSurfaceController.barPinnedOpen ? Math.round(barDepth * barSurfaceController.barSlide) : 0
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
                x: barSurfaceController.horizontalBar ? panel.barEndInset : Theme.barPosition === "left" ? panel.barInset + Math.round(-panel.barDepth * (1 - barSurfaceController.barSlide)) : Theme.barPosition === "right" ? panel.barInset + Math.round(panel.barDepth * (1 - barSurfaceController.barSlide)) : 0
                y: barSurfaceController.horizontalBar ? (Theme.barPosition === "top" ? panel.barInset + Math.round(-panel.barDepth * (1 - barSurfaceController.barSlide)) : Theme.barPosition === "bottom" ? panel.barInset + Math.round(panel.barDepth * (1 - barSurfaceController.barSlide)) : 0) : panel.barEndInset
                width: barSurfaceController.horizontalBar ? Math.max(0, parent.width - panel.barEndInset * 2) : Theme.railWidth
                height: barSurfaceController.horizontalBar ? Theme.railWidth : Math.max(0, parent.height - panel.barEndInset * 2)
                radius: Math.min(Theme.barScaledRadius(12), Math.min(width, height) / 2)
                color: Theme.barSeparateGroups ? "transparent" : Theme.background
                border.color: Theme.border
                border.width: !Theme.barSeparateGroups && Theme.barBorder ? 1 : 0

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
                    readonly property real alongSurfacePadding: Theme.barScaledSpacing(4)
                    // Keep the surface inside the fixed 34 px bar when a
                    // button plus the normal padding would be too tall.
                    readonly property real crossSurfacePadding: Math.min(alongSurfacePadding, Math.max(0, (Theme.railWidth - Theme.buttonSize) / 2))
                    readonly property real trayJoinExtent: Math.min(Theme.barScaledRadius(12), Theme.railWidth / 2)
                    readonly property real horizontalSurfacePadding: barSurfaceController.horizontalBar ? alongSurfacePadding : crossSurfacePadding
                    readonly property real verticalSurfacePadding: barSurfaceController.horizontalBar ? crossSurfacePadding : alongSurfacePadding
                    readonly property point verticalTrayPoint: mappedTrayPoint(verticalTrayToggleItem)
                    readonly property point horizontalTrayPoint: mappedTrayPoint(horizontalTrayToggleItem)
                    readonly property real verticalContentStart: {
                        let edge = verticalStartRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && verticalTrayRegion === "start" && verticalTrayToggleItem && verticalTrayToggleItem.trayOpensForward)
                            edge = Math.max(edge, verticalExpandedTray.settledY + verticalExpandedTrayContent.height + verticalExpandedTray.alongPadding);

                        return edge;
                    }
                    readonly property real verticalContentEnd: {
                        let edge = height - verticalEndRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && verticalTrayRegion === "end" && verticalTrayToggleItem && !verticalTrayToggleItem.trayOpensForward)
                            edge = Math.min(edge, verticalExpandedTray.settledY - verticalExpandedTray.alongPadding);

                        return edge;
                    }
                    readonly property real horizontalContentStart: {
                        let edge = horizontalStartRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && horizontalTrayRegion === "start" && horizontalTrayToggleItem && horizontalTrayToggleItem.trayOpensForward)
                            edge = Math.max(edge, horizontalExpandedTray.settledX + horizontalExpandedTrayContent.width + horizontalExpandedTray.alongPadding);

                        return edge;
                    }
                    readonly property real horizontalContentEnd: {
                        let edge = width - horizontalEndRegion.minimumExtent;
                        if (barSurfaceController.trayOpen && horizontalTrayRegion === "end" && horizontalTrayToggleItem && !horizontalTrayToggleItem.trayOpensForward)
                            edge = Math.min(edge, horizontalExpandedTray.settledX - horizontalExpandedTray.alongPadding);

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
                    anchors.leftMargin: barSurfaceController.horizontalBar ? alongSurfacePadding : crossSurfacePadding
                    anchors.rightMargin: barSurfaceController.horizontalBar ? alongSurfacePadding : crossSurfacePadding
                    anchors.topMargin: barSurfaceController.horizontalBar ? crossSurfacePadding : alongSurfacePadding
                    anchors.bottomMargin: barSurfaceController.horizontalBar ? crossSurfacePadding : alongSurfacePadding

                    component GroupSurface: Rectangle {
                        required property Item regionItem

                        visible: Theme.barSeparateGroups && regionItem.visible && regionItem.width > 0 && regionItem.height > 0
                        x: regionItem.x - configuredRail.horizontalSurfacePadding
                        y: regionItem.y - configuredRail.verticalSurfacePadding
                        width: regionItem.width + configuredRail.horizontalSurfacePadding * 2
                        height: regionItem.height + configuredRail.verticalSurfacePadding * 2
                        z: 110
                        radius: Math.max(0, Math.min(Theme.barScaledRadius(12), Math.min(width, height) / 2))
                        color: Theme.background
                        border.color: Theme.border
                        border.width: Theme.barBorder ? 1 : 0
                    }

                    component TraySurface: Rectangle {
                        id: traySurface

                        required property var trayItem
                        required property bool horizontal
                        required property bool arrowAtStart
                        required property real joinExtent

                        visible: Theme.barSeparateGroups && trayItem.visible && trayItem.width > 0 && trayItem.height > 0
                        enabled: false
                        anchors.fill: parent
                        z: -1
                        transform: Translate {
                            x: trayItem.slideOffsetX
                            y: trayItem.slideOffsetY
                        }
                        radius: Math.max(0, Math.min(Theme.barScaledRadius(12), Math.min(width, height) / 2))
                        color: Theme.background
                        border.color: Theme.border
                        border.width: Theme.barBorder ? 1 : 0

                        // The arrow-side corner belongs to the stable toggle,
                        // so the tray surface must continue behind it instead
                        // of ending in a second rounded corner.
                        Rectangle {
                            id: trayJoin

                            x: traySurface.horizontal && !traySurface.arrowAtStart ? parent.width - traySurface.joinExtent : 0
                            y: !traySurface.horizontal && !traySurface.arrowAtStart ? parent.height - traySurface.joinExtent : 0
                            width: traySurface.horizontal ? traySurface.joinExtent : parent.width
                            height: traySurface.horizontal ? parent.height : traySurface.joinExtent
                            color: Theme.background
                            border.width: 0
                            z: 1

                            Rectangle {
                                visible: Theme.barBorder
                                color: Theme.border
                                x: 0
                                y: 0
                                width: traySurface.horizontal ? parent.width : 1
                                height: traySurface.horizontal ? 1 : parent.height
                            }

                            Rectangle {
                                visible: Theme.barBorder
                                color: Theme.border
                                x: traySurface.horizontal ? 0 : parent.width - 1
                                y: traySurface.horizontal ? parent.height - 1 : 0
                                width: traySurface.horizontal ? parent.width : 1
                                height: traySurface.horizontal ? 1 : parent.height
                            }
                        }
                    }

                    GroupSurface {
                        regionItem: verticalStartRegion
                    }

                    GroupSurface {
                        regionItem: verticalCentreRegion
                    }

                    GroupSurface {
                        regionItem: verticalEndRegion
                    }

                    GroupSurface {
                        regionItem: horizontalStartRegion
                    }

                    GroupSurface {
                        regionItem: horizontalCentreRegion
                    }

                    GroupSurface {
                        regionItem: horizontalEndRegion
                    }

                    BarRegion {
                        id: verticalStartRegion

                        visible: !barSurfaceController.horizontalBar
                        z: 120
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
                        z: 120
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
                        z: 120
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
                        z: 120
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
                        z: 120
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
                        z: 120
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

                    Item {
                        id: verticalExpandedTray

                        readonly property real alongPadding: configuredRail.alongSurfacePadding
                        readonly property real crossPadding: configuredRail.crossSurfacePadding
                        readonly property real openingDirection: configuredRail.verticalTrayToggleItem && configuredRail.verticalTrayToggleItem.trayOpensForward ? 1 : -1
                        readonly property real joinExtent: configuredRail.trayJoinExtent
                        // The surface padding extends under the arrow-side
                        // rounding; the stable arrow then covers the join.
                        readonly property real settledY: configuredRail.verticalTrayToggleItem && configuredRail.verticalTrayToggleItem.trayOpensForward ? configuredRail.verticalTrayPoint.y + configuredRail.verticalTrayToggleItem.height : configuredRail.verticalTrayPoint.y - verticalExpandedTrayContent.height
                        readonly property real slideOffsetX: 0
                        readonly property real slideOffsetY: -openingDirection * (height + verticalExpandedTrayContent.spacing) * (1 - slideProgress)
                        property real slideProgress: barSurfaceController.trayOpen ? 1 : 0

                        visible: !barSurfaceController.horizontalBar && configuredRail.verticalTrayToggleItem && (barSurfaceController.trayOpen || slideProgress > 0.001)
                        // Sit above the group surface so the tray background
                        // can cover the arrow-side join, but below the stable
                        // bar regions that contain the arrow and its items.
                        z: 115
                        x: configuredRail.verticalTrayPoint.x - crossPadding
                        y: settledY - alongPadding - (openingDirection > 0 ? joinExtent : 0)
                        width: verticalExpandedTrayContent.width + crossPadding * 2
                        height: verticalExpandedTrayContent.height + alongPadding * 2 + joinExtent
                        clip: true

                        Behavior on slideProgress {
                            NumberAnimation {
                                duration: 160
                                easing.type: Easing.OutCubic
                            }

                        }

                        Column {
                            id: verticalExpandedTrayContent

                            readonly property real slideOffsetX: 0
                            readonly property real slideOffsetY: verticalExpandedTray.slideOffsetY
                            x: verticalExpandedTray.crossPadding
                            y: verticalExpandedTray.alongPadding + (verticalExpandedTray.openingDirection > 0 ? verticalExpandedTray.joinExtent : 0)
                            width: implicitWidth
                            height: implicitHeight
                            spacing: Theme.barScaledSpacing(2)

                            transform: Translate {
                                y: verticalExpandedTray.slideOffsetY
                            }

                            HoverHandler {
                                margin: Math.max(configuredRail.alongSurfacePadding, configuredRail.crossSurfacePadding)
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

                        TraySurface {
                            trayItem: verticalExpandedTrayContent
                            horizontal: false
                            arrowAtStart: verticalExpandedTray.openingDirection > 0
                            joinExtent: verticalExpandedTray.joinExtent
                        }

                    }

                    Item {
                        id: horizontalExpandedTray

                        readonly property real alongPadding: configuredRail.alongSurfacePadding
                        readonly property real crossPadding: configuredRail.crossSurfacePadding
                        readonly property real openingDirection: configuredRail.horizontalTrayToggleItem && configuredRail.horizontalTrayToggleItem.trayOpensForward ? 1 : -1
                        readonly property real joinExtent: configuredRail.trayJoinExtent
                        // The surface padding extends under the arrow-side
                        // rounding; the stable arrow then covers the join.
                        readonly property real settledX: configuredRail.horizontalTrayToggleItem && configuredRail.horizontalTrayToggleItem.trayOpensForward ? configuredRail.horizontalTrayPoint.x + configuredRail.horizontalTrayToggleItem.width : configuredRail.horizontalTrayPoint.x - horizontalExpandedTrayContent.width
                        readonly property real slideOffsetX: -openingDirection * (width + horizontalExpandedTrayContent.spacing) * (1 - slideProgress)
                        readonly property real slideOffsetY: 0
                        property real slideProgress: barSurfaceController.trayOpen ? 1 : 0

                        visible: barSurfaceController.horizontalBar && configuredRail.horizontalTrayToggleItem && (barSurfaceController.trayOpen || slideProgress > 0.001)
                        // Sit above the group surface so the tray background
                        // can cover the arrow-side join, but below the stable
                        // bar regions that contain the arrow and its items.
                        z: 115
                        x: settledX - alongPadding - (openingDirection > 0 ? joinExtent : 0)
                        y: configuredRail.horizontalTrayPoint.y - crossPadding
                        width: horizontalExpandedTrayContent.width + alongPadding * 2 + joinExtent
                        height: horizontalExpandedTrayContent.height + crossPadding * 2
                        clip: true

                        Behavior on slideProgress {
                            NumberAnimation {
                                duration: 160
                                easing.type: Easing.OutCubic
                            }

                        }

                        Row {
                            id: horizontalExpandedTrayContent

                            readonly property real slideOffsetX: horizontalExpandedTray.slideOffsetX
                            readonly property real slideOffsetY: 0
                            x: horizontalExpandedTray.alongPadding + (horizontalExpandedTray.openingDirection > 0 ? horizontalExpandedTray.joinExtent : 0)
                            y: horizontalExpandedTray.crossPadding
                            width: implicitWidth
                            height: implicitHeight
                            spacing: Theme.barScaledSpacing(2)

                            transform: Translate {
                                x: horizontalExpandedTray.slideOffsetX
                            }

                            HoverHandler {
                                margin: Math.max(configuredRail.alongSurfacePadding, configuredRail.crossSurfacePadding)
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

                        TraySurface {
                            trayItem: horizontalExpandedTrayContent
                            horizontal: true
                            arrowAtStart: horizontalExpandedTray.openingDirection > 0
                            joinExtent: horizontalExpandedTray.joinExtent
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
