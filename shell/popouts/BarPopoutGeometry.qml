import "../shared"
import QtQuick

QtObject {
    property var panelWindow
    property bool active: false
    property real screenWidth: 0
    property real screenHeight: 0
    property real openPanelX: 8
    property real openPanelY: 8

    function popupY(height, requestedY) {
        if (Theme.barPosition === "top")
            return Theme.railWidth + 8;

        if (Theme.barPosition === "bottom")
            return -height - 8;

        return Math.max(8, Math.min(screenHeight - height - 8, requestedY - height / 2));
    }

    function popupX(width, requestedX) {
        if (Theme.barPosition === "left")
            return Theme.railWidth + 8;

        if (Theme.barPosition === "right")
            return -width - 8;

        return Math.max(8, Math.min(screenWidth - width - 8, requestedX - width / 2));
    }

    function adjacentPopupX(width, siblingX, siblingWidth) {
        const right = siblingX + siblingWidth + 8;
        if (right + width <= screenWidth - 8)
            return right;

        return Math.max(8, siblingX - width - 8);
    }

}
