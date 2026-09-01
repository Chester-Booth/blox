import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    required property ThemePickerController controller

    Layout.preferredWidth: 265
    Layout.fillHeight: true
    radius: Theme.scaledRadius(8)
    color: Theme.surface
    border.color: Theme.border

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(10)
        spacing: Theme.scaledSpacing(8)

        BloxTextField {
            Layout.fillWidth: true
            placeholderText: "Search themes"
            text: controller.searchText
            onTextChanged: controller.searchText = text
        }

        BloxButton {
            Layout.fillWidth: true
            iconName: "plus"
            iconSize: 20
            text: "New theme"
            enabled: controller.candidate && !controller.dirty && !controller.busy
            onClicked: newThemeMenu.open()

            Popup {
                id: newThemeMenu

                y: parent.height + 5
                width: parent.width
                padding: Theme.scaledSpacing(5)
                modal: false
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                contentItem: Column {
                    spacing: Theme.scaledSpacing(4)

                    BloxButton {
                        width: parent.width
                        text: "From blank"
                        onClicked: {
                            newThemeMenu.close();
                            controller.openNewTheme(false);
                        }
                    }

                    BloxButton {
                        width: parent.width
                        text: "From wallpaper"
                        onClicked: {
                            newThemeMenu.close();
                            controller.openNewTheme(true);
                        }
                    }

                }

                background: Rectangle {
                    radius: Theme.scaledRadius(10)
                    color: Theme.surfaceAlt
                    border.color: Theme.border
                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(6)

            BloxButton {
                Layout.fillWidth: true
                iconName: "download-simple"
                text: "Import"
                enabled: !controller.dirty && !controller.busy
                onClicked: controller.openImportDialog()
            }

            BloxButton {
                Layout.fillWidth: true
                iconName: "upload-simple"
                text: "Export"
                enabled: controller.candidate && controller.sourceDigest.length > 0 && !controller.dirty && !controller.busy
                onClicked: controller.openExportDialog()
            }

        }

        ListView {
            id: themeList

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.scaledSpacing(4)
            model: controller.filteredThemes()
            boundsBehavior: Flickable.StopAtBounds

            BloxWheelHandler {
                flickable: themeList
            }

            ScrollBar.vertical: ScrollBar {
                id: themeScrollbar

                policy: themeList.contentHeight > themeList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                width: 8

                background: Rectangle {
                    radius: Theme.scaledRadius(3)
                    color: Theme.withAlpha(Theme.foreground, 0.04)
                }

                contentItem: Rectangle {
                    implicitWidth: 6
                    radius: Theme.scaledRadius(3)
                    color: themeScrollbar.hovered || themeScrollbar.pressed ? Theme.foreground : Theme.muted
                }

            }

            delegate: Rectangle {
                id: themeDelegate

                required property var modelData
                readonly property bool selected: modelData.id === controller.selectedId
                readonly property color previewBackground: controller.themePreviewColour(modelData, "background", Theme.background)
                readonly property color previewSurface: controller.themePreviewColour(modelData, "surface", Theme.surface)
                readonly property color previewSurfaceAlt: controller.themePreviewColour(modelData, "surface_alt", Theme.surfaceAlt)
                readonly property color previewForeground: controller.themePreviewColour(modelData, "foreground", Theme.foreground)
                readonly property color previewMuted: controller.themePreviewColour(modelData, "muted", Theme.muted)
                readonly property color previewAccent: controller.themePreviewColour(modelData, "accent", Theme.blue)
                readonly property color previewSuccess: controller.themePreviewColour(modelData, "success", Theme.green)
                readonly property color previewWarning: controller.themePreviewColour(modelData, "warning", Theme.yellow)
                readonly property string previewFont: modelData.preview && modelData.preview.fonts && modelData.preview.fonts.ui ? modelData.preview.fonts.ui : Theme.bodyFontFamily
                readonly property string previewBarPosition: controller.themePreviewBarPosition(modelData)
                readonly property bool verticalBar: previewBarPosition === "left" || previewBarPosition === "right"
                readonly property real maxPreviewWidth: width * 0.5
                readonly property real minPreviewWidth: width * 0.3
                readonly property real normalWrapWidth: Math.max(themeTitleMetrics.advanceWidth * 0.65, longestWordMetrics.advanceWidth)
                readonly property real previewWidth: Math.max(minPreviewWidth, Math.min(maxPreviewWidth, width - 59 - normalWrapWidth))
                readonly property bool previewAtMinimum: previewWidth <= minPreviewWidth + 0.5

                width: themeList.width - (themeList.contentHeight > themeList.height ? 10 : 0)
                height: 82
                radius: Theme.scaledRadius(10)
                color: selected ? previewSurface : mouse.containsMouse ? Qt.lighter(previewBackground, 1.13) : previewBackground
                border.color: modelData.unsaved ? previewWarning : selected ? previewAccent : mouse.containsMouse ? previewForeground : modelData.id === Theme.activeThemeId ? previewAccent : previewSurfaceAlt
                border.width: selected ? 2 : 1
                scale: mouse.containsMouse && !selected ? 1.008 : 1
                transformOrigin: Item.Center

                Rectangle {
                    id: themeThumbnail

                    x: 8
                    y: 8
                    width: themeDelegate.previewWidth
                    height: themeDelegate.height - 16
                    radius: Theme.scaledRadius(7)
                    color: themeDelegate.previewSurface
                    clip: true

                    Image {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(3)
                        source: themeDelegate.modelData.preview && themeDelegate.modelData.preview.wallpaper ? controller.localFileUrl(themeDelegate.modelData.preview.wallpaper) : ""
                        fillMode: Image.PreserveAspectCrop
                        visible: source.toString().length > 0
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(3)
                        radius: Theme.scaledRadius(5)
                        color: "#18000000"
                    }

                    Rectangle {
                        id: themeBarPreview

                        x: themeDelegate.previewBarPosition === "right" ? parent.width - width - 3 : 3
                        y: themeDelegate.previewBarPosition === "bottom" ? parent.height - height - 3 : 3
                        width: themeDelegate.verticalBar ? 5 : parent.width - 6
                        height: themeDelegate.verticalBar ? parent.height - 6 : 5
                        color: themeDelegate.previewSurface

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.scaledSpacing(2)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: !themeDelegate.verticalBar

                            Repeater {
                                model: controller.themePreviewBarCount(themeDelegate.modelData, "start")

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: themeDelegate.previewForeground
                                }

                            }

                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.scaledSpacing(1)
                            visible: !themeDelegate.verticalBar

                            Repeater {
                                model: controller.themePreviewBarCount(themeDelegate.modelData, "centre")

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: themeDelegate.previewAccent
                                }

                            }

                        }

                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaledSpacing(2)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: !themeDelegate.verticalBar

                            Repeater {
                                model: controller.themePreviewBarCount(themeDelegate.modelData, "end")

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: themeDelegate.previewForeground
                                }

                            }

                        }

                        Column {
                            anchors.top: parent.top
                            anchors.topMargin: Theme.scaledSpacing(2)
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: themeDelegate.verticalBar

                            Repeater {
                                model: controller.themePreviewBarCount(themeDelegate.modelData, "start")

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: themeDelegate.previewForeground
                                }

                            }

                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.scaledSpacing(1)
                            visible: themeDelegate.verticalBar

                            Repeater {
                                model: controller.themePreviewBarCount(themeDelegate.modelData, "centre")

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: themeDelegate.previewAccent
                                }

                            }

                        }

                        Column {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.scaledSpacing(2)
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: themeDelegate.verticalBar

                            Repeater {
                                model: controller.themePreviewBarCount(themeDelegate.modelData, "end")

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: themeDelegate.previewForeground
                                }

                            }

                        }

                    }

                }

                Item {
                    id: themeIdentity

                    x: themeThumbnail.x + themeThumbnail.width + 10
                    y: 7
                    width: themeDelegate.width - x - 8
                    height: themeDelegate.height - 14

                    TextMetrics {
                        id: themeTitleMetrics

                        font.family: themeDelegate.previewFont
                        font.pixelSize: 17
                        font.bold: true
                        text: themeDelegate.modelData.name
                    }

                    TextMetrics {
                        id: longestWordMetrics

                        font.family: themeDelegate.previewFont
                        font.pixelSize: 17
                        font.bold: true
                        text: controller.longestWord(themeDelegate.modelData.name)
                    }

                    Row {
                        id: themePalette

                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        spacing: Theme.scaledSpacing(5)

                        Repeater {
                            model: [themeDelegate.previewAccent, themeDelegate.previewSuccess, themeDelegate.previewWarning, themeDelegate.previewForeground]

                            Rectangle {
                                required property color modelData

                                width: Math.max(14, Math.min(24, (themeIdentity.width - 15) / 4))
                                height: 6
                                radius: Theme.scaledRadius(3)
                                color: modelData
                            }

                        }

                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.scaledSpacing(33)
                        anchors.bottom: themePalette.top
                        anchors.bottomMargin: Theme.scaledSpacing(4)
                        height: 42
                        text: themeDelegate.modelData.name
                        color: themeDelegate.previewForeground
                        font.family: themeDelegate.previewFont
                        font.pixelSize: 17
                        font.bold: true
                        fontSizeMode: themeDelegate.previewAtMinimum ? Text.Fit : Text.FixedSize
                        minimumPixelSize: 1
                        horizontalAlignment: Text.AlignLeft
                        verticalAlignment: Text.AlignBottom
                        wrapMode: Text.WordWrap
                        elide: Text.ElideNone
                        clip: true
                    }

                }

                Rectangle {
                    z: 2
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaledSpacing(7)
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 34
                    radius: Theme.scaledRadius(8)
                    color: kebabMouse.containsMouse || themeActions.visible ? Theme.withAlpha(themeDelegate.previewAccent, 0.22) : "transparent"

                    PhosphorIcon {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        iconName: "dots-three"
                        iconColor: kebabMouse.containsMouse || themeActions.visible ? themeDelegate.previewForeground : themeDelegate.previewMuted
                    }

                    MouseArea {
                        id: kebabMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: themeActions.open()
                    }

                }

                MouseArea {
                    id: mouse

                    anchors.fill: parent
                    anchors.rightMargin: Theme.scaledSpacing(38)
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (event) => {
                        if (event.button === Qt.RightButton)
                            themeActions.open();
                        else if (modelData.id !== controller.selectedId)
                            controller.requestSelection(modelData.id, true);
                    }
                }

                Popup {
                    id: themeActions

                    parent: themeDelegate
                    popupType: Popup.Item
                    modal: true
                    dim: false
                    x: themeDelegate.width - width - 6
                    y: 48
                    width: 154
                    height: actionColumn.implicitHeight + 8
                    padding: Theme.scaledSpacing(4)
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                    contentItem: Column {
                        id: actionColumn

                        spacing: Theme.scaledSpacing(4)

                        BloxButton {
                            width: parent.width
                            text: "Duplicate"
                            enabled: modelData.id !== controller.selectedId || !controller.dirty
                            onClicked: {
                                themeActions.close();
                                controller.openDuplicate(modelData.id, modelData.name);
                            }
                        }

                        BloxButton {
                            width: parent.width
                            text: "Rename"
                            enabled: !modelData.unsaved && !modelData.builtin && (modelData.id !== controller.selectedId || !controller.dirty)
                            onClicked: {
                                themeActions.close();
                                controller.openRename(modelData.id, modelData.name);
                            }
                        }

                        BloxButton {
                            width: parent.width
                            text: "Delete"
                            destructive: true
                            enabled: !modelData.unsaved && !modelData.builtin && (modelData.id !== controller.selectedId || !controller.dirty) && !controller.busy
                            onClicked: {
                                themeActions.close();
                                controller.requestDelete(modelData.id, modelData.name, modelData.builtin);
                            }
                        }

                    }

                    background: Rectangle {
                        radius: Theme.scaledRadius(10)
                        color: Theme.surfaceAlt
                        border.color: Theme.border
                    }

                }

                Behavior on color {
                    ColorAnimation {
                        duration: 110
                    }

                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 110
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: 110
                        easing.type: Easing.OutCubic
                    }

                }

            }

        }

    }

}
