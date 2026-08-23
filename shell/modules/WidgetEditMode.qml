import "../shared"
import "../shared" as Shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    required property bool active
    required property var items
    property int selectedIndex: -1
    readonly property var selectedItem: selectedIndex >= 0 && selectedIndex < items.length ? items[selectedIndex] : null

    signal itemChanged(int index, var item)
    signal exitRequested()
    signal saveRequested()

    function clone(value) {
        return JSON.parse(JSON.stringify(value));
    }

    function initialX(item, itemWidth) {
        const anchor = String(item.anchor || "top-left");
        if (anchor.indexOf("right") >= 0)
            return width - itemWidth - Number(item.offset_x || 0);

        if (anchor === "centre")
            return Math.round((width - itemWidth) / 2) + Number(item.offset_x || 0);

        return Number(item.offset_x || 0);
    }

    function initialY(item, itemHeight) {
        const anchor = String(item.anchor || "top-left");
        if (anchor.indexOf("bottom") >= 0)
            return height - itemHeight - Number(item.offset_y || 0);

        if (anchor === "centre")
            return Math.round((height - itemHeight) / 2) + Number(item.offset_y || 0);

        return Number(item.offset_y || 0);
    }

    function geometryItem(item, itemX, itemY, itemWidth, itemHeight, resized) {
        const next = clone(item);
        const centreX = itemX + itemWidth / 2;
        const centreY = itemY + itemHeight / 2;
        const nearCentre = Math.abs(centreX - width / 2) < width * 0.16 && Math.abs(centreY - height / 2) < height * 0.16;
        if (nearCentre) {
            next.anchor = "centre";
            next.offset_x = Math.round(itemX - (width - itemWidth) / 2);
            next.offset_y = Math.round(itemY - (height - itemHeight) / 2);
        } else {
            const right = centreX >= width / 2;
            const bottom = centreY >= height / 2;
            next.anchor = (bottom ? "bottom-" : "top-") + (right ? "right" : "left");
            next.offset_x = Math.round(right ? width - itemX - itemWidth : itemX);
            next.offset_y = Math.round(bottom ? height - itemY - itemHeight : itemY);
        }
        if (resized) {
            const scale = Math.max(0.25, Math.min(4, Number(next.options && next.options.scale || 1)));
            next.width = Math.round(itemWidth / scale);
            next.height = Math.round(itemHeight / scale);
            if (!next.options)
                next.options = {
            };

            next.options.auto_size = false;
        }
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

    function selectedAutoSize() {
        if (!selectedItem)
            return true;

        if (selectedItem.options && selectedItem.options.auto_size !== undefined)
            return selectedItem.options.auto_size === true;

        return Number(selectedItem.width || 0) === 0 && Number(selectedItem.height || 0) === 0;
    }

    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    visible: active
    color: "transparent"
    exclusiveZone: 0
    exclusionMode: ExclusionMode.Ignore
    focusable: active
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "blox-widget-edit"
    WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

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
            onClicked: root.selectedIndex = -1
        }

    }

    Repeater {
        model: root.items

        Item {
            id: editor

            required property var modelData
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

            z: 1
            x: root.initialX(modelData, width)
            y: root.initialY(modelData, height)
            width: surface.width
            height: surface.height

            Shared.DesktopWidget {
                id: surface

                widget: editor.modelData
                interactive: false
                overrideWidth: editor.frameWidth
                overrideHeight: editor.frameHeight
                maximumWidth: root.width
                maximumHeight: root.height
            }

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: 2
                border.color: root.selectedIndex === editor.index ? Theme.blue : Theme.border
                radius: surface.radius
            }

            MouseArea {
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
                    root.selectedIndex = editor.index;
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
                        editor.x = Math.max(0, Math.min(root.width - editor.width, editor.startX + dx));
                        editor.y = Math.max(0, Math.min(root.height - editor.height, editor.startY + dy));
                        return ;
                    }
                    if (editor.edges & 1) {
                        const nextX = Math.min(editor.startX + editor.startWidth - 80, editor.startX + dx);
                        editor.x = Math.max(0, nextX);
                        editor.frameWidth = Math.round(editor.startWidth + editor.startX - editor.x);
                    }
                    if (editor.edges & 2)
                        editor.frameWidth = Math.round(Math.max(80, Math.min(root.width - editor.x, editor.startWidth + dx)));

                    if (editor.edges & 4) {
                        const nextY = Math.min(editor.startY + editor.startHeight - 48, editor.startY + dy);
                        editor.y = Math.max(0, nextY);
                        editor.frameHeight = Math.round(editor.startHeight + editor.startY - editor.y);
                    }
                    if (editor.edges & 8)
                        editor.frameHeight = Math.round(Math.max(48, Math.min(root.height - editor.y, editor.startHeight + dy)));

                }
                onReleased: root.itemChanged(editor.index, root.geometryItem(editor.modelData, editor.x, editor.y, editor.width, editor.height, editor.edges !== 0))
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
                currentIndex: root.selectedItem ? Math.max(0, model.indexOf(root.selectedItem.anchor || "top-left")) : 0
                onActivated: (index, value) => {
                    return root.updateSelected({
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

            BloxCheckBox {
                Layout.columnSpan: 2
                text: "Automatic size"
                checked: root.selectedAutoSize()
                onToggled: (checked) => {
                    if (!root.selectedItem)
                        return ;

                    const options = root.clone(root.selectedItem.options || {
                    });
                    options.auto_size = checked;
                    root.updateSelected({
                        "width": checked ? 0 : Math.max(160, root.selectedItem.width || 0),
                        "height": checked ? 0 : Math.max(80, root.selectedItem.height || 0),
                        "options": options
                    });
                }
            }

            Label {
                text: "Scale"
                color: Theme.muted
            }

            BloxTextField {
                Layout.fillWidth: true
                suffix: "×"
                text: root.selectedItem && root.selectedItem.options ? String(root.selectedItem.options.scale || 1) : "1"
                onEditingFinished: {
                    if (!root.selectedItem)
                        return ;

                    const options = root.clone(root.selectedItem.options || {
                    });
                    const parsed = Number(text);
                    options.scale = Math.max(0.25, Math.min(4, isNaN(parsed) ? 1 : parsed));
                    root.updateSelected({
                        "options": options
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
                text: root.selectedItem && root.selectedItem.options && root.selectedItem.options.background_opacity !== undefined ? String(Math.round((1 - Number(root.selectedItem.options.background_opacity)) * 100)) : String(Math.round((1 - Theme.widgetOpacity) * 100))
                onEditingFinished: {
                    if (!root.selectedItem)
                        return ;

                    const options = root.clone(root.selectedItem.options || {
                    });
                    const parsed = Number(text);
                    const transparency = Math.max(0, Math.min(100, isNaN(parsed) ? (1 - Theme.widgetOpacity) * 100 : parsed));
                    options.background_opacity = 1 - transparency / 100;
                    root.updateSelected({
                        "options": options
                    });
                }
            }

            Repeater {
                model: [{
                    "label": "X offset",
                    "key": "offset_x"
                }, {
                    "label": "Y offset",
                    "key": "offset_y"
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
                        enabled: parent.modelData.key === "offset_x" || parent.modelData.key === "offset_y" || !root.selectedAutoSize()
                        text: root.selectedItem ? String(root.selectedItem[parent.modelData.key] || 0) : "0"
                        onEditingFinished: {
                            const key = parent.modelData.key;
                            const parsed = parseInt(text);
                            const update = {
                            };
                            update[key] = key === "width" || key === "height" ? Math.max(1, parsed || 0) : Math.max(-10000, Math.min(10000, isNaN(parsed) ? 0 : parsed));
                            root.updateSelected(update);
                        }

                        BloxToolTip {
                            shown: parent.hovered && !parent.enabled
                            text: "Disable Automatic size to set width and height"
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
