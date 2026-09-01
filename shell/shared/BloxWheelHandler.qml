import QtQuick

MouseArea {
    required property Flickable flickable
    property bool horizontal: false
    property real speed: 4
    property var canHandleWheel: null

    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true

    onWheel: (event) => {
        if (canHandleWheel && !canHandleWheel()) {
            event.accepted = false;
            return;
        }

        const pixelPrimary = horizontal ? event.pixelDelta.x : event.pixelDelta.y;
        const pixelFallback = horizontal ? event.pixelDelta.y : event.pixelDelta.x;
        const anglePrimary = horizontal ? event.angleDelta.x : event.angleDelta.y;
        const angleFallback = horizontal ? event.angleDelta.y : event.angleDelta.x;
        const pixelDelta = pixelPrimary || pixelFallback || 0;
        const angleDelta = anglePrimary || angleFallback || 0;
        const delta = pixelDelta !== 0 ? pixelDelta : angleDelta / 2;

        if (horizontal) {
            const maximum = Math.max(flickable.originX, flickable.originX + flickable.contentWidth - flickable.width);
            flickable.contentX = Math.max(flickable.originX, Math.min(maximum, flickable.contentX - delta * speed));
        } else {
            const maximum = Math.max(flickable.originY, flickable.originY + flickable.contentHeight - flickable.height);
            flickable.contentY = Math.max(flickable.originY, Math.min(maximum, flickable.contentY - delta * speed));
        }
        event.accepted = true;
    }
}
