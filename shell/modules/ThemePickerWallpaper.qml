import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: section

    required property ThemePickerController controller

    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(10)

    Label {
        text: "Wallpaper"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(10)

        Label {
            text: "Fit"
            color: Theme.muted
            font.family: Theme.bodyFontFamily
        }

        BloxComboBox {
            Layout.preferredWidth: 132
            model: ["cover", "contain", "tile"]
            currentIndex: controller.candidate && controller.candidate.wallpaper ? model.indexOf(controller.candidate.wallpaper.fit) : 0
            onActivated: (index, value) => {
                const next = controller.cloneCandidate();
                next.wallpaper.fit = value;
                controller.markCandidate(next, "wallpaper.fit");
            }
        }

        Item {
            Layout.fillWidth: true
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: wallpaperPanelColumn.implicitHeight + Theme.scaledSpacing(20)
        radius: Theme.scaledRadius(8)
        color: Theme.background
        border.color: Theme.border
        border.width: 1
        clip: true

        ColumnLayout {
            id: wallpaperPanelColumn

            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(10)
            spacing: Theme.scaledSpacing(8)

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(6)

                Repeater {
                    model: ["All", "Built in", "Imported"]

                    BloxButton {
                        required property string modelData

                        text: modelData
                        compact: true
                        checked: controller.wallpaperFilter === modelData
                        onClicked: controller.wallpaperFilter = modelData
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                BloxButton {
                    iconName: "plus"
                    text: "Import file"
                    compact: true
                    enabled: controller.themeControlsEnabled && !controller.busy
                    onClicked: controller.openWallpaperDialog("library")
                }
            }

            ListView {
                id: wallpaperList

                readonly property int cardHeight: 154
                readonly property int scrollbarHeight: 7

                Layout.fillWidth: true
                Layout.preferredHeight: cardHeight + scrollbarHeight + Theme.scaledSpacing(6)
                orientation: ListView.Horizontal
                spacing: Theme.scaledSpacing(9)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: controller.filteredWallpapers()

                BloxWheelHandler {
                    flickable: wallpaperList
                    horizontal: true
                    canHandleWheel: () => controller.claimEditorWheel(wallpaperList)
                }

                ScrollBar.horizontal: ScrollBar {
                    id: wallpaperScrollbar

                    policy: wallpaperList.contentWidth > wallpaperList.width ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    height: wallpaperList.scrollbarHeight

                    background: Rectangle {
                        radius: Theme.scaledRadius(3)
                        color: Theme.withAlpha(Theme.foreground, 0.04)
                    }

                    contentItem: Rectangle {
                        implicitHeight: 5
                        radius: Theme.scaledRadius(3)
                        color: wallpaperScrollbar.hovered || wallpaperScrollbar.pressed ? Theme.foreground : Theme.muted
                    }
                }

                delegate: Rectangle {
                    id: wallpaperCard

                    required property var modelData

                    width: 172
                    height: wallpaperList.cardHeight
                    radius: Theme.scaledRadius(9)
                    color: Theme.surface
                    border.color: controller.wallpaperItemSelected(modelData) ? Theme.accent : cardHover.hovered ? Theme.foreground : modelData.missing ? Theme.red : Theme.border
                    border.width: controller.wallpaperItemSelected(modelData) ? 2 : 1
                    enabled: controller.themeControlsEnabled && !controller.busy && !modelData.missing
                    clip: true

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(5)
                        spacing: Theme.scaledSpacing(5)

                        Rectangle {
                            id: wallpaperPreview

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: Theme.scaledRadius(6)
                            color: modelData.missing || wallpaperImage.status === Image.Error ? Theme.withAlpha(Theme.red, 0.08) : Theme.surfaceAlt
                            clip: true

                            Image {
                                id: wallpaperImage

                                anchors.fill: parent
                                source: modelData.path ? controller.localFileUrl(modelData.path) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                visible: status !== Image.Error && !modelData.missing
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: Theme.scaledSpacing(3)
                                visible: modelData.missing || wallpaperImage.status === Image.Error

                                PhosphorIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 22
                                    height: 22
                                    iconName: "image-broken"
                                    iconColor: Theme.red
                                }

                                Label {
                                    text: "File missing"
                                    color: Theme.red
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 12
                                    font.bold: true
                                }
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.margins: Theme.scaledSpacing(6)
                                width: selectedLabel.implicitWidth + 12
                                height: selectedLabel.implicitHeight + 6
                                radius: Theme.scaledRadius(5)
                                color: Theme.withAlpha(Theme.background, 0.84)
                                visible: controller.wallpaperItemSelected(modelData)

                                Label {
                                    id: selectedLabel

                                    anchors.centerIn: parent
                                    text: "Selected"
                                    color: Theme.accent
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                            }

                            HoverHandler {
                                id: cardHover

                                cursorShape: wallpaperCard.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            }

                            TapHandler {
                                enabled: wallpaperCard.enabled
                                onTapped: controller.chooseWallpaper(modelData)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.scaledSpacing(4)

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.scaledSpacing(0)

                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.name
                                    color: Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 10
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Label {
                                    text: modelData.kind
                                    color: Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 10
                                }
                            }

                            BloxButton {
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 30
                                compact: true
                                iconName: "trash"
                                destructive: true
                                visible: modelData.removable === true
                                enabled: wallpaperCard.enabled
                                onClicked: controller.requestWallpaperRemoval(modelData)
                            }

                            PhosphorIcon {
                                Layout.preferredWidth: 16
                                Layout.preferredHeight: 16
                                visible: modelData.removable !== true
                                iconName: controller.wallpaperItemSelected(modelData) ? "check-circle" : "file-image"
                                iconColor: controller.wallpaperItemSelected(modelData) ? Theme.accent : Theme.muted
                            }
                        }
                    }
                }

                Label {
                    anchors.centerIn: parent
                    text: "No wallpapers in this view"
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    visible: wallpaperList.count === 0
                }
            }
        }
    }
}
