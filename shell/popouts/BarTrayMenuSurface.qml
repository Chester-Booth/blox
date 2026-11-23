import qs.services
import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

Item {
    id: root

    readonly property alias menuView: trayMenuPopout
    readonly property bool iconHovered: menuWindow.overIcon
    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController

    // One focusable layer surface keeps keyboard focus as menu levels resize.
    PanelWindow {
        id: menuWindow
        screen: root.geometry.panelWindow ? root.geometry.panelWindow.screen : null
        anchors.top: true
        anchors.left: true
        // Keep the surface geometry stable while opening and closing menu levels.
        implicitWidth: root.geometry.screenWidth
        implicitHeight: root.geometry.screenHeight
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        focusable: true
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "blox-tray-menu"
        visible: root.geometry.active && root.surfaceController.trayMenuOpen && trayMenuPopout.rootPanel.rowCount > 0
        color: "transparent"
        property point pointerPosition: Qt.point(-1, -1)
        readonly property bool overIcon: pointerPosition.x >= iconGuard.x && pointerPosition.x < iconGuard.x + iconGuard.width
            && pointerPosition.y >= iconGuard.y && pointerPosition.y < iconGuard.y + iconGuard.height
        Item {
            id: iconGuard
            readonly property bool horizontal: Theme.barPosition === "top" || Theme.barPosition === "bottom"
            x: horizontal ? root.surfaceController.trayMenuY - Theme.buttonSize / 2
                : Theme.barPosition === "right" ? root.geometry.screenWidth - trayMenuPopout.barThickness : 0
            y: horizontal ? (Theme.barPosition === "bottom" ? root.geometry.screenHeight - trayMenuPopout.barThickness : 0)
                : root.surfaceController.trayMenuY - Theme.buttonSize / 2
            width: horizontal ? Theme.buttonSize : trayMenuPopout.barThickness
            height: horizontal ? trayMenuPopout.barThickness : Theme.buttonSize
        }
        HoverHandler {
            onPointChanged: {
                const position = point.position;
                if (Math.abs(position.x - menuWindow.pointerPosition.x) + Math.abs(position.y - menuWindow.pointerPosition.y) > 1)
                    trayMenuPopout.keyboardNavigation = false;
                menuWindow.pointerPosition = position;
            }
        }
        MouseArea {
            anchors.fill: parent
            z: -1
            acceptedButtons: Qt.AllButtons
            onClicked: root.surfaceController.closeTrayMenu()
        }
        onVisibleChanged: {
            if (visible) {
                pointerPosition = Qt.point(iconGuard.x + iconGuard.width / 2, iconGuard.y + iconGuard.height / 2);
                Qt.callLater(() => {
                    if (menuWindow.visible && menuWindow._backingWindow)
                        menuWindow._backingWindow.requestActivate();
                });
            }
        }

        Timer {
            interval: 280
            running: menuWindow.visible && !trayMenuPopout.containsPoint(menuWindow.pointerPosition)
                && !menuWindow.overIcon
                && !trayMenuPopout.keyboardNavigation
            onTriggered: root.surfaceController.closeTrayMenu()
        }
        HyprlandFocusGrab {
            active: menuWindow.visible
            windows: [menuWindow]
            onCleared: root.surfaceController.closeTrayMenu()
        }
        TrayMenuPopout {
            id: trayMenuPopout
            x: rootScreenX + offsetX
            y: rootScreenY + offsetY
            menuHandle: root.surfaceController.trayMenuHandle
            screenWidth: root.geometry.screenWidth
            screenHeight: root.geometry.screenHeight
            barThickness: root.geometry.panelWindow
                ? (Theme.barPosition === "top" || Theme.barPosition === "bottom"
                    ? root.geometry.panelWindow.height : root.geometry.panelWindow.width) : Theme.railWidth
            rootScreenX: Theme.barPosition === "left" ? barThickness + 8
                : root.geometry.popupX(rootMenuWidth, root.geometry.openPanelX)
                + (Theme.barPosition === "right" ? screenWidth - barThickness : 0)
            rootScreenY: Theme.barPosition === "top" ? barThickness + 8
                : root.geometry.popupY(rootMenuHeight, root.surfaceController.trayMenuY)
                + (Theme.barPosition === "bottom" ? screenHeight - barThickness : 0)
            keyboardOpen: menuWindow.visible
            onCloseRequested: root.surfaceController.closeTrayMenu()
            onTriggered: root.surfaceController.closeTrayMenu()
        }
    }
}
