import QtQuick

Item {
    id: root

    property color color: "transparent"
    property var mask: null
    property real contentWidth: 1
    property real contentHeight: 1
    property real implicitWidth: Math.max(1, contentWidth)
    property real implicitHeight: Math.max(1, contentHeight)
    property bool grabFocus: false
    property PopupWindowAnchor anchor: PopupWindowAnchor {}
    property PopupSurfaceFormat surfaceFormat: PopupSurfaceFormat {}
    readonly property var _backingWindow: anchor.window

    width: implicitWidth
    height: implicitHeight

    function requestActivate() {
        if (anchor.window)
            anchor.window.requestActivate();
    }
}
