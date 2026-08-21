import "."
import "../services"
import QtQuick

Item {
    id: root

    required property var regionItems
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    required property WorkspaceController workspaceController
    required property NotificationController notificationController
    required property var trayHost
    required property bool horizontal
    required property real panelExtent
    required property string region
    property real maximumExtent: Number.POSITIVE_INFINITY
    property int extentsRevision: 0
    readonly property real minimumExtent: contentMinimumExtent()

    function contentMinimumExtent() {
        const revision = root.extentsRevision;
        const repeater = root.horizontal ? horizontalRepeater : verticalRepeater;
        let extent = 0;
        for (let index = 0; index < repeater.count; ++index) {
            const item = repeater.itemAt(index);
            if (!item || !item.visible)
                continue;

            extent += item.itemId === "active-window-title" ? Theme.buttonSize : root.horizontal ? item.implicitWidth : item.implicitHeight;
        }
        return extent;
    }

    function itemMaximumExtent(itemIndex) {
        const revision = root.extentsRevision;
        const repeater = root.horizontal ? horizontalRepeater : verticalRepeater;
        let reservedExtent = 0;
        for (let index = 0; index < repeater.count; ++index) {
            if (index === itemIndex)
                continue;

            const item = repeater.itemAt(index);
            if (item && item.visible)
                reservedExtent += root.horizontal ? item.implicitWidth : item.implicitHeight;

        }
        return Math.max(0, root.maximumExtent - reservedExtent);
    }

    implicitWidth: horizontal ? horizontalRow.implicitWidth : verticalColumn.implicitWidth
    implicitHeight: horizontal ? horizontalRow.implicitHeight : verticalColumn.implicitHeight
    width: implicitWidth
    height: implicitHeight

    Row {
        id: horizontalRow

        visible: root.horizontal

        Repeater {
            id: horizontalRepeater

            model: root.horizontal ? root.regionItems : []
            delegate: regionDelegate
        }

    }

    Column {
        id: verticalColumn

        visible: !root.horizontal

        Repeater {
            id: verticalRepeater

            model: root.horizontal ? [] : root.regionItems
            delegate: regionDelegate
        }

    }

    Component {
        id: regionDelegate

        BarItemDelegate {
            required property var modelData
            required property int index

            itemId: modelData.id
            surfaceController: root.surfaceController
            contentController: root.contentController
            workspaceController: root.workspaceController
            notificationController: root.notificationController
            horizontal: root.horizontal
            maximumExtent: modelData.id === "active-window-title" ? root.itemMaximumExtent(index) : Number.POSITIVE_INFINITY
            trayOpensForward: root.region === "start" || root.region === "centre" && index === root.regionItems.length - 1
            panelExtent: root.panelExtent
            onImplicitWidthChanged: {
                if (modelData.id !== "active-window-title")
                    root.extentsRevision++;

            }
            onImplicitHeightChanged: {
                if (modelData.id !== "active-window-title")
                    root.extentsRevision++;

            }
            onVisibleChanged: root.extentsRevision++
            Component.onCompleted: {
                root.trayHost.registerTrayToggle(this, root.horizontal, root.region);
                root.extentsRevision++;
            }
            Component.onDestruction: {
                root.trayHost.unregisterTrayToggle(this, root.horizontal);
                root.extentsRevision++;
            }
        }

    }

}
