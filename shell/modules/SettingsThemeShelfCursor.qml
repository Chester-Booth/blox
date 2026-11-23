import QtQuick
import Quickshell
import Quickshell.Io

// Tracks the cursor position in the Settings theme shelf while the shelf is open
// so card hover state stays accurate across Wayland popups.
Scope {
    id: root

    required property Item frameItem
    required property var themeShelfOverlay
    property bool shelfOpen: false
    property bool themeCardMenuOpen: false
    property var shelfCursor: ({x: -1, y: -1, occluded: false})

    function updateShelfCursor(raw) {
        if (!shelfOpen)
            return;
        try {
            const point = JSON.parse(raw);
            const x = Number(point.x);
            const y = Number(point.y);
            if (!Number.isFinite(x) || !Number.isFinite(y))
                return;
            if (point.title !== "Blox settings") {
                setShelfCursor({x: -1, y: -1, occluded: false});
                return;
            }
            const localX = x - Number(point.originX) - frameItem.x;
            const localY = y - Number(point.originY) - frameItem.y;
            const menu = themeShelfOverlay.themeCardMenuOverlay.mapToItem(frameItem, 0, 0);
            const occluded = themeCardMenuOpen
                && localX >= menu.x && localX <= menu.x + themeShelfOverlay.themeCardMenuOverlay.width
                && localY >= menu.y && localY <= menu.y + themeShelfOverlay.themeCardMenuOverlay.height;
            setShelfCursor({x: localX, y: localY, occluded: occluded});
        } catch (_) {
            // Pointer events still provide hover state when Hyprland is unavailable.
        }
    }

    function setShelfCursor(point) {
        shelfCursor = point;
        Qt.callLater(() => syncThemeCardHover());
    }

    function syncThemeCardHover() {
        for (let index = 0; index < themeShelfOverlay.themeList.count; index++) {
            const card = themeShelfOverlay.themeList.itemAtIndex(index);
            if (card)
                card.syncGlobalPointer();
        }
    }

    onShelfOpenChanged: {
        if (!shelfOpen)
            shelfCursor = ({x: -1, y: -1, occluded: false});
    }

    Timer {
        interval: 120
        repeat: true
        running: root.shelfOpen
        triggeredOnStart: true
        onTriggered: {
            if (!shelfCursorProcess.running)
                shelfCursorProcess.running = true;
        }
    }

    Process {
        id: shelfCursorProcess
        command: ["python3", Quickshell.shellDir + "/scripts/pointer_position.py"]
        stdout: StdioCollector {
            onStreamFinished: root.updateShelfCursor(this.text)
        }
    }
}
