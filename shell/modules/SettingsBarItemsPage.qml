import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules
import qs.shared
import "SettingsBarOrder.js" as BarOrder

SettingsPageContent {
    id: root

    readonly property var settings: windowOwner.settingsController.settings || ({})
    readonly property var sourceItems: windowOwner.settingsValue("bar.items", settings.bar ? settings.bar.items || [] : [])
    readonly property string barPosition: windowOwner.settingsValue("bar.layout.position", settings.bar && settings.bar.layout ? settings.bar.layout.position || "top" : "top")
    readonly property var regions: ["start", "centre", "end", "hidden"]
    property bool barDragActive: false
    property string barDragItemId: ""
    property string barDropRegion: ""
    property int barDropIndex: -1
    property string barDropTarget: ""
    property real dragOriginX: 0
    property real dragOriginY: 0
    readonly property Item barDragProxyItem: dragProxy

    sectionMap: [{id: "bar-items", item: itemsSection}]
    searchTargetMap: [{section: "bar-items", label: "Bar items", objectName: "bar-item-power"}]
        .concat(sourceItems.map(item => ({section: "bar-items", label: itemLabel(item.id), objectName: "bar-item-" + item.id})))

    function copyItems() {
        return JSON.parse(JSON.stringify(sourceItems || []));
    }

    function itemsFor(region) {
        return copyItems().filter(item => item.region === region).sort((left, right) => left.order - right.order);
    }

    function itemLabel(id) {
        const labels = {
            "active-window-title": "Active window title",
            "application-tray": "Application tray",
            "bt": "Bluetooth",
            "gpu": "GPU",
            "power": "Power",
            "wifi": "Wi-Fi",
            "workspaces": "Workspaces"
        };
        if (labels[id])
            return labels[id];
        return String(id).split("-").map(word => word.length ? word[0].toUpperCase() + word.slice(1) : "").join(" ");
    }

    function normalise(items) {
        return BarOrder.normaliseOrders(items);
    }

    function moveBarItemTo(id, region, destinationIndex) {
        const next = BarOrder.moveTo(copyItems(), id, region, destinationIndex);
        if (next) windowOwner.writeSettingsValue("bar.items", next);
    }

    function barDropAllowed(id, region, index) {
        return BarOrder.dropAllowed(copyItems(), id, region, index);
    }

    function beginBarDrag(row, id) {
        const point = row.mapToItem(dragProxy.parent, 0, 0);
        barDragItemId = id;
        dragProxy.width = row.width;
        dragProxy.height = row.height;
        dragProxy.x = dragOriginX = point.x;
        dragProxy.y = dragOriginY = point.y;
        clearDropTarget();
        barDragActive = true;
    }

    function moveBarDragProxy(deltaX, deltaY) {
        if (!barDragActive) return;
        dragProxy.x = dragOriginX + deltaX;
        dragProxy.y = dragOriginY + deltaY;
    }

    function clearDropTarget() {
        barDropRegion = "";
        barDropIndex = -1;
        barDropTarget = "";
    }

    function setBarDropTarget(region, index, target) {
        if (!barDragActive) return;
        if (!barDropAllowed(barDragItemId, region, index)) {
            clearDropTarget();
            return;
        }
        barDropRegion = region;
        barDropIndex = index;
        barDropTarget = target;
    }

    function finishBarDrag(commit) {
        if (commit !== false && barDropRegion.length && barDropIndex >= 0)
            moveBarItemTo(barDragItemId, barDropRegion, barDropIndex);
        barDragActive = false;
        barDragItemId = "";
        clearDropTarget();
    }

    function scrollBarDrag() {
        if (!barDragActive || !scrollHost) return;
        const viewport = scrollHost.mapToItem(dragProxy.parent, 0, 0);
        const pointerY = dragProxy.y + dragProxy.height / 2;
        const maximum = Math.max(scrollHost.originY, scrollHost.originY + scrollHost.contentHeight - scrollHost.height);
        if (pointerY > viewport.y + scrollHost.height - 54)
            scrollHost.contentY = Math.min(maximum, scrollHost.contentY + 14);
        else if (pointerY < viewport.y + 54)
            scrollHost.contentY = Math.max(scrollHost.originY, scrollHost.contentY - 14);
    }

    onVisibleChanged: if (!visible) finishBarDrag(false)
    function setBarItemValue(id, key, value) {
        const next = copyItems().map(item => {
            if (item.id !== id)
                return item;
            const mapped = key === "region" && value === "tray" ? "hidden" : value;
            return Object.assign({}, item, {[key]: mapped}, key === "region"
                ? {order: sourceItems.filter(peer => peer.id !== id && peer.region === mapped).length} : {});
        });
        windowOwner.writeSettingsValue("bar.items", normalise(next));
    }

    function moveBarItem(id, direction) {
        const next = copyItems();
        const current = next.find(item => item.id === id);
        if (!current || id === "application-tray")
            return;
        const peers = next.filter(item => item.region === current.region).sort((left, right) => left.order - right.order);
        if (id === "tray") {
            if (current.region !== "centre") return;
            current.order = current.order === 0 ? peers.length : -1;
            windowOwner.writeSettingsValue("bar.items", normalise(next));
            return;
        }
        const index = peers.findIndex(item => item.id === id);
        const destination = index + direction;
        if (index < 0 || destination < 0 || destination >= peers.length)
            return;
        const moved = peers.splice(index, 1)[0];
        peers.splice(destination, 0, moved);
        peers.forEach((item, position) => item.order = position);
        windowOwner.writeSettingsValue("bar.items", normalise(next));
    }

    ColumnLayout {
        id: itemsSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(10)

        Text {
            text: "Bar items"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        Repeater {
            model: root.regions
            delegate: ColumnLayout {
                required property string modelData
                readonly property string regionName: modelData
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(6)

                // Keep the drop slot in the header's height so rows stay put, then align the label to the bottom.
                Item {
                    id: regionHeader
                    Layout.fillWidth: true
                    Layout.preferredHeight: regionHeading.implicitHeight + Theme.scaledSpacing(6) + 12

                    DropArea {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: parent.height + Theme.scaledSpacing(6)
                        onEntered: root.setBarDropTarget(regionName, 0, "start:" + regionName)
                        onExited: if (root.barDropTarget === "start:" + regionName) root.clearDropTarget()
                        onDropped: drop => { if (drop.source === root.barDragProxyItem) root.finishBarDrag(); }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            y: regionHeader.height + (Theme.scaledSpacing(6) - height) / 2
                            height: 3
                            radius: Theme.scaledRadius(2)
                            visible: root.barDragActive && root.barDropTarget === "start:" + regionName
                            color: Theme.blue
                        }
                    }

                    Text {
                        id: regionHeading
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        z: 1
                        text: regionName.charAt(0).toUpperCase() + regionName.slice(1) + " region"
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 13
                        font.bold: true
                    }
                }

                Repeater {
                    model: root.itemsFor(regionName)
                    delegate: SettingsBarItemRow {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        item: modelData
                        page: root
                        itemIndex: index
                        itemCount: root.itemsFor(regionName).length
                    }
                }
            }
        }
    }

    Rectangle {
        id: dragProxy
        parent: Overlay.overlay || root
        z: 1000
        visible: root.barDragActive
        property string barItemId: root.barDragItemId
        radius: Theme.scaledRadius(8)
        color: Theme.withAlpha(Theme.surface, 0.98)
        border.color: Theme.blue
        border.width: 2
        Drag.active: root.barDragActive
        Drag.source: dragProxy
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
        Text {
            anchors.centerIn: parent
            text: root.itemLabel(root.barDragItemId)
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
        }
    }

    Timer {
        interval: 16
        repeat: true
        running: root.barDragActive
        onTriggered: root.scrollBarDrag()
    }
}
