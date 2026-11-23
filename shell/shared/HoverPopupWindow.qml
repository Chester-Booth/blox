import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland

PopupWindow {
    id: root

    default property alias content: contentHost.data
    property var anchorWindow
    property real anchorX: Theme.railWidth + 8
    property real anchorY: 8
    property real contentWidth: 0
    property real contentHeight: 0
    property real slideOffset: 10
    readonly property real openingSlideX: Theme.barPosition === "left" ? -4 : Theme.barPosition === "right" ? 4 : 0
    readonly property real openingSlideY: Theme.barPosition === "top" ? -4 : Theme.barPosition === "bottom" ? 4 : 0
    readonly property real slideX: Theme.barPosition === "left" ? -slideOffset : Theme.barPosition === "right" ? slideOffset : 0
    readonly property real slideY: Theme.barPosition === "top" ? -slideOffset : Theme.barPosition === "bottom" ? slideOffset : 0
    property bool open: false
    property bool rendered: false
    property bool keyboardFocus: false
    property bool persistentKeyboardFocus: false
    property bool dismissOnFocusClear: false

    signal hoverEntered()
    signal hoverExited()
    signal dismissRequested()

    function requestKeyboardFocus() {
        keyboardFocus = true;
        activateKeyboardFocusWhenReady();
    }

    function releaseKeyboardFocus() {
        keyboardFocus = false;
    }

    function activateKeyboardFocusWhenReady() {
        Qt.callLater(() => {
            if (root.visible && (root.keyboardFocus || root.persistentKeyboardFocus) && root._backingWindow)
                root._backingWindow.requestActivate();
        });
    }

    anchor.window: anchorWindow
    anchor.rect.x: anchorX
    anchor.rect.y: anchorY
    implicitWidth: Math.max(1, contentWidth)
    implicitHeight: Math.max(1, contentHeight)
    surfaceFormat.opaque: false
    grabFocus: keyboardFocus || persistentKeyboardFocus
    color: Qt.rgba(0, 0, 0, 0.004)
    visible: rendered && anchorWindow && anchorWindow.visible
        && anchorWindow.width > 0 && anchorWindow.height > 0
        && contentWidth > 0 && contentHeight > 0
    onVisibleChanged: {
        if (!visible)
            keyboardFocus = false;
        else if (persistentKeyboardFocus)
            activateKeyboardFocusWhenReady();

    }
    onPersistentKeyboardFocusChanged: {
        if (persistentKeyboardFocus)
            activateKeyboardFocusWhenReady();

    }
    function applyOpenState() {
        if (open) {
            hideAnimation.stop();
            if (!rendered) {
                contentHost.x = root.openingSlideX;
                contentHost.y = root.openingSlideY;
                contentHost.scale = 1;
            }
            rendered = true;
            showAnimation.restart();
        } else if (rendered) {
            showAnimation.stop();
            hideAnimation.restart();
        }
    }

    Component.onCompleted: {
        if (open && !rendered)
            applyOpenState();
    }
    onOpenChanged: applyOpenState()

    Item {
        id: contentHost

        width: Math.max(1, root.contentWidth)
        height: Math.max(1, root.contentHeight)
        x: root.openingSlideX
        y: root.openingSlideY
        opacity: 0
        scale: 1
        transformOrigin: Item.Left

        Keys.onEscapePressed: event => {
            if (!root.keyboardFocus && !root.persistentKeyboardFocus) {
                event.accepted = false;
                return;
            }

            root.dismissRequested();
            event.accepted = true;
        }

        HoverHandler {
            onHoveredChanged: hovered ? root.hoverEntered() : root.hoverExited()
        }

    }

    HyprlandFocusGrab {
        id: keyboardFocusGrab
        objectName: "popup-keyboard-focus-grab"
        active: root.visible && (root.keyboardFocus || root.persistentKeyboardFocus)
        windows: [root]
        onCleared: {
            const dismissOwner = root.persistentKeyboardFocus || root.dismissOnFocusClear;
            root.keyboardFocus = false;
            if (dismissOwner)
                root.dismissRequested();
        }
    }

    ParallelAnimation {
        id: showAnimation

        NumberAnimation {
            target: contentHost
            property: "opacity"
            from: contentHost.opacity
            to: 1
            duration: 40
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: contentHost
            property: "y"
            from: contentHost.y
            to: 0
            duration: 40
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: contentHost
            property: "x"
            from: contentHost.x
            to: 0
            duration: 40
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: contentHost
            property: "scale"
            from: contentHost.scale
            to: 1
            duration: 40
            easing.type: Easing.OutCubic
        }

    }

    ParallelAnimation {
        id: hideAnimation

        onFinished: {
            if (!root.open)
                root.rendered = false;

        }

        NumberAnimation {
            target: contentHost
            property: "opacity"
            from: contentHost.opacity
            to: 0
            duration: 110
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: contentHost
            property: "x"
            from: contentHost.x
            to: root.slideX
            duration: 130
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: contentHost
            property: "y"
            from: contentHost.y
            to: root.slideY
            duration: 130
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: contentHost
            property: "scale"
            from: contentHost.scale
            to: 0.985
            duration: 130
            easing.type: Easing.InCubic
        }

    }

}
