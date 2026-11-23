import QtQuick
import QtQuick.Layouts
import qs.shared

Rectangle {
    id: root
    objectName: "bar-item-" + item.id

    required property var item
    required property var page
    property int itemIndex: 0
    property int itemCount: 1
    readonly property bool compactRow: width < 700
    readonly property bool dragging: handleDrag.active || emptyDrag.active

    readonly property bool isBattery: item.id === "battery"
    readonly property bool isGpu: item.id === "gpu"
    readonly property bool isVisibilityItem: ["privacy", "touchpad", "fan"].indexOf(item.id) >= 0 || isGpu
    readonly property bool isWindowTitle: item.id === "active-window-title"

    implicitHeight: 48
    radius: Theme.scaledRadius(8)
    color: dragging || dragHandleHover.hovered || rowHover.hovered ? Theme.withAlpha(Theme.blue, 0.08) : Theme.background
    border.color: dragging || dragHandleHover.hovered || rowHover.hovered ? Theme.blue : Theme.border

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(root.compactRow ? 6 : 8)
        spacing: Theme.scaledSpacing(root.compactRow ? 5 : 9)

        Item {
            Layout.preferredWidth: 18
            Layout.fillHeight: true
            PhosphorIcon {
                anchors.centerIn: parent
                width: 17
                height: 17
                iconName: "dots-six-vertical"
                iconColor: dragHandleHover.hovered ? Theme.foreground : Theme.muted
            }
            HoverHandler {
                id: dragHandleHover
                cursorShape: Qt.SizeAllCursor
            }
            DragHandler {
                id: handleDrag
                target: null
                acceptedButtons: Qt.LeftButton
                onTranslationChanged: root.page.moveBarDragProxy(translation.x, translation.y)
                onActiveChanged: {
                    if (active) root.page.beginBarDrag(root, root.item.id);
                    else if (root.page.barDragActive) Qt.callLater(() => root.page.finishBarDrag());
                }
            }
        }

        BloxCheckBox {
            Layout.fillWidth: true
            Layout.minimumWidth: root.compactRow ? 85 : 105
            text: root.page.itemLabel(root.item.id)
            checked: root.item.enabled === true
            onToggled: value => root.page.setBarItemValue(root.item.id, "enabled", value)
        }

        BloxComboBox {
            visible: root.isBattery
            Layout.preferredWidth: visible ? 132 : 0
            Layout.preferredHeight: 32
            model: ["click to toggle", "only numeric", "only icon"]
            currentIndex: Math.max(0, ["toggle", "numeric", "icon"].indexOf(root.item.display || "toggle"))
            onActivated: (index, value) => root.page.setBarItemValue(root.item.id, "display", ["toggle", "numeric", "icon"][index])
        }

        BloxComboBox {
            visible: root.isVisibilityItem
            Layout.preferredWidth: visible ? root.isGpu ? 190 : 172 : 0
            Layout.preferredHeight: 32
            model: root.visibilityLabels()
            currentIndex: root.visibilityIndex()
            onActivated: (index, value) => root.page.setBarItemValue(root.item.id, "visibility", root.visibilityValues()[index])
        }

        BloxComboBox {
            visible: root.isWindowTitle && ["left", "right"].indexOf(root.page.barPosition) >= 0
            Layout.preferredWidth: visible ? root.compactRow ? 125 : 164 : 0
            Layout.preferredHeight: 32
            model: ["flip inward", "flip outward", "stay horizontal"]
            currentIndex: Math.max(0, ["inward", "outward", "horizontal"].indexOf(root.item.orientation || "inward"))
            onActivated: (index, value) => root.page.setBarItemValue(root.item.id, "orientation", ["inward", "outward", "horizontal"][index])
        }

        BloxComboBox {
            visible: root.isWindowTitle
            Layout.preferredWidth: visible ? root.compactRow ? 145 : 172 : 0
            Layout.preferredHeight: 32
            model: ["cut off long titles", "show full title"]
            currentIndex: Math.max(0, ["truncate", "full"].indexOf(root.item.titleLength || "truncate"))
            onActivated: (index, value) => root.page.setBarItemValue(root.item.id, "titleLength", ["truncate", "full"][index])
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            HoverHandler { cursorShape: Qt.SizeAllCursor }
            DragHandler {
                id: emptyDrag
                target: null
                acceptedButtons: Qt.LeftButton
                onTranslationChanged: root.page.moveBarDragProxy(translation.x, translation.y)
                onActiveChanged: {
                    if (active) root.page.beginBarDrag(root, root.item.id);
                    else if (root.page.barDragActive) Qt.callLater(() => root.page.finishBarDrag());
                }
            }
        }

        BloxButton {
            Layout.preferredWidth: root.compactRow ? 30 : 34
            Layout.preferredHeight: 32
            compact: true
            iconName: "caret-up"
            enabled: root.canMoveUp()
            onClicked: root.page.moveBarItem(root.item.id, -1)
        }

        BloxButton {
            Layout.preferredWidth: root.compactRow ? 30 : 34
            Layout.preferredHeight: 32
            compact: true
            iconName: "caret-down"
            enabled: root.canMoveDown()
            onClicked: root.page.moveBarItem(root.item.id, 1)
        }

        BloxComboBox {
            Layout.preferredWidth: root.compactRow ? 82 : 92
            Layout.preferredHeight: 32
            model: root.regionOptions()
            currentIndex: Math.max(0, model.indexOf(root.item.id === "application-tray" ? "tray"
                : root.item.region === "hidden" ? "tray" : root.item.region))
            onActivated: (index, value) => root.page.setBarItemValue(root.item.id, "region", value === "tray" ? "hidden" : value)
        }
    }

    DropArea {
        anchors.fill: parent
        enabled: !root.dragging
        z: 2
        onEntered: drag => root.page.setBarDropTarget(root.item.region,
            drag.y < height / 2 ? root.itemIndex : root.itemIndex + 1, root.item.id)
        onPositionChanged: drag => root.page.setBarDropTarget(root.item.region,
            drag.y < height / 2 ? root.itemIndex : root.itemIndex + 1, root.item.id)
        onExited: if (root.page.barDropTarget === root.item.id) root.page.clearDropTarget()
        onDropped: drop => { if (drop.source === root.page.barDragProxyItem) root.page.finishBarDrag(); }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: root.page.barDropIndex === root.itemIndex ? parent.top : undefined
        anchors.bottom: root.page.barDropIndex === root.itemIndex + 1 ? parent.bottom : undefined
        height: 3
        radius: Theme.scaledRadius(2)
        z: 40
        visible: root.page.barDragActive && root.page.barDropTarget === root.item.id
        color: Theme.blue
    }

    HoverHandler { id: rowHover }

    function visibilityValues() {
        return isGpu ? ["always", "dedicated", "hybrid", "integrated"] : ["always", "normal"];
    }

    function visibilityLabels() {
        return visibilityValues().map(value => value === "always" ? "always visible"
            : isGpu ? "hide in " + value.charAt(0).toUpperCase() + value.slice(1) : "hidden when normal");
    }

    function visibilityIndex() {
        return Math.max(0, visibilityValues().indexOf(item.visibility || (isGpu ? "hybrid" : "normal")));
    }

    function regionOptions() {
        if (item.id === "application-tray")
            return ["tray"];
        if (item.id === "tray")
            return ["start", "centre", "end"];
        return ["start", "centre", "end", "tray"];
    }

    function canMoveUp() {
        if (item.id === "application-tray")
            return false;
        if (item.id === "tray")
            return item.region === "centre" && itemIndex > 0;
        return itemIndex > 0;
    }

    function canMoveDown() {
        if (item.id === "application-tray")
            return false;
        if (item.id === "tray")
            return item.region === "centre" && itemIndex < itemCount - 1;
        return itemIndex < itemCount - 1;
    }
}
