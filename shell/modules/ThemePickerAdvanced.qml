import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: section

    required property ThemePickerController controller

    visible: controller.editorMode === "advanced"
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(12)

    Label {
        text: "Bar settings"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)

            Label {
                text: "Bar position"
                color: Theme.muted
            }

            BloxComboBox {
                Layout.fillWidth: true
                model: ["left", "right", "top", "bottom"]
                currentIndex: model.indexOf(controller.shellValue("bar", "position"))
                onActivated: (index, value) => controller.setShellValue("bar", "position", value)
            }
        }

        BloxCheckBox {
            Layout.fillWidth: true
            text: "Separate bar groups"
            checked: controller.shellValue("bar", "separate_groups")
            onToggled: value => controller.setShellValue("bar", "separate_groups", value)
        }

        BloxCheckBox {
            Layout.fillWidth: true
            text: "Bar border"
            checked: controller.shellValue("bar", "border")
            onToggled: value => controller.setShellValue("bar", "border", value)
        }

        BloxSlider {
            wheelSession: controller
            Layout.fillWidth: true
            label: "Edge inset"
            from: 0
            to: 24
            decimals: 0
            value: controller.shellValue("bar", "edge_inset")
            onMoved: value => controller.setShellValue("bar", "edge_inset", Math.round(value))
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)

            BloxCheckBox {
                Layout.alignment: Qt.AlignBottom
                text: "Automatic"
                checked: controller.barOverrideAutomatic("radius")
                onToggled: value => controller.setBarOverrideAutomatic("radius", value)
            }

            BloxSlider {
                wheelSession: controller
                Layout.fillWidth: true
                label: "Bar roundness"
                from: 0
                to: 2
                value: controller.barOverrideValue("radius")
                enabled: !controller.barOverrideAutomatic("radius")
                onMoved: value => controller.setBarOverrideValue("radius", value)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)

            BloxCheckBox {
                Layout.alignment: Qt.AlignBottom
                text: "Automatic"
                checked: controller.barOverrideAutomatic("density")
                onToggled: value => controller.setBarOverrideAutomatic("density", value)
            }

            BloxSlider {
                wheelSession: controller
                Layout.fillWidth: true
                label: "Bar density"
                from: 0.75
                to: 1.5
                value: controller.barOverrideValue("density")
                enabled: !controller.barOverrideAutomatic("density")
                onMoved: value => controller.setBarOverrideValue("density", value)
            }
        }
    }

    Label {
        text: "OSD / Notifications"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 12
        rowSpacing: 8

        Label {
            text: "OSD position"
            color: Theme.muted
        }

        BloxComboBox {
            Layout.fillWidth: true
            model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre-top", "centre-bottom"]
            currentIndex: model.indexOf(controller.shellValue("osd", "position"))
            onActivated: (index, value) => controller.setShellValue("osd", "position", value)
        }

        Label {
            text: "Notification position"
            color: Theme.muted
        }

        BloxComboBox {
            Layout.fillWidth: true
            model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre-top", "centre-bottom"]
            currentIndex: model.indexOf(controller.shellValue("notifications", "position"))
            onActivated: (index, value) => controller.setShellValue("notifications", "position", value)
        }
    }

    Label {
        text: "Shape & density"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 230
        radius: Theme.cardRadius
        color: Theme.withAlpha(Theme.foreground, 0.03)
        border.color: Theme.border

        ThemeShapePreview {
            width: Math.min(560, parent.width - 32)
            height: width * 96 / 260
            anchors.centerIn: parent
            radiusScale: controller.shapeValue("radius_scale", 1.25)
            densityScale: controller.shapeValue("density_scale", 1.0)
            windowGap: controller.effectiveWindowGap()
        }
    }

    BloxSlider {
        wheelSession: controller
        Layout.fillWidth: true
        label: "Roundness"
        from: 0
        to: 2
        value: controller.shapeValue("radius_scale", 1.25)
        onMoved: value => controller.setShapeValue("radius_scale", value)
    }

    BloxSlider {
        wheelSession: controller
        Layout.fillWidth: true
        label: "Density"
        from: 0.75
        to: 1.5
        value: controller.shapeValue("density_scale", 1.0)
        onMoved: value => controller.setShapeValue("density_scale", value)
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(12)

        BloxCheckBox {
            Layout.alignment: Qt.AlignBottom
            text: "Automatic"
            checked: !controller.candidate || !controller.candidate.shape || controller.candidate.shape.window_gap === undefined
            onToggled: checked => controller.setAutomaticWindowGap(checked)
        }

        BloxSlider {
            wheelSession: controller
            Layout.fillWidth: true
            enabled: controller.candidate && controller.candidate.shape && controller.candidate.shape.window_gap !== undefined
            label: "Window gap"
            from: 0
            to: 30
            decimals: 0
            value: controller.effectiveWindowGap()
            onMoved: value => controller.setShapeValue("window_gap", Math.round(value))
        }
    }

    Label {
        text: "Cursor"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(12)

        BloxCheckBox {
            Layout.fillWidth: true
            text: "Follow theme roundness"
            enabled: controller.cursorGenerated()
            checked: controller.cursorFollowsThemeRoundness()
            onToggled: value => controller.setCursorFollowsThemeRoundness(value)
        }

        BloxComboBox {
            Layout.preferredWidth: 320
            Layout.fillWidth: true
            enabled: controller.cursorGenerated() && !controller.cursorFollowsThemeRoundness()
            model: ["Classic (square)", "Modern (rounded)"]
            currentIndex: {
                controller.candidateRevision;
                return controller.cursorShapeIndex();
            }
            onActivated: (index, value) => controller.setCursorShape(index)
        }
    }

    BloxSlider {
        wheelSession: controller
        Layout.fillWidth: true
        label: "Cursor size"
        from: 16
        to: 48
        decimals: 0
        value: controller.cursorSize()
        enabled: controller.candidate !== null
        onMoved: value => controller.setCursorSize(Math.round(value))
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(12)

        Label {
            text: "Pointer direction"
            color: Theme.muted
        }

        BloxComboBox {
            Layout.fillWidth: true
            enabled: controller.cursorGenerated()
            model: ["Points right", "Points left"]
            currentIndex: {
                controller.candidateRevision;
                return controller.cursorDirectionIndex();
            }
            onActivated: (index, value) => controller.setCursorDirection(index)
        }
    }

    Label {
        text: "Semantic colours"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 3
        columnSpacing: 10
        rowSpacing: 8

        Repeater {
            model: controller.semanticKeys

            ColumnLayout {
                required property string modelData

                Layout.fillWidth: true

                Label {
                    text: modelData.replace(/_/g, " ")
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 38
                    radius: Theme.scaledRadius(9)
                    color: controller.candidate ? controller.validColour(controller.candidate.colours[modelData], "transparent") : "transparent"
                    border.color: colourHover.hovered ? Theme.foreground : Theme.border
                    border.width: colourHover.hovered ? 2 : 1

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.scaledSpacing(7)
                        text: controller.candidate ? controller.candidate.colours[modelData] : ""
                        color: controller.swatchText(parent.color)
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                        elide: Text.ElideRight
                    }

                    HoverHandler {
                        id: colourHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: controller.openColourPicker(modelData, "")
                    }

                }

            }

        }

    }

    Label {
        text: "Terminal colours"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 4
        columnSpacing: 10
        rowSpacing: 8

        Repeater {
            model: controller.ansiKeys

            ColumnLayout {
                required property string modelData

                Layout.fillWidth: true

                Label {
                    text: modelData
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 38
                    radius: Theme.scaledRadius(9)
                    color: controller.previewData && controller.previewData.ansi ? controller.previewData.ansi[modelData] : "transparent"
                    border.color: ansiColourHover.hovered ? Theme.foreground : Theme.border
                    border.width: ansiColourHover.hovered ? 2 : 1

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.scaledSpacing(7)
                        text: controller.previewData && controller.previewData.ansi ? controller.previewData.ansi[modelData] : ""
                        color: controller.swatchText(parent.color)
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                        elide: Text.ElideRight
                    }

                    HoverHandler {
                        id: ansiColourHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: controller.openColourPicker(modelData, "ansi")
                    }

                }

            }

        }

    }

    Label {
        text: "Bar items"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    Text {
        Layout.fillWidth: true
        text: "Choose which bar items are shown and arrange them within each section. Tray items remain available in the expanded section."
        color: Theme.muted
        font.family: Theme.bodyFontFamily
        wrapMode: Text.Wrap
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(10)

        Repeater {
            model: ["start", "centre", "end", "hidden"]

            ColumnLayout {
                id: regionSection

                required property string modelData

                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(5)

                Label {
                    text: regionSection.modelData === "hidden" ? "Tray" : regionSection.modelData.charAt(0).toUpperCase() + regionSection.modelData.slice(1)
                    color: Theme.blue
                    font.bold: true
                }

                DropArea {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 12
                    z: 1
                    onEntered: controller.setBarDropTarget(regionSection.modelData, 0, "start:" + regionSection.modelData)
                    onDropped: (drop) => {
                        if (drop.source === controller.barDragProxyItem)
                            controller.finishBarDrag();

                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: 3
                        radius: Theme.scaledRadius(2)
                        visible: controller.barDragActive && controller.barDropTarget === "start:" + regionSection.modelData
                        color: Theme.blue
                    }

                }

                Repeater {
                    id: barItemRepeater

                    model: {
                        controller.candidateRevision;
                        return controller.barItems().filter((item) => {
                            return item.region === regionSection.modelData;
                        }).sort((left, right) => {
                            return left.order - right.order;
                        });
                    }

                    Rectangle {
                        id: barItemRow

                        required property var modelData
                        required property int index
                        property string barItemId: modelData.id

                        Layout.fillWidth: true
                        implicitHeight: 48
                        radius: Theme.scaledRadius(8)
                        color: handleDrag.active || emptyDrag.active ? Theme.withAlpha(Theme.blue, 0.15) : Theme.background
                        border.color: handleDrag.active || emptyDrag.active ? Theme.blue : Theme.border
                        z: handleDrag.active || emptyDrag.active ? 20 : 0

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.scaledSpacing(8)
                            spacing: Theme.scaledSpacing(9)

                            Item {
                                Layout.preferredWidth: 18
                                Layout.fillHeight: true

                                PhosphorIcon {
                                    anchors.centerIn: parent
                                    width: 17
                                    height: 17
                                    iconName: "dots-six-vertical"
                                    iconColor: handleHover.hovered ? Theme.foreground : Theme.muted
                                }

                                HoverHandler {
                                    id: handleHover

                                    cursorShape: Qt.SizeAllCursor
                                }

                                DragHandler {
                                    id: handleDrag

                                    target: null
                                    acceptedButtons: Qt.LeftButton
                                    onTranslationChanged: controller.moveBarDragProxy(translation.x, translation.y)
                                    onActiveChanged: {
                                        if (active)
                                            controller.beginBarDrag(barItemRow, barItemRow.barItemId);
                                        else if (controller.barDragActive)
                                            Qt.callLater(controller.finishBarDrag);
                                    }
                                }

                            }

                            RowLayout {
                                Layout.alignment: Qt.AlignVCenter
                                spacing: Theme.scaledSpacing(9)

                                BloxCheckBox {
                                    text: controller.barItemLabel(barItemRow.modelData.id)
                                    checked: barItemRow.modelData.enabled
                                    onToggled: (value) => {
                                        if (value !== barItemRow.modelData.enabled)
                                            controller.setBarItemEnabled(barItemRow.modelData.id, value);

                                    }
                                }

                                BloxComboBox {
                                    readonly property var displayValues: ["toggle", "numeric", "icon"]

                                    visible: barItemRow.modelData.id === "battery"
                                    Layout.preferredWidth: visible ? 132 : 0
                                    Layout.preferredHeight: 32
                                    model: ["click to toggle", "only numeric", "only icon"]
                                    currentIndex: Math.max(0, displayValues.indexOf(barItemRow.modelData.display || "toggle"))
                                    onActivated: (index) => {
                                        return controller.setBarItemDisplay(barItemRow.barItemId, displayValues[index]);
                                    }
                                }

                                BloxComboBox {
                                    readonly property var visibilityValues: ["always", "normal"]

                                    visible: ["privacy", "touchpad", "fan", "gpu"].indexOf(barItemRow.modelData.id) >= 0
                                    Layout.preferredWidth: visible ? 172 : 0
                                    Layout.preferredHeight: 32
                                    model: ["always visible", "hidden when normal"]
                                    currentIndex: Math.max(0, visibilityValues.indexOf(barItemRow.modelData.visibility || "normal"))
                                    onActivated: (index) => {
                                        return controller.setBarItemVisibility(barItemRow.barItemId, visibilityValues[index]);
                                    }
                                }

                                BloxComboBox {
                                    readonly property var orientationValues: ["inward", "outward", "horizontal"]
                                    readonly property string barPosition: controller.shellValue("bar", "position")

                                    visible: barItemRow.modelData.id === "active-window-title" && ["left", "right"].indexOf(barPosition) >= 0
                                    Layout.preferredWidth: visible ? 164 : 0
                                    Layout.preferredHeight: 32
                                    model: ["flip inward", "flip outward", "stay horizontal"]
                                    currentIndex: Math.max(0, orientationValues.indexOf(barItemRow.modelData.orientation || "inward"))
                                    onActivated: (index) => {
                                        return controller.setBarItemOrientation(barItemRow.barItemId, orientationValues[index]);
                                    }
                                }

                                BloxComboBox {
                                    readonly property var titleLengthValues: ["truncate", "full"]

                                    visible: barItemRow.modelData.id === "active-window-title"
                                    Layout.preferredWidth: visible ? 172 : 0
                                    Layout.preferredHeight: 32
                                    model: ["cut off long titles", "show full title"]
                                    currentIndex: Math.max(0, titleLengthValues.indexOf(barItemRow.modelData.titleLength || "truncate"))
                                    onActivated: (index) => {
                                        return controller.setBarItemTitleLength(barItemRow.barItemId, titleLengthValues[index]);
                                    }
                                }

                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                HoverHandler {
                                    cursorShape: Qt.SizeAllCursor
                                }

                                DragHandler {
                                    id: emptyDrag

                                    target: null
                                    acceptedButtons: Qt.LeftButton
                                    onTranslationChanged: controller.moveBarDragProxy(translation.x, translation.y)
                                    onActiveChanged: {
                                        if (active)
                                            controller.beginBarDrag(barItemRow, barItemRow.barItemId);
                                        else if (controller.barDragActive)
                                            Qt.callLater(controller.finishBarDrag);
                                    }
                                }

                            }

                            BloxButton {
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 32
                                compact: true
                                iconName: "caret-up"
                                enabled: barItemRow.modelData.id === "application-tray" ? false : barItemRow.modelData.id === "tray" ? barItemRow.modelData.region === "centre" && barItemRow.index > 0 : barItemRow.index > 0
                                onClicked: controller.moveBarItem(barItemRow.barItemId, -1)
                            }

                            BloxButton {
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 32
                                compact: true
                                iconName: "caret-down"
                                enabled: barItemRow.modelData.id === "application-tray" ? false : barItemRow.modelData.id === "tray" ? barItemRow.modelData.region === "centre" && barItemRow.index === 0 && barItemRepeater.count > 1 : barItemRow.index < barItemRepeater.count - 1
                                onClicked: controller.moveBarItem(barItemRow.barItemId, 1)
                            }

                            BloxComboBox {
                                Layout.preferredWidth: 92
                                Layout.preferredHeight: 32
                                model: barItemRow.modelData.id === "application-tray" ? ["tray"] : barItemRow.modelData.id === "tray" ? ["start", "centre", "end"] : controller.barRegions
                                currentIndex: model.indexOf(barItemRow.modelData.region === "hidden" ? "tray" : barItemRow.modelData.region)
                                onActivated: (index, value) => {
                                    return controller.setBarItemRegion(barItemRow.barItemId, value === "tray" ? "hidden" : value);
                                }
                            }

                        }

                        DropArea {
                            anchors.fill: parent
                            enabled: !(handleDrag.active || emptyDrag.active)
                            z: 2
                            onEntered: (drag) => {
                                const insertion = drag.y < height / 2 ? barItemRow.index : barItemRow.index + 1;
                                controller.setBarDropTarget(regionSection.modelData, insertion, barItemRow.barItemId);
                            }
                            onPositionChanged: (drag) => {
                                const insertion = drag.y < height / 2 ? barItemRow.index : barItemRow.index + 1;
                                controller.setBarDropTarget(regionSection.modelData, insertion, barItemRow.barItemId);
                            }
                            onDropped: (drop) => {
                                if (drop.source === controller.barDragProxyItem)
                                    controller.finishBarDrag();

                            }
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: controller.barDropIndex === barItemRow.index ? parent.top : undefined
                            anchors.bottom: controller.barDropIndex === barItemRow.index + 1 ? parent.bottom : undefined
                            height: 3
                            radius: Theme.scaledRadius(2)
                            z: 40
                            visible: controller.barDragActive && controller.barDropTarget === barItemRow.barItemId
                            color: Theme.blue
                        }

                    }

                }

            }

        }

    }

    GridLayout {
        Layout.fillWidth: true
        columns: 6
        columnSpacing: 8
        rowSpacing: 8

        Label {
            text: "Bar"
            color: Theme.muted
        }

        BloxComboBox {
            Layout.fillWidth: true
            Layout.columnSpan: 5
            model: ["left", "right", "top", "bottom"]
            currentIndex: model.indexOf(controller.shellValue("bar", "position"))
            onActivated: (index, value) => {
                return controller.setShellValue("bar", "position", value);
            }
        }

        Label {
            text: "OSD"
            color: Theme.muted
        }

        BloxComboBox {
            Layout.fillWidth: true
            model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre-top", "centre-bottom"]
            currentIndex: model.indexOf(controller.shellValue("osd", "position"))
            onActivated: (index, value) => {
                return controller.setShellValue("osd", "position", value);
            }
        }

        Label {
            text: "X offset"
            color: Theme.muted
        }

        BloxTextField {
            text: String(controller.shellValue("osd", "offset_x"))
            suffix: "px"
            onEditingFinished: controller.setShellValue("osd", "offset_x", parseInt(text) || 0)
        }

        Label {
            text: "Y offset"
            color: Theme.muted
        }

        BloxTextField {
            text: String(controller.shellValue("osd", "offset_y"))
            suffix: "px"
            onEditingFinished: controller.setShellValue("osd", "offset_y", parseInt(text) || 0)
        }

        Label {
            text: "Notifications"
            color: Theme.muted
        }

        BloxComboBox {
            Layout.fillWidth: true
            model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre-top", "centre-bottom"]
            currentIndex: model.indexOf(controller.shellValue("notifications", "position"))
            onActivated: (index, value) => {
                return controller.setShellValue("notifications", "position", value);
            }
        }

        Label {
            text: "X offset"
            color: Theme.muted
        }

        BloxTextField {
            text: String(controller.shellValue("notifications", "offset_x"))
            suffix: "px"
            onEditingFinished: controller.setShellValue("notifications", "offset_x", parseInt(text) || 0)
        }

        Label {
            text: "Y offset"
            color: Theme.muted
        }

        BloxTextField {
            text: String(controller.shellValue("notifications", "offset_y"))
            suffix: "px"
            onEditingFinished: controller.setShellValue("notifications", "offset_y", parseInt(text) || 0)
        }

    }

    Label {
        text: "Fonts"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 3

        Repeater {
            model: ["ui", "mono", "panel"]

            ColumnLayout {
                required property string modelData

                Layout.fillWidth: true

                Label {
                    text: modelData === "panel" ? "panel · proportional fonts recommended" : modelData
                    color: Theme.muted
                }

                BloxFontPicker {
                    Layout.fillWidth: true
                    families: controller.fontFamilies
                    value: {
                        controller.candidateRevision;
                        return controller.candidate ? controller.candidate.fonts[modelData] : "";
                    }
                    onAccepted: (family) => {
                        return controller.setFont(modelData, family);
                    }
                }

            }

        }

    }

    ThemePickerIconTheme {
        controller: section.controller
        gtkDetail: "File manager and settings"
        quickshellDetail: "Launcher and notifications"
    }

    Label {
        text: "Theme targets"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    Label {
        text: "Core"
        color: Theme.blue
        font.bold: true
    }

    Flow {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Repeater {
            model: controller.coreTargetKeys

            Rectangle {
                required property string modelData

                width: 250
                height: 54
                radius: Theme.scaledRadius(8)
                color: Theme.background
                border.color: Theme.border

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(7)

                    BloxCheckBox {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: controller.targetLabel(modelData)
                        checked: {
                            controller.candidateRevision;
                            return controller.candidate ? controller.candidate.targets[modelData] : false;
                        }
                        onToggled: (value) => {
                            if (controller.candidate && value !== controller.candidate.targets[modelData])
                                controller.setTarget(modelData, value);

                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        text: controller.targetModeLabel(modelData)
                        color: controller.targetApplyMode(modelData) === "restart" ? Theme.yellow : Theme.green
                        font.pixelSize: 9
                    }

                }

            }

        }

    }

    Label {
        text: "Applications"
        color: Theme.blue
        font.bold: true
    }

    Flow {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Repeater {
            model: controller.applicationTargetKeys

            Rectangle {
                required property string modelData

                width: 250
                height: 54
                radius: Theme.scaledRadius(8)
                color: Theme.background
                border.color: Theme.border

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(7)

                    BloxCheckBox {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: controller.targetLabel(modelData)
                        checked: {
                            controller.candidateRevision;
                            return controller.candidate ? controller.candidate.targets[modelData] : false;
                        }
                        onToggled: (value) => {
                            if (controller.candidate && value !== controller.candidate.targets[modelData])
                                controller.setTarget(modelData, value);

                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        visible: controller.targetApplyMode(modelData) !== "manual"
                        text: controller.targetModeLabel(modelData)
                        color: controller.targetApplyMode(modelData) === "restart" ? Theme.yellow : Theme.green
                        font.pixelSize: 9
                    }

                    BloxButton {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredHeight: 32
                        visible: controller.targetApplyMode(modelData) === "manual"
                        text: "Guide"
                        onClicked: {
                            controller.openGuide(modelData, "");
                        }
                    }

                }

            }

        }

    }

    Label {
        visible: controller.browserTargetKeys.length > 0
        text: "Browsers"
        color: Theme.blue
        font.bold: true
    }

    Flow {
        visible: controller.browserTargetKeys.length > 0
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Repeater {
            model: controller.browserTargetKeys

            Rectangle {
                required property string modelData

                width: 250
                height: 54
                radius: Theme.scaledRadius(8)
                color: Theme.background
                border.color: Theme.border

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(7)

                    BloxCheckBox {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: controller.targetLabel(modelData)
                        checked: {
                            controller.candidateRevision;
                            return controller.candidate && controller.candidate.targets ? controller.candidate.targets[modelData] === true : false;
                        }
                        onToggled: (value) => {
                            if (controller.candidate && value !== controller.candidate.targets[modelData])
                                controller.setTarget(modelData, value);

                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        text: controller.targetModeLabel(modelData)
                        color: controller.targetApplyMode(modelData) === "restart" ? Theme.yellow : Theme.green
                        font.pixelSize: 9
                    }

                }

            }

        }

    }

    Label {
        text: "Stylus"
        color: Theme.blue
        font.bold: true
    }

    BloxComboBox {
        Layout.fillWidth: true
        model: controller.stylusStyleSetNames
        currentIndex: controller.stylusStyleSetIndex()
        onActivated: (index, value) => controller.setStylusStyleSet(index)
    }

    Label {
        text: "Unavailable"
        color: Theme.muted
        font.bold: true
    }

    Flow {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Repeater {
            model: controller.unavailableTargetKeys

            BloxCheckBox {
                required property string modelData

                text: controller.targetLabel(modelData)
                checked: false
                enabled: controller.targetAvailable(modelData)
            }

        }

    }

    Label {
        text: "Generated Files"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    Text {
        Layout.fillWidth: true
        text: "Download the generated files for the currently selected targets. Apply or save the theme first so the active generation is up to date."
        color: Theme.muted
        font.family: Theme.bodyFontFamily
        wrapMode: Text.Wrap
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Repeater {
            model: {
                controller.candidateRevision;
                return controller.generatedFileGroups();
            }

            ColumnLayout {
                required property var modelData

                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(6)

                RowLayout {
                    Layout.fillWidth: true

                    Label {
                        Layout.fillWidth: true
                        text: controller.targetLabel(modelData.target)
                        color: Theme.blue
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        font.bold: true
                    }

                    BloxButton {
                        visible: modelData.files.length > 1
                        iconName: "download-simple"
                        text: "Download all (.zip)"
                        onClicked: controller.downloadGeneratedArchive(modelData.target)
                    }

                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(8)

                    Repeater {
                        model: modelData.files

                        BloxButton {
                            required property var modelData

                            iconName: "download-simple"
                            text: modelData.name
                            onClicked: controller.downloadGeneratedFile(modelData.target, modelData.file)
                        }

                    }

                }

            }

        }

    }

    Label {
        text: "Target-specific colour overrides"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    Repeater {
        model: ["gtk", "hyprlock"]

        ColumnLayout {
            required property string modelData

            Layout.fillWidth: true

            Label {
                text: modelData
                color: Theme.blue
                font.family: Theme.fontFamily
                font.pixelSize: 12
            }

            RowLayout {
                Repeater {
                    model: controller.overrideKeys

                    ColumnLayout {
                        id: overrideEditor

                        required property string modelData
                        property string targetName: parent.parent.modelData
                        property string overrideValue: {
                            controller.candidateRevision;
                            const values = controller.candidate && controller.candidate.overrides && controller.candidate.overrides[targetName];
                            return values && values[modelData] ? values[modelData] : "";
                        }

                        Layout.fillWidth: true

                        Label {
                            text: modelData
                            color: Theme.muted
                            font.pixelSize: 9
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Rectangle {
                                Layout.fillWidth: true
                                height: 38
                                radius: Theme.scaledRadius(9)
                                color: overrideEditor.overrideValue || Theme.background
                                border.color: overrideHover.hovered ? Theme.foreground : Theme.border
                                border.width: overrideHover.hovered ? 2 : 1

                                Text {
                                    anchors.fill: parent
                                    anchors.margins: Theme.scaledSpacing(9)
                                    text: overrideEditor.overrideValue || "inherit"
                                    color: overrideEditor.overrideValue ? controller.swatchText(parent.color) : Theme.muted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 9
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                }

                                HoverHandler {
                                    id: overrideHover

                                    cursorShape: Qt.PointingHandCursor
                                }

                                TapHandler {
                                    onTapped: controller.openColourPicker(overrideEditor.modelData, overrideEditor.targetName)
                                }

                            }

                            BloxButton {
                                visible: overrideEditor.overrideValue.length > 0
                                Layout.preferredWidth: 38
                                iconName: "arrow-counter-clockwise"
                                text: ""
                                onClicked: controller.setOverride(overrideEditor.targetName, overrideEditor.modelData, "")
                            }

                        }

                    }

                }

            }

        }

    }

}
