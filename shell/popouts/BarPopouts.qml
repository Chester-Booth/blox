import "../services"
import QtQuick

Item {
    id: root

    required property var panelWindow
    required property bool active
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    required property NotificationController notificationController
    required property UiState persistentState

    BarPopoutGeometry {
        id: geometry

        panelWindow: root.panelWindow
        active: root.active
        screenWidth: root.panelWindow.screen ? root.panelWindow.screen.width : 0
        screenHeight: root.panelWindow.screen ? root.panelWindow.screen.height : 0
        openPanelX: root.surfaceController.openPanelX
        openPanelY: root.surfaceController.openPanelY
    }

    BarNotesSurface {
        geometry: geometry
        surfaceController: root.surfaceController
        contentController: root.contentController
    }

    BarTrayMenuSurface {
        geometry: geometry
        surfaceController: root.surfaceController
    }

    BarCalendarSurface {
        geometry: geometry
        surfaceController: root.surfaceController
        contentController: root.contentController
    }

    BarSystemSurfaces {
        geometry: geometry
        surfaceController: root.surfaceController
        contentController: root.contentController
        uiState: root.persistentState
    }

    BarNotificationSurface {
        geometry: geometry
        surfaceController: root.surfaceController
        notificationController: root.notificationController
    }

    BarBasicSurface {
        geometry: geometry
        surfaceController: root.surfaceController
        contentController: root.contentController
        notificationController: root.notificationController
    }

}
