import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    required property ThemePickerController controller

    function focusInitial() {
        if (controller.newFlowPage === "wallpaper")
            newWallpaperField.focusEditor(true);
        else
            newNameField.focusEditor(true);
    }

    visible: controller.modalKind === "new"
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(12)

    Label {
        visible: controller.modalKind === "new" && !controller.creationBusy
        text: "Name"
        color: Theme.foreground
        font.bold: true
    }

    BloxTextField {
        id: newNameField

        visible: controller.modalKind === "new" && !controller.creationBusy
        Layout.fillWidth: true
        placeholderText: "My Theme"
        text: controller.newThemeName
        onTextChanged: {
            controller.newThemeName = text;
            controller.newThemeId = controller.duplicateIdForName(text);
        }
        onAccepted: {
            if (controller.newThemeId.trim().length > 0 && controller.newThemeName.trim().length > 0)
                controller.startNewTheme(false);

        }
    }

    Label {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "blank"
        text: "Appearance"
        color: Theme.foreground
        font.bold: true
    }

    RowLayout {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "blank"
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(0)

        Repeater {
            model: ["dark", "light"]

            BloxButton {
                required property string modelData

                Layout.fillWidth: true
                text: modelData === "dark" ? "Dark" : "Light"
                checked: controller.newVariant === modelData
                onClicked: controller.newVariant = modelData
            }

        }

    }

    Label {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "wallpaper"
        text: "File Path"
        color: Theme.foreground
        font.bold: true
    }

    RowLayout {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "wallpaper"
        Layout.fillWidth: true

        BloxTextField {
            id: newWallpaperField

            Layout.fillWidth: true
            placeholderText: "/path/to/wallpaper"
            text: controller.newWallpaper
            onTextChanged: {
                controller.newWallpaper = text;
                controller.schedulePaletteRequest();
            }
        }

        BloxButton {
            text: "Browse"
            onClicked: controller.openWallpaperDialog("new")
        }

    }

    Label {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "wallpaper" && controller.newWallpaper.trim().length > 0
        text: "Generated Colour Palettes"
        color: Theme.foreground
        font.bold: true
    }

    BusyIndicator {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.paletteLoading
        running: visible
        Layout.alignment: Qt.AlignHCenter
    }

    GridLayout {
        visible: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "wallpaper"
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 10
        rowSpacing: 10

        Repeater {
            model: controller.modalKind === "new" && !controller.creationBusy && controller.newFlowPage === "wallpaper" ? controller.paletteOptions : []

            Rectangle {
                id: palettePill

                required property var modelData
                readonly property var colourRoles: ["background", "surface", "surface_alt", "foreground", "muted", "accent", "danger", "success", "warning", "border", "info", "mauve", "selection_background", "selection_foreground", "teal"]
                readonly property bool selected: controller.generatorBackend === modelData.backend && controller.newVariant === modelData.mode

                function choose() {
                    if (!modelData.available)
                        return ;

                    controller.generatorBackend = modelData.backend;
                    controller.newVariant = modelData.mode;
                }

                Layout.fillWidth: true
                Layout.preferredHeight: 132
                radius: Theme.scaledRadius(9)
                color: modelData.colours.background || Theme.background
                border.color: activeFocus || selected ? Theme.blue : (modelData.colours.border || Theme.border)
                border.width: activeFocus || selected ? 2 : 1
                opacity: modelData.available ? 1 : 0.5
                clip: true
                activeFocusOnTab: modelData.available
                Keys.onSpacePressed: choose()
                Keys.onReturnPressed: choose()
                Keys.onEnterPressed: choose()

                Rectangle {
                    x: 10
                    y: 9
                    width: 16
                    height: 16
                    radius: Theme.scaledRadius(8)
                    color: "transparent"
                    border.color: palettePill.selected ? Theme.blue : (palettePill.modelData.colours.muted || Theme.muted)
                    border.width: 2

                    Rectangle {
                        visible: palettePill.selected
                        anchors.centerIn: parent
                        width: 7
                        height: 7
                        radius: Theme.scaledRadius(4)
                        color: Theme.blue
                    }

                }

                Text {
                    x: 34
                    y: 8
                    text: (modelData.backend === "matugen" ? "Matugen" : "Pywal") + "  •  " + (modelData.mode === "light" ? "Light" : "Dark")
                    color: modelData.colours.foreground || Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                    font.bold: true
                }

                Rectangle {
                    x: 10
                    y: 32
                    width: parent.width - 20
                    height: 74
                    radius: Theme.scaledRadius(6)
                    color: modelData.colours.background || Theme.background
                    border.color: modelData.colours.border || Theme.border
                    clip: true

                    Image {
                        x: 0
                        y: 0
                        width: parent.width * 0.49
                        height: parent.height
                        source: "file://" + controller.newWallpaper.trim()
                        fillMode: Image.PreserveAspectCrop
                    }

                    Rectangle {
                        x: 0
                        y: 0
                        width: parent.width * 0.49
                        height: 10
                        radius: Theme.scaledRadius(0)
                        color: palettePill.modelData.colours.surface_alt || Theme.surfaceAlt

                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaledSpacing(5)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.scaledSpacing(3)

                            Repeater {
                                model: [palettePill.modelData.colours.accent, palettePill.modelData.colours.success, palettePill.modelData.colours.warning]

                                Rectangle {
                                    required property color modelData

                                    width: 5
                                    height: 5
                                    radius: Theme.scaledRadius(3)
                                    color: modelData
                                }

                            }

                        }

                    }

                    Rectangle {
                        x: parent.width * 0.52
                        y: 5
                        width: parent.width * 0.45
                        height: 64
                        radius: Theme.scaledRadius(5)
                        color: palettePill.modelData.colours.surface || Theme.surface
                        border.color: palettePill.modelData.colours.border || Theme.border

                        Rectangle {
                            x: 6
                            y: 7
                            width: parent.width - 12
                            height: 20
                            radius: Theme.scaledRadius(5)
                            color: palettePill.modelData.colours.selection_background || Theme.accent

                            Rectangle {
                                x: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 8
                                radius: Theme.scaledRadius(2)
                                color: palettePill.modelData.colours.selection_foreground || Theme.background
                            }

                            Rectangle {
                                x: 19
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 38
                                height: 4
                                radius: Theme.scaledRadius(2)
                                color: palettePill.modelData.colours.selection_foreground || Theme.background
                            }

                        }

                        Repeater {
                            model: 2

                            Rectangle {
                                required property int index

                                x: 12
                                y: 35 + index * 12
                                width: index === 0 ? parent.width - 24 : parent.width * 0.52
                                height: 4
                                radius: Theme.scaledRadius(2)
                                color: index === 0 ? (palettePill.modelData.colours.foreground || Theme.foreground) : (palettePill.modelData.colours.muted || Theme.muted)
                            }

                        }

                    }

                }

                Row {
                    x: 10
                    y: 112
                    width: parent.width - 20
                    spacing: Theme.scaledSpacing(3)

                    Repeater {
                        model: palettePill.colourRoles

                        Rectangle {
                            required property string modelData

                            width: (palettePill.width - 20 - 42) / 15
                            height: 10
                            radius: Theme.scaledRadius(3)
                            color: palettePill.modelData.colours[modelData] || "transparent"
                            border.color: palettePill.modelData.colours.border || Theme.border
                        }

                    }

                }

                Text {
                    visible: !modelData.available
                    anchors.centerIn: parent
                    width: parent.width - 24
                    text: modelData.reason || "Unavailable"
                    color: Theme.red
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 9
                }

                TapHandler {
                    enabled: modelData.available
                    onTapped: {
                        palettePill.forceActiveFocus();
                        palettePill.choose();
                    }
                }

            }

        }

    }

    ColumnLayout {
        visible: controller.modalKind === "new" && controller.creationBusy
        Layout.fillWidth: true

        BusyIndicator {
            running: visible
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: controller.creationRequest && controller.creationRequest.wallpaper ? controller.creationRequest.backend + " — generating palette and theme" : "Creating blank theme"
            color: Theme.blue
        }

    }

}
