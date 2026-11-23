import QtQuick
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var controller: windowOwner.themeEditorController
    readonly property var candidate: controller ? controller.candidate : null
    readonly property bool editable: controller && controller.themeControlsEnabled && !controller.busy

    searchTargetMap: [
        {section: "cursor", label: "Windows & cursor", objectName: "cursor-follow-roundness"},
        {section: "cursor", label: "Follow theme roundness", objectName: "cursor-follow-roundness"},
        {section: "cursor", label: "Cursor shape", objectName: "cursor-shape"},
        {section: "cursor", label: "Cursor size", objectName: "cursor-size"},
        {section: "cursor", label: "Pointer direction", objectName: "cursor-direction"},
        {section: "window", label: "Window appearance", objectName: "window-controls"},
        {section: "window", label: "Inactive opacity", objectName: "window-inactive-opacity"},
        {section: "window", label: "Border size", objectName: "window-border-size"},
        {section: "window-preview", label: "Preview", objectName: "window-preview"}
    ]

    sectionMap: [
        {id: "cursor", item: cursorSection},
        {id: "window", item: windowSection},
        {id: "window-preview", item: previewSection}
    ]

    ColumnLayout {
        id: cursorSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Cursor"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        Loader {
            Layout.fillWidth: true
            sourceComponent: root.width < 900 ? narrowCursorChoices : wideCursorChoices
        }

        Text {
            Layout.fillWidth: true
            visible: root.editable && root.candidate && root.controller && !root.controller.cursorGenerated()
            text: "These controls apply to generated cursor themes only."
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Component {
            id: wideCursorChoices
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(12)
                BloxCheckBox {
                    Layout.fillWidth: true
                    objectName: "cursor-follow-roundness"
                    text: "Follow theme roundness"
                    enabled: root.editable && root.controller.cursorGenerated()
                    checked: root.controller && root.controller.cursorFollowsThemeRoundness()
                    onToggled: value => root.controller.setCursorFollowsThemeRoundness(value)
                }
                BloxComboBox {
                    Layout.preferredWidth: 230
                    enabled: root.editable && root.controller.cursorGenerated() && !root.controller.cursorFollowsThemeRoundness()
                    objectName: "cursor-shape"
                    model: ["Classic (square)", "Modern (rounded)"]
                    currentIndex: root.controller ? Math.max(0, root.controller.cursorShapeIndex()) : 0
                    onActivated: index => root.controller.setCursorShape(index)
                }
            }
        }

        Component {
            id: narrowCursorChoices
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(6)
                BloxCheckBox {
                    Layout.fillWidth: true
                    objectName: "cursor-follow-roundness"
                    text: "Follow theme roundness"
                    enabled: root.editable && root.controller.cursorGenerated()
                    checked: root.controller && root.controller.cursorFollowsThemeRoundness()
                    onToggled: value => root.controller.setCursorFollowsThemeRoundness(value)
                }
                BloxComboBox {
                    Layout.fillWidth: true
                    enabled: root.editable && root.controller.cursorGenerated() && !root.controller.cursorFollowsThemeRoundness()
                    objectName: "cursor-shape"
                    model: ["Classic (square)", "Modern (rounded)"]
                    currentIndex: root.controller ? Math.max(0, root.controller.cursorShapeIndex()) : 0
                    onActivated: index => root.controller.setCursorShape(index)
                }
            }
        }
        BloxSlider {
            Layout.fillWidth: true
            objectName: "cursor-size"
            label: "Cursor size"
            from: 16
            to: 48
            decimals: 0
            value: root.controller ? root.controller.cursorSize() : 26
            enabled: root.editable && root.candidate !== null
            onMoved: value => root.controller.setCursorSize(Math.round(value))
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)
            Text { text: "Pointer direction"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxComboBox {
                Layout.preferredWidth: 220
                enabled: root.editable && root.controller.cursorGenerated()
                objectName: "cursor-direction"
                model: ["Points right", "Points left"]
                currentIndex: root.controller ? Math.max(0, root.controller.cursorDirectionIndex()) : 0
                onActivated: index => root.controller.setCursorDirection(index)
            }
            Item { Layout.fillWidth: true }
        }
    }

    ColumnLayout {
        id: windowSection
        objectName: "window-controls"
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Window appearance"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        BloxSlider {
            Layout.fillWidth: true
            enabled: root.editable
            objectName: "window-inactive-opacity"
            label: "Inactive opacity"
            from: 0.1
            to: 1
            decimals: 2
            value: root.controller ? root.controller.hyprlandValue("inactive_opacity", 1) : 1
            onMoved: value => root.controller.setHyprlandInactiveOpacity(value)
        }
        BloxSlider {
            Layout.fillWidth: true
            enabled: root.editable
            objectName: "window-border-size"
            label: "Border size"
            from: 0
            to: 8
            decimals: 0
            value: root.controller ? root.controller.hyprlandValue("border_size", 1) : 1
            onMoved: value => root.controller.setHyprlandBorderSize(value)
        }
    }

    ColumnLayout {
        id: previewSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Preview"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        Rectangle {
            Layout.fillWidth: true
            objectName: "window-preview"
            Layout.preferredHeight: 230
            radius: Theme.scaledRadius(10)
            color: Theme.withAlpha(Theme.foreground, 0.03)
            border.color: Theme.border
            clip: true
            SettingsShapePreview {
                id: previewWindow
                width: Math.min(560, parent.width - 32)
                height: width * 96 / 260
                anchors.centerIn: parent
                radiusScale: root.candidate && root.candidate.shape ? root.candidate.shape.radius_scale : 1.25
                densityScale: root.candidate && root.candidate.shape ? root.candidate.shape.density_scale : 1
                windowGap: root.candidate && root.candidate.shape && root.candidate.shape.window_gap !== null
                    ? root.candidate.shape.window_gap : 5
                inactiveOpacity: root.controller ? root.controller.hyprlandValue("inactive_opacity", 1) : 1
                borderSize: root.controller ? root.controller.hyprlandValue("border_size", 1) : 1
            }
            SettingsCursorPreview {
                id: cursorImage
                candidate: root.candidate
                x: previewWindow.x + Math.round(previewWindow.width * 0.58 - hotspotX)
                y: previewWindow.y + Math.round(previewWindow.height * 0.48 - hotspotY)
                z: 2
            }

        }
    }
}
