import QtQuick
import Quickshell

// Owns drag-and-drop state for reordering bar items inside Settings.
Scope {
    id: root

    required property var host
    property bool active: false
    property string itemId: ""
    property string label: ""
    property string dropRegion: ""
    property int dropIndex: -1
    property string dropTarget: ""
    property real originX: 0
    property real originY: 0

    function begin(row, id) {
        const point = row.mapToItem(host.pickerRootItem, 0, 0);
        itemId = id;
        label = host.barItemLabel(id);
        host.barDragProxyItem.width = row.width;
        host.barDragProxyItem.height = row.height;
        host.barDragProxyItem.x = point.x;
        host.barDragProxyItem.y = point.y;
        originX = point.x;
        originY = point.y;
        dropRegion = "";
        dropIndex = -1;
        dropTarget = "";
        active = true;
    }

    function moveProxy(deltaX, deltaY) {
        if (!active)
            return;
        host.barDragProxyItem.x = originX + deltaX;
        host.barDragProxyItem.y = originY + deltaY;
    }

    function scrollEditor() {
        if (!active)
            return;
        const viewport = host.editorScrollItem.mapToItem(host.pickerRootItem, 0, 0);
        const pointerY = host.barDragProxyItem.y + host.barDragProxyItem.height / 2;
        const edge = 54;
        const maximum = Math.max(
            host.editorScrollItem.originY,
            host.editorScrollItem.originY + host.editorScrollItem.contentHeight - host.editorScrollItem.height
        );
        if (pointerY > viewport.y + host.editorScrollItem.height - edge)
            host.editorScrollItem.contentY = Math.min(maximum, host.editorScrollItem.contentY + 14);
        else if (pointerY < viewport.y + edge)
            host.editorScrollItem.contentY = Math.max(host.editorScrollItem.originY, host.editorScrollItem.contentY - 14);
    }

    function dropAllowed(id, region, index) {
        if (id === "application-tray") {
            if (region !== "hidden")
                return false;
            const count = host.barItems().filter((item) => item.region === "hidden").length;
            return host.applicationTrayAtStart() ? index === 0 : index === count;
        }
        if (id !== "tray")
            return true;
        if (region === "hidden")
            return false;
        const count = host.barItems().filter((item) => item.region === region).length;
        if (region === "start")
            return index === count;
        if (region === "end")
            return index === 0;
        return region === "centre" && (index === 0 || index === count);
    }

    function setDropTarget(region, index, target) {
        if (!active)
            return;
        if (!dropAllowed(itemId, region, index)) {
            dropRegion = "";
            dropIndex = -1;
            dropTarget = "";
            return;
        }
        dropRegion = region;
        dropIndex = index;
        dropTarget = target;
    }

    function commitDrop() {
        if (itemId.length > 0 && dropRegion.length > 0 && dropIndex >= 0)
            host.moveBarItemTo(itemId, dropRegion, dropIndex);
    }

    function end() {
        active = false;
        itemId = "";
        label = "";
        dropRegion = "";
        dropIndex = -1;
        dropTarget = "";
    }

    function finish() {
        commitDrop();
        end();
    }
}
