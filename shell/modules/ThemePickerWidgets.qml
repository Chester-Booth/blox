import "."
import "../services"
import "../shared"
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: section

    required property ThemePickerController controller

    visible: controller.editorMode === "widgets"
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(12)

    Label {
        text: "Style"
        color: Theme.foreground
        font.pixelSize: 17
        font.bold: true
    }

    BloxComboBox {
        Layout.fillWidth: true
        model: ["minimal", "compact", "comfortable"]
        currentIndex: {
            controller.candidateRevision;
            const profile = controller.candidate && controller.candidate.widgets ? controller.candidate.widgets.profile : "minimal";
            return Math.max(0, model.indexOf(profile));
        }
        onActivated: (index, value) => {
            return controller.setWidgetProfile(value);
        }
    }

    RowLayout {
        Layout.fillWidth: true

        Label {
            Layout.fillWidth: true
            text: "Widgets"
            color: Theme.foreground
            font.pixelSize: 20
            font.bold: true
        }

        BloxButton {
            iconName: "squares-four"
            text: "Edit mode"
            onClicked: controller.openWidgetEditMode()
        }

        BloxButton {
            iconName: "plus"
            text: "New Widget"
            onClicked: controller.openWidgetEditor(-1)
        }

        BloxButton {
            iconName: "download-simple"
            text: "Import"
            onClicked: controller.openWidgetImportDialog()
        }

        BloxButton {
            iconName: "upload-simple"
            text: "Export"
            onClicked: controller.openWidgetExportDialog()
        }

    }

    Label {
        text: "List"
        color: Theme.foreground
        font.bold: true
    }

    Repeater {
        model: controller.widgetItems()

        Rectangle {
            required property var modelData
            required property int index

            Layout.fillWidth: true
            height: 54
            radius: Theme.scaledRadius(8)
            color: Theme.background
            border.color: Theme.border

            RowLayout {
                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(8)

                BloxCheckBox {
                    checked: modelData.enabled
                    onToggled: (value) => {
                        const items = controller.widgetItems().slice();
                        items[index].enabled = value;
                        controller.setWidgetItems(items);
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: modelData.name + " · " + modelData.type
                    color: Theme.foreground
                }

                BloxButton {
                    text: "Edit"
                    onClicked: controller.openWidgetEditor(index)
                }

                BloxButton {
                    text: "Delete"
                    destructive: true
                    onClicked: {
                        const items = controller.widgetItems().slice();
                        items.splice(index, 1);
                        controller.setWidgetItems(items);
                    }
                }

            }

        }

    }

    Text {
        visible: controller.widgetItems().length === 0
        text: "No widgets in this theme. Add one to show it on the desktop."
        color: Theme.muted
        wrapMode: Text.Wrap
    }

    Label {
        visible: false
        text: "Position"
        color: Theme.foreground
        font.bold: true
    }

    Text {
        visible: false
        Layout.fillWidth: true
        text: "Drag a widget to position it. Drop near a corner to snap it; drag any edge to resize."
        color: Theme.muted
        wrapMode: Text.Wrap
    }

    Rectangle {
        id: widgetCanvas

        visible: false
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(520, width * 9 / 16)
        clip: true
        radius: Theme.scaledRadius(12)
        color: Theme.background
        border.color: Theme.border

        Rectangle {
            id: barPreview

            property string barPosition: controller.candidate && controller.candidate.shell && controller.candidate.shell.bar ? controller.candidate.shell.bar.position : "left"
            readonly property bool horizontal: barPosition === "top" || barPosition === "bottom"

            anchors.left: barPosition === "left" || barPosition === "top" || barPosition === "bottom" ? parent.left : undefined
            anchors.right: barPosition === "right" || barPosition === "top" || barPosition === "bottom" ? parent.right : undefined
            anchors.top: barPosition === "top" || barPosition === "left" || barPosition === "right" ? parent.top : undefined
            anchors.bottom: barPosition === "bottom" || barPosition === "left" || barPosition === "right" ? parent.bottom : undefined
            width: horizontal ? parent.width : 18
            height: horizontal ? 18 : parent.height
            z: 4
            color: Theme.withAlpha(Theme.surface, 0.94)
            border.color: Theme.border

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: barPreview.horizontal

                Repeater {
                    model: controller.barPreviewItems("start")

                    delegate: PreviewBarItem {
                    }

                }

            }

            Row {
                anchors.centerIn: parent
                visible: barPreview.horizontal

                Repeater {
                    model: controller.barPreviewItems("centre")

                    delegate: PreviewBarItem {
                    }

                }

            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: barPreview.horizontal

                Repeater {
                    model: controller.barPreviewItems("end")

                    delegate: PreviewBarItem {
                    }

                }

            }

            Column {
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !barPreview.horizontal

                Repeater {
                    model: controller.barPreviewItems("start")

                    delegate: PreviewBarItem {
                    }

                }

            }

            Column {
                anchors.centerIn: parent
                visible: !barPreview.horizontal

                Repeater {
                    model: controller.barPreviewItems("centre")

                    delegate: PreviewBarItem {
                    }

                }

            }

            Column {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !barPreview.horizontal

                Repeater {
                    model: controller.barPreviewItems("end")

                    delegate: PreviewBarItem {
                    }

                }

            }

            component PreviewBarItem: Item {
                required property var modelData

                width: barPreview.horizontal ? 15 : barPreview.width
                height: barPreview.horizontal ? barPreview.height : 15

                PhosphorIcon {
                    anchors.centerIn: parent
                    width: 9
                    height: 9
                    iconName: controller.barPreviewIcon(parent.modelData.id)
                    iconColor: Theme.foreground
                }

            }

        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            onTapped: controller.selectedWidgetIndex = -1
        }

        Image {
            anchors.fill: parent
            source: controller.candidate && controller.candidate.wallpaper && controller.candidate.wallpaper.path ? controller.localFileUrl(controller.candidate.wallpaper.path) : "data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs="
            fillMode: Image.PreserveAspectCrop
            asynchronous: true

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.22)
            }

        }

        Text {
            anchors.centerIn: parent
            visible: !controller.candidate || !controller.candidate.wallpaper || !controller.candidate.wallpaper.path
            text: "No wallpaper selected"
            color: Theme.muted
        }

        Repeater {
            model: controller.widgetItems()

            Rectangle {
                id: widgetPreview

                required property var modelData
                required property int index
                property real virtualWidth: modelData.width > 0 ? modelData.width : 320
                property real virtualHeight: modelData.height > 0 ? modelData.height : 160
                property real resizeStartX: 0
                property real resizeStartY: 0
                property real resizeStartWidth: 0
                property real resizeStartHeight: 0

                width: Math.max(48, virtualWidth * widgetCanvas.width / 1920)
                height: Math.max(32, virtualHeight * widgetCanvas.height / 1080)
                x: modelData.anchor.indexOf("right") >= 0 ? widgetCanvas.width - width - modelData.offset_x * widgetCanvas.width / 1920 : modelData.anchor === "centre" ? (widgetCanvas.width - width) / 2 + modelData.offset_x * widgetCanvas.width / 1920 : modelData.offset_x * widgetCanvas.width / 1920
                y: modelData.anchor.indexOf("bottom") >= 0 ? widgetCanvas.height - height - modelData.offset_y * widgetCanvas.height / 1080 : modelData.anchor === "centre" ? (widgetCanvas.height - height) / 2 + modelData.offset_y * widgetCanvas.height / 1080 : modelData.offset_y * widgetCanvas.height / 1080
                radius: modelData.shape === "circle" ? Math.min(width, height) / 2 : modelData.shape === "square" ? 0 : Theme.scaledRadius(8)
                color: Theme.withAlpha(Theme.surface, 0.88)
                border.width: controller.selectedWidgetIndex === index ? 2 : 1
                border.color: controller.selectedWidgetIndex === index ? Theme.blue : Theme.border

                ScriptPoller {
                    id: previewWidgetContent

                    command: controller.widgetPreviewCommand(widgetPreview.modelData)
                    interval: Math.max(500, widgetPreview.modelData.interval_ms || 60000)
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 16
                    text: previewWidgetContent.raw.trim().length > 0 ? previewWidgetContent.raw : widgetPreview.modelData.name
                    color: Theme.foreground
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }

                MouseArea {
                    anchors.fill: parent
                    drag.target: widgetPreview
                    drag.minimumX: 0
                    drag.maximumX: widgetCanvas.width - widgetPreview.width
                    drag.minimumY: 0
                    drag.maximumY: widgetCanvas.height - widgetPreview.height
                    onPressed: controller.selectedWidgetIndex = widgetPreview.index
                    onReleased: controller.commitWidgetPreview(widgetPreview.index, widgetPreview.x, widgetPreview.y, widgetPreview.width, widgetPreview.height, widgetCanvas.width, widgetCanvas.height)
                }

                Rectangle {
                    width: 18
                    height: 18
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    radius: Theme.scaledRadius(4)
                    color: Theme.blue
                    border.color: Theme.background

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.SizeFDiagCursor
                        onPressed: (mouse) => {
                            const point = mapToItem(widgetCanvas, mouse.x, mouse.y);
                            widgetPreview.resizeStartX = point.x;
                            widgetPreview.resizeStartY = point.y;
                            widgetPreview.resizeStartWidth = widgetPreview.width;
                            widgetPreview.resizeStartHeight = widgetPreview.height;
                            controller.selectedWidgetIndex = widgetPreview.index;
                        }
                        onPositionChanged: (mouse) => {
                            if (!pressed)
                                return ;

                            const point = mapToItem(widgetCanvas, mouse.x, mouse.y);
                            widgetPreview.width = Math.max(48, Math.min(widgetCanvas.width - widgetPreview.x, widgetPreview.resizeStartWidth + point.x - widgetPreview.resizeStartX));
                            widgetPreview.height = Math.max(32, Math.min(widgetCanvas.height - widgetPreview.y, widgetPreview.resizeStartHeight + point.y - widgetPreview.resizeStartY));
                        }
                        onReleased: controller.commitWidgetPreview(widgetPreview.index, widgetPreview.x, widgetPreview.y, widgetPreview.width, widgetPreview.height, widgetCanvas.width, widgetCanvas.height)
                    }

                }

                MouseArea {
                    property real startCanvasX: 0
                    property real startPreviewX: 0
                    property real startWidth: 0

                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 7
                    cursorShape: Qt.SizeHorCursor
                    onPressed: (mouse) => {
                        const point = mapToItem(widgetCanvas, mouse.x, mouse.y);
                        startCanvasX = point.x;
                        startPreviewX = widgetPreview.x;
                        startWidth = widgetPreview.width;
                        controller.selectedWidgetIndex = widgetPreview.index;
                    }
                    onPositionChanged: (mouse) => {
                        if (!pressed)
                            return ;

                        const point = mapToItem(widgetCanvas, mouse.x, mouse.y);
                        const delta = Math.min(startWidth - 48, point.x - startCanvasX);
                        widgetPreview.x = startPreviewX + delta;
                        widgetPreview.width = startWidth - delta;
                    }
                    onReleased: controller.commitWidgetPreview(widgetPreview.index, widgetPreview.x, widgetPreview.y, widgetPreview.width, widgetPreview.height, widgetCanvas.width, widgetCanvas.height)
                }

                MouseArea {
                    property real startCanvasX: 0
                    property real startWidth: 0

                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 7
                    cursorShape: Qt.SizeHorCursor
                    onPressed: (mouse) => {
                        startCanvasX = mapToItem(widgetCanvas, mouse.x, mouse.y).x;
                        startWidth = widgetPreview.width;
                        controller.selectedWidgetIndex = widgetPreview.index;
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed)
                            widgetPreview.width = Math.max(48, Math.min(widgetCanvas.width - widgetPreview.x, startWidth + mapToItem(widgetCanvas, mouse.x, mouse.y).x - startCanvasX));

                    }
                    onReleased: controller.commitWidgetPreview(widgetPreview.index, widgetPreview.x, widgetPreview.y, widgetPreview.width, widgetPreview.height, widgetCanvas.width, widgetCanvas.height)
                }

                MouseArea {
                    property real startCanvasY: 0
                    property real startPreviewY: 0
                    property real startHeight: 0

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 7
                    cursorShape: Qt.SizeVerCursor
                    onPressed: (mouse) => {
                        const point = mapToItem(widgetCanvas, mouse.x, mouse.y);
                        startCanvasY = point.y;
                        startPreviewY = widgetPreview.y;
                        startHeight = widgetPreview.height;
                        controller.selectedWidgetIndex = widgetPreview.index;
                    }
                    onPositionChanged: (mouse) => {
                        if (!pressed)
                            return ;

                        const point = mapToItem(widgetCanvas, mouse.x, mouse.y);
                        const delta = Math.min(startHeight - 32, point.y - startCanvasY);
                        widgetPreview.y = startPreviewY + delta;
                        widgetPreview.height = startHeight - delta;
                    }
                    onReleased: controller.commitWidgetPreview(widgetPreview.index, widgetPreview.x, widgetPreview.y, widgetPreview.width, widgetPreview.height, widgetCanvas.width, widgetCanvas.height)
                }

                MouseArea {
                    property real startCanvasY: 0
                    property real startHeight: 0

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 7
                    cursorShape: Qt.SizeVerCursor
                    onPressed: (mouse) => {
                        startCanvasY = mapToItem(widgetCanvas, mouse.x, mouse.y).y;
                        startHeight = widgetPreview.height;
                        controller.selectedWidgetIndex = widgetPreview.index;
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed)
                            widgetPreview.height = Math.max(32, Math.min(widgetCanvas.height - widgetPreview.y, startHeight + mapToItem(widgetCanvas, mouse.x, mouse.y).y - startCanvasY));

                    }
                    onReleased: controller.commitWidgetPreview(widgetPreview.index, widgetPreview.x, widgetPreview.y, widgetPreview.width, widgetPreview.height, widgetCanvas.width, widgetCanvas.height)
                }

            }

        }

    }

    GridLayout {
        visible: false
        Layout.fillWidth: true
        columns: 4
        columnSpacing: 10
        rowSpacing: 6

        BloxCheckBox {
            Layout.columnSpan: 4
            text: "Automatic size"
            checked: {
                const item = controller.selectedWidgetIndex >= 0 && controller.selectedWidgetIndex < controller.widgetItems().length ? controller.widgetItems()[controller.selectedWidgetIndex] : null;
                return item && item.width === 0 && item.height === 0;
            }
            onToggled: (checked) => {
                const item = controller.widgetItems()[controller.selectedWidgetIndex];
                controller.updateWidgetGeometry(controller.selectedWidgetIndex, item.anchor, item.offset_x, item.offset_y, checked ? 0 : 320, checked ? 0 : 160);
            }
        }

        Repeater {
            model: ["X offset", "Y offset", "Width", "Height"]

            Label {
                required property string modelData

                text: modelData
                color: Theme.muted
            }

        }

        Repeater {
            model: ["offset_x", "offset_y", "width", "height"]

            BloxTextField {
                required property string modelData
                property var selectedItem: controller.selectedWidgetIndex >= 0 && controller.selectedWidgetIndex < controller.widgetItems().length ? controller.widgetItems()[controller.selectedWidgetIndex] : null

                Layout.fillWidth: true
                enabled: modelData === "offset_x" || modelData === "offset_y" || !selectedItem || selectedItem.width > 0 || selectedItem.height > 0
                text: selectedItem ? String(selectedItem[modelData]) : "0"
                onEditingFinished: {
                    if (!selectedItem)
                        return ;

                    const parsed = parseInt(text);
                    const value = modelData === "width" || modelData === "height" ? Math.max(1, parsed || 0) : Math.max(-10000, Math.min(10000, isNaN(parsed) ? 0 : parsed));
                    controller.updateWidgetGeometry(controller.selectedWidgetIndex, selectedItem.anchor, modelData === "offset_x" ? value : selectedItem.offset_x, modelData === "offset_y" ? value : selectedItem.offset_y, modelData === "width" ? value : selectedItem.width, modelData === "height" ? value : selectedItem.height);
                }

                BloxToolTip {
                    shown: parent.hovered && !parent.enabled
                    text: "Disable Automatic size to set width and height"
                }

            }

        }

    }

}
