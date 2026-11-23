import qs.shared
import QtQuick
import QtQuick.Window
import Quickshell

// All menu levels share one popup and focus grab. Parent openers remain alive.
Item {
    id: root

    property var menuHandle: null
    property bool keyboardOpen: false
    property bool keyboardNavigation: false
    readonly property bool pointerHovered: firstPanel.pointerHovered || submenuStack.some(panel => panel.pointerHovered)
    onPointerHoveredChanged: if (!pointerHovered) keyboardNavigation = false
    property real screenWidth: Window.window && Window.window.screen ? Window.window.screen.width : 1280
    property real screenHeight: Window.window && Window.window.screen ? Window.window.screen.height : 720
    property real rootScreenX: 42
    property real rootScreenY: 8
    property real barThickness: Theme.railWidth
    readonly property real maximumHeight: screenHeight - 16
        - (Theme.barPosition === "top" || Theme.barPosition === "bottom" ? barThickness : 0)
    property var submenuStack: []
    readonly property alias rootPanel: firstPanel
    readonly property real rootMenuWidth: firstPanel.width
    readonly property real rootMenuHeight: firstPanel.height
    readonly property real offsetX: Math.min(0, ...submenuStack.map(panel => panel.panelX))
    readonly property real offsetY: Math.min(0, ...submenuStack.map(panel => panel.panelY))
    width: Math.max(firstPanel.width, ...submenuStack.map(panel => panel.panelX + panel.width)) - offsetX
    height: Math.max(firstPanel.height, ...submenuStack.map(panel => panel.panelY + panel.height)) - offsetY

    signal closeRequested()
    signal triggered()

    function containsPoint(point) {
        return [firstPanel].concat(submenuStack).some(panel => point.x >= x + panel.x
            && point.x < x + panel.x + panel.width && point.y >= y + panel.y
            && point.y < y + panel.y + panel.height);
    }
    function closeAfter(depth) {
        const removed = submenuStack.slice(depth);
        submenuStack = submenuStack.slice(0, depth);
        const parent = depth === 0 ? firstPanel : submenuStack[depth - 1];
        if (parent) parent.submenuIndex = -1;
        for (let i = removed.length - 1; i >= 0; i--) removed[i].destroy();
    }
    function resetNavigation() { closeAfter(0); }
    function goBack() {
        if (submenuStack.length === 0) return;
        const child = submenuStack[submenuStack.length - 1];
        const parent = child.parentPanel;
        const index = child.anchorIndex;
        // Closing a level can generate a hover enter under a stationary pointer.
        parent.hoverBlockedIndex = index;
        closeAfter(submenuStack.length - 1);
        parent.focusRow(index);
    }
    function openSubmenu(parent, entry, index) {
        const depth = parent.depth;
        const existing = submenuStack[depth];
        if (existing && existing.menuHandle === entry) {
            existing.forceActiveFocus();
            return;
        }
        closeAfter(depth);
        if (!entry || !entry.enabled || !entry.hasChildren) return;
        const panel = submenuComponent.createObject(root, {
            menuHandle: entry, parentPanel: parent, anchorIndex: index,
            lastPointerPosition: parent.lastPointerPosition
        });
        if (!panel) return;
        parent.submenuIndex = index;
        submenuStack = submenuStack.concat([panel]);
        panel.forceActiveFocus();
    }
    function takeKeyboardFocus() { firstPanel.forceActiveFocus(); }
    onMenuHandleChanged: resetNavigation()
    onKeyboardOpenChanged: {
        keyboardNavigation = false;
        firstPanel.selectedIndex = -1;
        firstPanel.lastPointerPosition = Qt.point(-1, -1);
        if (keyboardOpen) Qt.callLater(takeKeyboardFocus);
        else resetNavigation();
    }

    TrayMenuPanel {
        id: firstPanel
        objectName: "tray-menu-panel-0"
        property int depth: 0
        property real panelX: 0
        property real panelY: 0
        x: -root.offsetX
        y: -root.offsetY
        menuHandle: root.menuHandle
        maximumHeight: root.maximumHeight
        onKeyboardUsed: root.keyboardNavigation = true
        onPointerMoved: root.keyboardNavigation = false
        submenuOpensLeft: root.rootScreenX + width * 2 + 4 > root.screenWidth - 8
        onSubmenuRequested: (entry, index) => root.openSubmenu(this, entry, index)
        onCloseRequested: root.closeRequested()
        onTriggered: root.triggered()
        onViewportMoved: root.closeAfter(0)
    }
    Component {
        id: submenuComponent
        TrayMenuPanel {
            id: panel
            required property var parentPanel
            required property int anchorIndex
            readonly property int depth: parentPanel.depth + 1
            readonly property real rightX: parentPanel.panelX + parentPanel.width + 4
            readonly property real leftX: parentPanel.panelX - width - 4
            readonly property real panelX: root.rootScreenX + rightX + width <= root.screenWidth - 8
                && (!parentPanel.submenuOpensLeft || root.rootScreenX + leftX < 8)
                ? rightX : Math.max(8 - root.rootScreenX, leftX)
            readonly property real panelY: Math.max((Theme.barPosition === "top" ? barThickness : 0) + 8 - root.rootScreenY,
                Math.min(root.screenHeight - (Theme.barPosition === "bottom" ? barThickness : 0) - 8 - root.rootScreenY - height,
                    parentPanel.panelY + parentPanel.rowY(anchorIndex)))
            objectName: "tray-menu-panel-" + depth
            x: panelX - root.offsetX
            y: panelY - root.offsetY
            maximumHeight: root.maximumHeight
            onKeyboardUsed: root.keyboardNavigation = true
            onPointerMoved: root.keyboardNavigation = false
            submenuOpensLeft: panelX < parentPanel.panelX
            onSubmenuRequested: (entry, index) => root.openSubmenu(this, entry, index)
            onParentRequested: root.goBack()
            onCloseRequested: root.goBack()
            onTriggered: root.triggered()
            onViewportMoved: root.closeAfter(depth)
        }
    }
}
