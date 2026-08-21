import "../services"
import QtQuick

QtObject {
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    required property WorkspaceController workspaceController
    required property NotificationController notificationController
    property bool horizontal: false
    property real panelExtent: 0
    property real maximumExtent: Number.POSITIVE_INFINITY
    property bool trayOpensForward: false
    property string batteryDisplay: "toggle"
    property var notificationPositionPublisher: null

    function mappedCentre(item, centre) {
        // A null target maps into the panel window's scene coordinates, which
        // are the coordinates expected by PopupWindow.anchor.rect.
        const point = item.mapToItem(null, item.width / 2, centre);
        return horizontal ? point.x : point.y;
    }

    function publishNotificationPosition() {
        if (notificationPositionPublisher)
            notificationPositionPublisher();

    }

}
