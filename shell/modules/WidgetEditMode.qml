import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Blox.Widgets 1.0 as Widgets
import "../shared/WidgetWorkArea.js" as WidgetWorkArea

PanelWindow {
    id: root

    required property bool active
    required property var items
    required property var widgetTheme
    required property var provider
    property var qmlRegistry: ({})
    property string selectedWidgetId: ""
    property var occupiedBar: null
    property var externalReservationsByOutput: ({})
    readonly property var externalReservations: screen ? externalReservationsByOutput[screen.name] : null
    readonly property bool workAreaReady: Theme.ready && !!externalReservations
    readonly property rect widgetBounds: WidgetWorkArea.bounds(width, height,
        externalReservations, occupiedBar)
    readonly property int selectedIndex: items ? items.findIndex(item => item.id === selectedWidgetId) : -1
    readonly property var selectedItem: selectedIndex >= 0 && selectedIndex < items.length ? items[selectedIndex] : null

    onItemsChanged: {
        if (selectedWidgetId && items.findIndex(item => item.id === selectedWidgetId) < 0)
            selectedWidgetId = "";
    }

    signal itemChanged(int index, var item)
    signal exitRequested()
    signal saveRequested()

    function clone(value) {
        return JSON.parse(JSON.stringify(value));
    }

    function initialX(item, itemWidth) {
        const anchor = String(item.placement.anchor);
        let offset = Number(item.placement.x);
        if (anchor.indexOf("right") >= 0)
            offset = widgetBounds.width - itemWidth - offset;
        else if (anchor === "centre")
            offset += (widgetBounds.width - itemWidth) / 2;
        if (item.placement.sizing === "content")
            offset = Math.max(0, Math.min(offset, widgetBounds.width - itemWidth));
        return widgetBounds.x + offset;
    }

    function initialY(item, itemHeight) {
        const anchor = String(item.placement.anchor);
        let offset = Number(item.placement.y);
        if (anchor.indexOf("bottom") >= 0)
            offset = widgetBounds.height - itemHeight - offset;
        else if (anchor === "centre")
            offset += (widgetBounds.height - itemHeight) / 2;
        if (item.placement.sizing === "content")
            offset = Math.max(0, Math.min(offset, widgetBounds.height - itemHeight));
        return widgetBounds.y + offset;
    }

    function geometryItem(item, itemX, itemY, itemWidth, itemHeight) {
        const next = clone(item);
        itemX -= widgetBounds.x;
        itemY -= widgetBounds.y;
        const width = widgetBounds.width;
        const height = widgetBounds.height;
        const centreX = itemX + itemWidth / 2;
        const centreY = itemY + itemHeight / 2;
        const nearCentre = Math.abs(centreX - width / 2) < width * 0.16 && Math.abs(centreY - height / 2) < height * 0.16;
        if (nearCentre) {
            next.placement.anchor = "centre";
            next.placement.x = Math.round(itemX - (width - itemWidth) / 2);
            next.placement.y = Math.round(itemY - (height - itemHeight) / 2);
        } else {
            const right = centreX >= width / 2;
            const bottom = centreY >= height / 2;
            next.placement.anchor = (bottom ? "bottom-" : "top-") + (right ? "right" : "left");
            next.placement.x = Math.round(right ? width - itemX - itemWidth : itemX);
            next.placement.y = Math.round(bottom ? height - itemY - itemHeight : itemY);
        }
        next.placement.width = Math.round(itemWidth);
        next.placement.height = Math.round(itemHeight);
        return next;
    }

    function updateSelected(values) {
        if (!selectedItem)
            return ;

        const next = clone(selectedItem);
        Object.keys(values).forEach((key) => {
            next[key] = values[key];
        });
        itemChanged(selectedIndex, next);
    }

    function updatePlacement(values) {
        if (!selectedItem) return;
        const placement = clone(selectedItem.placement);
        Object.keys(values).forEach(key => placement[key] = values[key]);
        updateSelected({placement: placement});
    }

    screen: Hyprland.focusedMonitor ? Quickshell.screens.find(screen => screen.name === Hyprland.focusedMonitor.name) || Quickshell.screens[0] : Quickshell.screens[0] || null
    visible: active && workAreaReady
    color: "transparent"
    exclusiveZone: 0
    exclusionMode: ExclusionMode.Ignore
    focusable: active
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "blox-widget-edit"
    WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    Shortcut {
        sequence: "Escape"
        context: Qt.WindowShortcut
        enabled: root.active
        onActivated: root.exitRequested()
    }

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    Rectangle {
        anchors.fill: parent
        z: -1
        color: Theme.withAlpha(Theme.background, 0.16)

        MouseArea {
            anchors.fill: parent
            onClicked: root.selectedWidgetId = ""
        }

    }

    WidgetItemModel { id: editItemModel; items: root.items }
    Repeater {
        model: editItemModel

        Item {
            id: editor

            required property string document
            readonly property var modelData: JSON.parse(document)
            required property int index
            property real startX: 0
            property real startY: 0
            property real startWidth: 0
            property real startHeight: 0
            property point startPointer: Qt.point(0, 0)
            property int edges: 0
            property int frameWidth: 0
            property int frameHeight: 0
            readonly property int edgeSize: 10

            function restoreGeometry() {
                frameWidth = 0;
                frameHeight = 0;
                x = Qt.binding(function() { return root.initialX(editor.modelData, editor.width); });
                y = Qt.binding(function() { return root.initialY(editor.modelData, editor.height); });
            }
            onModelDataChanged: if (!dragArea || !dragArea.pressed) restoreGeometry()

            z: 1
            x: root.initialX(modelData, width)
            y: root.initialY(modelData, height)
            width: frameWidth > 0 ? frameWidth : surface.normalWidth
            height: frameHeight > 0 ? frameHeight : surface.normalHeight

            Widgets.WidgetHost {
                id: surface
                x: 0
                y: 0
                width: editor.width
                height: editor.height
                widget: editor.modelData
                theme: root.widgetTheme
                provider: root.provider
                qmlRegistry: root.qmlRegistry
                placementBounds: root.widgetBounds
                fullscreenBounds: Qt.rect(0, 0, root.width, root.height)
                editing: true
                visible: root.visible
            }

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: 2
                border.color: root.selectedIndex === editor.index ? Theme.blue : Theme.border
                radius: Theme.scaledRadius(12)
            }

            MouseArea {
                id: dragArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: {
                    const horizontal = mouseX <= editor.edgeSize || mouseX >= width - editor.edgeSize;
                    const vertical = mouseY <= editor.edgeSize || mouseY >= height - editor.edgeSize;
                    if (horizontal && vertical)
                        return (mouseX <= editor.edgeSize) === (mouseY <= editor.edgeSize) ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor;

                    if (horizontal)
                        return Qt.SizeHorCursor;

                    if (vertical)
                        return Qt.SizeVerCursor;

                    return Qt.SizeAllCursor;
                }
                onPressed: (event) => {
                    root.selectedWidgetId = editor.modelData.id;
                    editor.startX = editor.x;
                    editor.startY = editor.y;
                    editor.startWidth = editor.width;
                    editor.startHeight = editor.height;
                    editor.startPointer = editor.mapToGlobal(Qt.point(event.x, event.y));
                    editor.edges = (event.x <= editor.edgeSize ? 1 : 0) | (event.x >= width - editor.edgeSize ? 2 : 0) | (event.y <= editor.edgeSize ? 4 : 0) | (event.y >= height - editor.edgeSize ? 8 : 0);
                }
                onPositionChanged: (event) => {
                    if (!pressed)
                        return ;

                    const pointer = editor.mapToGlobal(Qt.point(event.x, event.y));
                    const dx = pointer.x - editor.startPointer.x;
                    const dy = pointer.y - editor.startPointer.y;
                    if (editor.edges === 0) {
                        editor.x = Math.max(root.widgetBounds.x, Math.min(root.widgetBounds.x + root.widgetBounds.width - editor.width, editor.startX + dx));
                        editor.y = Math.max(root.widgetBounds.y, Math.min(root.widgetBounds.y + root.widgetBounds.height - editor.height, editor.startY + dy));
                        return ;
                    }
                    if (editor.edges & 1) {
                        const nextX = Math.min(editor.startX + editor.startWidth - 80, editor.startX + dx);
                        editor.x = Math.max(root.widgetBounds.x, nextX);
                        editor.frameWidth = Math.round(editor.startWidth + editor.startX - editor.x);
                    }
                    if (editor.edges & 2)
                        editor.frameWidth = Math.round(Math.max(80, Math.min(root.widgetBounds.x + root.widgetBounds.width - editor.x, editor.startWidth + dx)));

                    if (editor.edges & 4) {
                        const nextY = Math.min(editor.startY + editor.startHeight - 48, editor.startY + dy);
                        editor.y = Math.max(root.widgetBounds.y, nextY);
                        editor.frameHeight = Math.round(editor.startHeight + editor.startY - editor.y);
                    }
                    if (editor.edges & 8)
                        editor.frameHeight = Math.round(Math.max(48, Math.min(root.widgetBounds.y + root.widgetBounds.height - editor.y, editor.startHeight + dy)));

                }
                onReleased: {
                    const item = root.geometryItem(editor.modelData, editor.x, editor.y, editor.width, editor.height);
                    if (editor.edges !== 0) item.placement.sizing = "fixed";
                    root.itemChanged(editor.index, item);
                    editor.restoreGeometry();
                }
                onCanceled: editor.restoreGeometry()
            }

        }

    }

    Rectangle {
        id: controls

        property point dragOrigin: Qt.point(0, 0)
        property point positionOrigin: Qt.point(0, 0)
        property point startPointer: Qt.point(0, 0)

        z: 2
        x: root.width - width - 20
        y: 20
        width: root.selectedItem ? 300 : buttonRow.implicitWidth + 58
        height: root.selectedItem ? positionGrid.implicitHeight + 72 : buttonRow.implicitHeight + 16
        color: Theme.surface
        border.width: 1
        border.color: Theme.border
        radius: Theme.radius

        Row {
            id: buttonRow

            anchors.right: parent.right
            anchors.rightMargin: Theme.scaledSpacing(10)
            anchors.top: parent.top
            anchors.topMargin: Theme.scaledSpacing(8)
            spacing: Theme.scaledSpacing(8)

            BloxButton {
                text: "Exit"
                iconName: "x"
                onClicked: root.exitRequested()
            }

            BloxButton {
                text: "Save"
                iconName: "floppy-disk"
                accent: Theme.green
                onClicked: root.saveRequested()
            }

        }

        GridLayout {
            id: positionGrid

            visible: root.selectedItem !== null
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: buttonRow.bottom
            anchors.leftMargin: Theme.scaledSpacing(12)
            anchors.rightMargin: Theme.scaledSpacing(12)
            anchors.topMargin: Theme.scaledSpacing(14)
            columns: 2
            columnSpacing: 10
            rowSpacing: 8

            Label {
                Layout.columnSpan: 2
                text: root.selectedItem ? root.selectedItem.name + " position" : "Widget position"
                color: Theme.foreground
                font.bold: true
            }

            Label {
                text: "Anchor"
                color: Theme.muted
            }

            BloxComboBox {
                Layout.fillWidth: true
                model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre"]
                currentIndex: root.selectedItem ? Math.max(0, model.indexOf(root.selectedItem.placement.anchor)) : 0
                onActivated: (index, value) => {
                    return root.updatePlacement({
                        "anchor": value
                    });
                }
            }

            Label {
                text: "Visibility"
                color: Theme.muted
            }

            BloxComboBox {
                Layout.fillWidth: true
                model: ["empty-workspace", "always"]
                currentIndex: root.selectedItem ? Math.max(0, model.indexOf(root.selectedItem.visibility || "empty-workspace")) : 0
                onActivated: (index, value) => {
                    return root.updateSelected({
                        "visibility": value
                    });
                }
            }

            Label {
                text: "Transparency"
                color: Theme.muted
            }

            BloxTextField {
                Layout.fillWidth: true
                suffix: "%"
                text: root.selectedItem ? String(Math.round((1 - root.selectedItem.appearance.backgroundOpacity) * 100)) : "0"
                onEditingFinished: {
                    if (!root.selectedItem)
                        return ;

                    const appearance = root.clone(root.selectedItem.appearance);
                    const parsed = Number(text);
                    if (!Number.isFinite(parsed)) return;
                    appearance.backgroundOpacity = 1 - Math.max(0, Math.min(100, parsed)) / 100;
                    root.updateSelected({appearance: appearance});
                }
            }

            Repeater {
                model: [{
                    "label": "X offset",
                    "key": "x"
                }, {
                    "label": "Y offset",
                    "key": "y"
                }, {
                    "label": "Width",
                    "key": "width"
                }, {
                    "label": "Height",
                    "key": "height"
                }]

                RowLayout {
                    required property var modelData

                    Layout.columnSpan: 2

                    Label {
                        Layout.preferredWidth: 92
                        text: parent.modelData.label
                        color: Theme.muted
                    }

                    BloxTextField {
                        Layout.fillWidth: true
                        suffix: "px"
                        text: root.selectedItem ? String(root.selectedItem.placement[parent.modelData.key]) : "0"
                        onEditingFinished: {
                            const key = parent.modelData.key;
                            const parsed = parseInt(text);
                            const update = {
                            };
                            update[key] = key === "width" || key === "height" ? Math.max(1, Math.min(16384, parsed || 0)) : Math.max(-100000, Math.min(100000, isNaN(parsed) ? 0 : parsed));
                            if (key === "width" || key === "height") update.sizing = "fixed";
                            root.updatePlacement(update);
                        }



                    }

                }

            }

        }

        PhosphorIcon {
            anchors.left: parent.left
            anchors.leftMargin: Theme.scaledSpacing(12)
            anchors.top: parent.top
            anchors.topMargin: Theme.scaledSpacing(17)
            width: 18
            height: 18
            iconName: "dots-six-vertical"
            iconColor: Theme.muted
        }

        MouseArea {
            anchors.left: parent.left
            anchors.top: parent.top
            width: 42
            height: 48
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.SizeAllCursor
            onPressed: (event) => {
                controls.dragOrigin = Qt.point(event.x, event.y);
                controls.positionOrigin = Qt.point(controls.x, controls.y);
                controls.startPointer = controls.mapToGlobal(Qt.point(event.x, event.y));
            }
            onPositionChanged: (event) => {
                if (!pressed)
                    return ;

                const pointer = controls.mapToGlobal(Qt.point(event.x, event.y));
                controls.x = Math.max(0, Math.min(root.width - controls.width, controls.positionOrigin.x + pointer.x - controls.startPointer.x));
                controls.y = Math.max(0, Math.min(root.height - controls.height, controls.positionOrigin.y + pointer.y - controls.startPointer.y));
            }
        }

    }

}
