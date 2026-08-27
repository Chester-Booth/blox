import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: section

    required property ThemePickerController controller

    visible: controller.editorMode === "overview"
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(14)

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(6)

        Label {
            text: "Theme name"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(10)

            BloxTextField {
                Layout.fillWidth: true
                placeholderText: "My Theme"
                text: {
                    controller.candidateRevision;
                    return controller.candidate ? controller.candidate.name : "";
                }
                onEditingFinished: {
                    if (controller.candidate)
                        controller.setTopLevel("name", text.trim());

                }
            }

            Text {
                text: controller.candidate ? controller.candidate.id : ""
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: 9
                elide: Text.ElideMiddle
                Layout.maximumWidth: 260
            }

        }

        Label {
            text: "Style"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 10

            Repeater {
                model: [
                    {"label": "Round", "value": 1.25},
                    {"label": "Slightly round", "value": 0.65},
                    {"label": "Square", "value": 0}
                ]

                Rectangle {
                    id: styleChoice

                    required property var modelData
                    readonly property bool selected: Math.abs(controller.shapeValue("radius_scale", 1.25) - modelData.value) < 0.001

                    Layout.fillWidth: true
                    Layout.preferredHeight: 116
                    radius: Theme.cardRadius
                    color: selected ? Theme.withAlpha(Theme.accent, 0.14) : Theme.background
                    border.color: selected ? Theme.accent : styleHover.hovered ? Theme.foreground : Theme.border
                    border.width: selected ? 2 : 1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(8)
                        spacing: Theme.scaledSpacing(6)

                        Label {
                            text: styleChoice.modelData.label
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.bold: true
                        }

                        ThemeShapePreview {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radiusScale: styleChoice.modelData.value
                            densityScale: controller.shapeValue("density_scale", 1.0)
                            windowGap: controller.effectiveWindowGap()
                        }
                    }

                    HoverHandler {
                        id: styleHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: controller.setShapeValue("radius_scale", styleChoice.modelData.value)
                    }
                }
            }
        }

        Label {
            text: "Density"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 10

            Repeater {
                model: [
                    {"label": "Compact", "value": 0.75, "gap": 0},
                    {"label": "Comfortable", "value": 1.0, "gap": 5},
                    {"label": "Spacious", "value": 1.5, "gap": 15}
                ]

                Rectangle {
                    id: densityChoice

                    required property var modelData
                    readonly property bool selected: Math.abs(controller.shapeValue("density_scale", 1.0) - modelData.value) < 0.001

                    Layout.fillWidth: true
                    Layout.preferredHeight: 116
                    radius: Theme.cardRadius
                    color: selected ? Theme.withAlpha(Theme.accent, 0.14) : Theme.background
                    border.color: selected ? Theme.accent : densityHover.hovered ? Theme.foreground : Theme.border
                    border.width: selected ? 2 : 1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(8)
                        spacing: Theme.scaledSpacing(6)

                        Label {
                            text: densityChoice.modelData.label
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.bold: true
                        }

                        ThemeShapePreview {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radiusScale: controller.shapeValue("radius_scale", 1.25)
                            densityScale: densityChoice.modelData.value
                            windowGap: controller.candidate && controller.candidate.shape && controller.candidate.shape.window_gap !== undefined
                                ? controller.candidate.shape.window_gap
                                : densityChoice.modelData.gap
                        }
                    }

                    HoverHandler {
                        id: densityHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: controller.setShapeValue("density_scale", densityChoice.modelData.value)
                    }
                }
            }
        }

        Label {
            text: "Bar / OSD / Notifications"
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
                text: "Bar position"
                color: Theme.muted
            }

            BloxComboBox {
                Layout.fillWidth: true
                model: ["left", "right", "top", "bottom"]
                currentIndex: model.indexOf(controller.shellValue("bar", "position"))
                onActivated: (index, value) => {
                    return controller.setShellValue("bar", "position", value);
                }
            }

            Label {
                text: "OSD position"
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
                text: "Notification position"
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

        }

    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(12)

        Label {
            text: "Wallpaper"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        RowLayout {
            Layout.fillWidth: true

            BloxTextField {
                Layout.fillWidth: true
                placeholderText: "/path/to/wallpaper"
                text: {
                    controller.candidateRevision;
                    return controller.candidate && controller.candidate.wallpaper ? controller.wallpaperDisplayPath(controller.candidate.wallpaper.path) : "";
                }
                onEditingFinished: {
                    controller.setWallpaperDisplayPath(text);
                }
            }

            BloxButton {
                text: "Browse"
                onClicked: controller.openWallpaperDialog("overview")
            }

            BloxComboBox {
                model: ["cover", "contain", "tile"]
                currentIndex: controller.candidate && controller.candidate.wallpaper ? model.indexOf(controller.candidate.wallpaper.fit) : 0
                onActivated: (index, selectedText) => {
                    const next = controller.cloneCandidate();
                    next.wallpaper.fit = selectedText;
                    controller.markCandidate(next, "wallpaper.fit");
                }
            }

        }

        Label {
            text: "Semantic palette"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        Flow {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)

            Repeater {
                model: controller.semanticKeys

                Rectangle {
                    id: semanticSwatch

                    required property string modelData

                    width: 112
                    height: 72
                    radius: Theme.scaledRadius(6)
                    color: controller.candidate && controller.candidate.colours ? controller.validColour(controller.candidate.colours[modelData], "transparent") : "transparent"
                    border.color: Theme.withAlpha(Theme.foreground, 0.45)

                    BloxToolTip {
                        shown: semanticHover.hovered && semanticLabel.truncated
                        text: modelData.replace(/_/g, " ")
                    }

                    HoverHandler {
                        id: semanticHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: controller.openColourPicker(modelData, "")
                    }

                    Text {
                        id: semanticLabel

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.scaledSpacing(6)
                        text: modelData.replace(/_/g, " ")
                        color: controller.swatchText(parent.color)
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                    }

                }

            }

        }

        Label {
            text: "Terminal palette"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        Flow {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(6)

            Repeater {
                model: controller.ansiKeys

                Rectangle {
                    required property string modelData

                    width: 58
                    height: 34
                    radius: Theme.scaledRadius(5)
                    color: controller.previewData && controller.previewData.ansi ? controller.previewData.ansi[modelData] : "transparent"
                    border.color: Theme.border

                    Text {
                        anchors.centerIn: parent
                        text: modelData.replace("color", "")
                        color: controller.swatchText(parent.color)
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                    }

                }

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
            columnSpacing: 10

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
                            return controller.candidate && controller.candidate.fonts ? controller.candidate.fonts[modelData] : "";
                        }
                        onAccepted: (family) => {
                            return controller.setFont(modelData, family);
                        }
                    }

                }

            }

        }

        Label {
            text: "Font samples"
            color: Theme.muted
        }

        Rectangle {
            Layout.fillWidth: true
            height: 116
            radius: Theme.scaledRadius(7)
            color: Theme.background
            border.color: Theme.border

            Column {
                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(12)
                spacing: Theme.scaledSpacing(7)

                Text {
                    text: "Interface — Notifications and theme picker 0123456789"
                    color: Theme.foreground
                    font.family: controller.candidate ? controller.candidate.fonts.ui : Theme.bodyFontFamily
                    font.pixelSize: 16
                }

                Text {
                    text: "const accent = \"#89b4fa\";  {} [] () => ⚡󰍹"
                    color: Theme.foreground
                    font.family: controller.candidate ? controller.candidate.fonts.mono : Theme.monoFontFamily
                    font.pixelSize: 14
                }

                Text {
                    text: "Panel 󰕾 󰂄 󰤨 󰔛 󰖩"
                    color: Theme.foreground
                    font.family: controller.candidate ? controller.candidate.fonts.panel : Theme.fontFamily
                    font.pixelSize: 14
                }

            }

        }

    }

}
