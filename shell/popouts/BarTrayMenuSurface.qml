import "../services"
import "../shared"
import QtQuick

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController

    HoverPopupWindow {
        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(trayMenuPopout.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(trayMenuPopout.height, root.surfaceController.trayMenuY)
        contentWidth: trayMenuPopout.width
        contentHeight: trayMenuPopout.height
        open: root.geometry.active && root.surfaceController.trayMenuOpen
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()

        TrayMenuPopout {
            id: trayMenuPopout

            menuHandle: root.surfaceController.trayMenuHandle
            title: root.surfaceController.trayMenuTitle
            onTriggered: root.surfaceController.closeTrayMenu()
        }

    }

}
