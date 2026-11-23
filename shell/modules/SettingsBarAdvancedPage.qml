import QtQuick
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var settings: windowOwner.settingsController.settings || ({})
    readonly property var barStyle: settings.bar ? settings.bar.style || ({}) : ({})
    readonly property var controller: windowOwner.themeEditorController
    readonly property var candidate: controller ? controller.candidate : null
    readonly property bool themeEditable: controller && controller.themeControlsEnabled && !controller.busy

    searchTargetMap: [
        {section: "position-offsets", label: "Bar inset", objectName: "bar-inset"},
        {section: "position-offsets", label: "OSD horizontal offset", objectName: "osd-offset-x"},
        {section: "position-offsets", label: "OSD vertical offset", objectName: "osd-offset-y"},
        {section: "position-offsets", label: "Notification horizontal offset", objectName: "notification-offset-x"},
        {section: "position-offsets", label: "Notification vertical offset", objectName: "notification-offset-y"},
        {section: "window-shape-density", label: "Window roundness", objectName: "window-roundness"},
        {section: "window-shape-density", label: "Window density", objectName: "window-density"},
        {section: "window-shape-density", label: "Automatic window gap", objectName: "window-gap-automatic"},
        {section: "window-shape-density", label: "Window gap", objectName: "window-gap"}
    ]

    sectionMap: [
        {id: "position-offsets", item: offsetsSection},
        {id: "window-shape-density", item: shapeSection}
    ]

    function saveOffset(path, text) {
        const parsed = Number.parseInt(text, 10);
        windowOwner.writeSettingsValue(path, Number.isNaN(parsed) ? 0 : parsed);
    }

    ColumnLayout {
        id: offsetsSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        Text {
            text: "Position offsets"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 5
            columnSpacing: Theme.scaledSpacing(12)
            rowSpacing: Theme.scaledSpacing(8)

            Text { text: "Bar inset"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxSlider {
                objectName: "bar-inset"
                Layout.columnSpan: 4
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                showLabel: false
                valueSuffix: "px"
                from: 0
                to: 24
                decimals: 0
                value: root.windowOwner.settingsValue("bar.style.edgeInset", root.barStyle.edgeInset || 0)
                onMoved: value => root.windowOwner.writeSettingsValue("bar.style.edgeInset", Math.round(value))
            }

            Text { text: "OSD"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            Text { text: "X offset"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxTextField {
                objectName: "osd-offset-x"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                text: String(root.windowOwner.settingsValue("osd.offsetX", root.settings.osd ? root.settings.osd.offsetX || 0 : 0))
                suffix: "px"
                onEditingFinished: root.saveOffset("osd.offsetX", text)
            }
            Text { text: "Y offset"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxTextField {
                objectName: "osd-offset-y"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                text: String(root.windowOwner.settingsValue("osd.offsetY", root.settings.osd ? root.settings.osd.offsetY || 0 : 0))
                suffix: "px"
                onEditingFinished: root.saveOffset("osd.offsetY", text)
            }

            Text { text: "Notifications"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            Text { text: "X offset"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxTextField {
                objectName: "notification-offset-x"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                text: String(root.windowOwner.settingsValue("notifications.offsetX",
                    root.settings.notifications ? root.settings.notifications.offsetX || 0 : 0))
                suffix: "px"
                onEditingFinished: root.saveOffset("notifications.offsetX", text)
            }
            Text { text: "Y offset"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxTextField {
                objectName: "notification-offset-y"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                text: String(root.windowOwner.settingsValue("notifications.offsetY",
                    root.settings.notifications ? root.settings.notifications.offsetY || 0 : 0))
                suffix: "px"
                onEditingFinished: root.saveOffset("notifications.offsetY", text)
            }
        }
    }

    ColumnLayout {
        id: shapeSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(10)

        Text {
            text: "Window shape & density"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 230
            radius: Theme.scaledRadius(10)
            clip: true
            color: Theme.withAlpha(Theme.foreground, 0.03)
            border.color: Theme.border
            SettingsShapePreview {
                width: Math.min(560, parent.width - 32)
                height: width * 96 / 260
                anchors.centerIn: parent
                radiusScale: root.candidate && root.candidate.shape ? root.candidate.shape.radius_scale : 1.25
                densityScale: root.candidate && root.candidate.shape ? root.candidate.shape.density_scale : 1
                windowGap: root.controller ? root.controller.effectiveWindowGap() : 5
            }
        }

        BloxSlider {
            Layout.fillWidth: true
            enabled: root.themeEditable && root.candidate !== null
            objectName: "window-roundness"
            label: "Window roundness"
            from: 0
            to: 2
            value: root.candidate && root.candidate.shape ? root.candidate.shape.radius_scale : 1.25
            onMoved: value => root.controller.setShapeValue("radius_scale", value)
        }

        BloxSlider {
            Layout.fillWidth: true
            enabled: root.themeEditable && root.candidate !== null
            objectName: "window-density"
            label: "Window density"
            from: 0.75
            to: 1.5
            value: root.candidate && root.candidate.shape ? root.candidate.shape.density_scale : 1
            onMoved: value => root.controller.setShapeValue("density_scale", value)
        }

        BloxCheckBox {
            objectName: "window-gap-automatic"
            text: "Automatic window gap"
            enabled: root.themeEditable && root.candidate !== null
            checked: !root.candidate || !root.candidate.shape || root.candidate.shape.window_gap === undefined
                || root.candidate.shape.window_gap === null
            onToggled: value => root.controller.setAutomaticWindowGap(value)
        }

        BloxSlider {
            Layout.fillWidth: true
            enabled: root.themeEditable && root.candidate && root.candidate.shape
                && root.candidate.shape.window_gap !== undefined && root.candidate.shape.window_gap !== null
            objectName: "window-gap"
            label: "Window gap"
            from: 0
            to: 30
            decimals: 0
            value: root.controller ? root.controller.effectiveWindowGap() : 5
            onMoved: value => root.controller.setShapeValue("window_gap", Math.round(value))
        }
    }
}
