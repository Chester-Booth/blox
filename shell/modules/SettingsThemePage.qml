import Blox.Services 1.0
import QtQuick
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var controller: windowOwner.themeEditorController
    readonly property var candidate: controller ? controller.candidate : null
    readonly property bool editable: controller && controller.themeControlsEnabled && !controller.busy

    sectionMap: [
        {id: "theme-name", item: themeNameSection},
        {id: "style", item: styleSection},
        {id: "density", item: densitySection},
        {id: "wallpaper", item: wallpaperSection}
    ]

    searchTargetMap: [
        {section: "theme-name", label: "Theme", objectName: "theme-name-field"},
        {section: "theme-name", label: "Theme name", objectName: "theme-name-field"},
        {section: "style", label: "Theme roundness", objectName: "style-round"},
        {section: "style", label: "Slightly round corners", objectName: "style-slightly-round"},
        {section: "style", label: "Square corners", objectName: "style-square"},
        {section: "density", label: "Density", objectName: "density-compact"},
        {section: "density", label: "Comfortable density", objectName: "density-comfortable"},
        {section: "density", label: "Spacious density", objectName: "density-spacious"},
        {section: "wallpaper", label: "Wallpaper fit", objectName: "wallpaper-fit"},
        {section: "wallpaper", label: "Import wallpaper", objectName: "wallpaper-import"},
        {section: "wallpaper", label: "Wallpaper library", objectName: "wallpaper-filters"}
    ]

    ColumnLayout {
        id: themeNameSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Text { text: "Theme name"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(9)
            BloxTextField {
                objectName: "theme-name-field"
                Layout.fillWidth: true
                enabled: root.editable
                text: root.candidate ? root.candidate.name : ""
                onEditingFinished: {
                    if (root.candidate && text.trim().length > 0 && text.trim() !== root.candidate.name)
                        root.controller.setTopLevel("name", text.trim());
                }
            }
            Text {
                text: root.controller ? root.controller.selectedId : ""
                color: Theme.muted
                font.family: Theme.monoFontFamily
                font.pixelSize: 11
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    ColumnLayout {
        id: styleSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        Text { text: "Style"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }

        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: Theme.scaledSpacing(9)
            rowSpacing: Theme.scaledSpacing(9)
            Repeater {
                model: [
                    {label: "Round", detail: "Balanced corners", value: 1.25},
                    {label: "Slightly round", detail: "Small corners", value: 0.65},
                    {label: "Square", detail: "Crisp corners", value: 0}
                ]
                SettingsOptionCard {
                    required property var modelData
                    objectName: modelData.value === 1.25 ? "style-round"
                        : modelData.value === 0.65 ? "style-slightly-round" : "style-square"
                    Layout.fillWidth: true
                    label: modelData.label
                    detail: modelData.detail
                    previewRadius: modelData.value
                    previewDensity: root.candidate && root.candidate.shape ? root.candidate.shape.density_scale : 1
                    previewGap: root.candidate && root.candidate.shape && root.candidate.shape.window_gap !== null
                        ? root.candidate.shape.window_gap : 5
                    selected: root.candidate && root.candidate.shape
                        && Math.abs(root.candidate.shape.radius_scale - modelData.value) < 0.01
                    onClicked: if (root.editable) root.controller.setShapeValue("radius_scale", modelData.value)
                }
            }
        }
    }

    ColumnLayout {
        id: densitySection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        Text { text: "Density"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }

        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: Theme.scaledSpacing(9)
            rowSpacing: Theme.scaledSpacing(9)
            Repeater {
                model: [
                    {label: "Compact", detail: "Tighter spacing", value: 0.75},
                    {label: "Comfortable", detail: "Balanced spacing", value: 1.0},
                    {label: "Spacious", detail: "More room", value: 1.5}
                ]
                SettingsOptionCard {
                    required property var modelData
                    objectName: modelData.value === 0.75 ? "density-compact"
                        : modelData.value === 1.0 ? "density-comfortable" : "density-spacious"
                    Layout.fillWidth: true
                    label: modelData.label
                    detail: modelData.detail
                    previewRadius: root.candidate && root.candidate.shape ? root.candidate.shape.radius_scale : 1.25
                    previewDensity: modelData.value
                    previewGap: root.candidate && root.candidate.shape && root.candidate.shape.window_gap !== null
                        ? root.candidate.shape.window_gap : 5
                    selected: root.candidate && root.candidate.shape
                        && Math.abs(root.candidate.shape.density_scale - modelData.value) < 0.01
                    onClicked: if (root.editable) root.controller.setShapeValue("density_scale", modelData.value)
                }
            }
        }

        SettingsSubpageButton {
            Layout.fillWidth: true
            text: "Advanced style and density"
            detail: "Exact roundness, density and window gap controls"
            iconName: "wrench"
            onClicked: root.windowOwner.openSettingsSection("theme", "shape-density")
        }
    }

    ColumnLayout {
        id: wallpaperSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        Text { text: "Wallpaper"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(10)
            Text { text: "Fit"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxComboBox {
                objectName: "wallpaper-fit"
                Layout.preferredWidth: 132
                enabled: root.editable && root.candidate && root.candidate.wallpaper
                model: ["cover", "contain", "tile"]
                currentIndex: root.candidate && root.candidate.wallpaper ? Math.max(0, model.indexOf(root.candidate.wallpaper.fit)) : 0
                onActivated: (index, value) => {
                    if (!root.candidate || !root.editable)
                        return;
                    const next = root.controller.cloneCandidate();
                    next.wallpaper.fit = value;
                    root.controller.markCandidate(next, "wallpaper.fit");
                }
            }
            Item { Layout.fillWidth: true }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: wallpaperPanel.implicitHeight + Theme.scaledSpacing(20)
            color: Theme.background
            border.color: Theme.border
            radius: Theme.scaledRadius(8)
            clip: true

            ColumnLayout {
                id: wallpaperPanel
                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(10)
                spacing: Theme.scaledSpacing(8)

                RowLayout {
                    objectName: "wallpaper-filters"
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(6)
                    Repeater {
                        model: ["All", "Built in", "Imported"]
                        BloxButton {
                            required property string modelData
                            objectName: "wallpaper-filter-" + modelData.toLowerCase().replace(/[^a-z0-9]+/g, "-")
                            text: modelData
                            compact: true
                            checked: root.controller && root.controller.wallpaperFilter === modelData
                            onClicked: if (root.controller) root.controller.wallpaperFilter = modelData
                        }
                    }
                    Item { Layout.fillWidth: true }
                    BloxButton {
                        objectName: "wallpaper-import"
                        text: "Import file"
                        iconName: "plus"
                        compact: true
                        enabled: root.editable
                        onClicked: root.controller.openWallpaperDialog("library")
                    }
                }

                ListView {
                    id: wallpaperList
                    readonly property int cardHeight: 154
                    Layout.fillWidth: true
                    Layout.preferredHeight: cardHeight + Theme.scaledSpacing(13)
                    orientation: ListView.Horizontal
                    spacing: Theme.scaledSpacing(9)
                    clip: true
                    model: root.controller ? root.controller.filteredWallpapers() : []
                    boundsBehavior: Flickable.StopAtBounds
                    BloxWheelHandler {
                        flickable: wallpaperList
                        horizontal: true
                        canHandleWheel: () => root.controller ? root.controller.claimEditorWheel(wallpaperList) : true
                    }
                    ScrollBar.horizontal: BloxScrollBar {
                        policy: wallpaperList.contentWidth > wallpaperList.width ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                        height: 7
                    }

                    delegate: Rectangle {
                        required property var modelData
                        width: 172
                        height: wallpaperList.cardHeight
                        activeFocusOnTab: root.editable && !modelData.missing
                        Keys.onReturnPressed: root.controller.chooseWallpaper(modelData)
                        Keys.onSpacePressed: root.controller.chooseWallpaper(modelData)
                        radius: Theme.scaledRadius(9)
                        color: Theme.surface
                        border.color: root.controller && root.controller.wallpaperItemSelected(modelData)
                            ? Theme.accent : cardHover.hovered ? Theme.foreground : Theme.border
                        border.width: root.controller && root.controller.wallpaperItemSelected(modelData) ? 2 : 1
                        enabled: root.editable && !modelData.missing
                        opacity: enabled ? 1 : 0.56
                        clip: true

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.scaledSpacing(5)
                            spacing: Theme.scaledSpacing(5)
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: Theme.scaledRadius(6)
                                color: modelData.missing ? Theme.withAlpha(Theme.red, 0.08) : Theme.surfaceAlt
                                clip: true
                                ImageCacheResolver {
                                    id: imageCache
                                    source: root.controller ? root.controller.localFileUrl(modelData.reference || modelData.path) : ""
                                    sourceId: modelData.id || ""
                                    pixelWidth: Math.max(1, Math.ceil(wallpaperImage.width * Screen.devicePixelRatio))
                                    pixelHeight: Math.max(1, Math.ceil(wallpaperImage.height * Screen.devicePixelRatio))
                                    fit: "cover"
                                    active: wallpaperImage.visible && wallpaperImage.width > 0 && wallpaperImage.height > 0
                                }
                                Image {
                                    id: wallpaperImage
                                    anchors.fill: parent
                                    source: imageCache.status === "ready" ? imageCache.readySource : ""
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize: Qt.size(Math.max(1, Math.ceil(width * Screen.devicePixelRatio)),
                                        Math.max(1, Math.ceil(height * Screen.devicePixelRatio)))
                                    asynchronous: true
                                    layer.enabled: true
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: wallpaperImageMask
                                    }
                                }
                                Rectangle {
                                    id: wallpaperImageMask
                                    anchors.fill: wallpaperImage
                                    radius: parent.radius
                                    color: "white"
                                    visible: false
                                    layer.enabled: true
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.name
                                color: Theme.foreground
                                font.family: Theme.bodyFontFamily
                                font.pixelSize: 11
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.kind + (modelData.missing ? " · unavailable" : "")
                                color: modelData.missing ? Theme.red : Theme.muted
                                font.family: Theme.bodyFontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }
                        HoverHandler { id: cardHover; cursorShape: root.editable ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        TapHandler { enabled: root.editable && !modelData.missing; onTapped: root.controller.chooseWallpaper(modelData) }
                    }
                }
            }
        }
    }
}
