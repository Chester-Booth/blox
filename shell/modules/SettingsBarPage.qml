import QtQuick
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var settings: windowOwner.settingsController.settings || ({})
    readonly property var bar: settings.bar || ({})
    readonly property var layout: bar.layout || ({})
    readonly property var style: bar.style || ({})

    searchTargetMap: [
        {section: "bar-settings", label: "Bar settings", objectName: "bar-position"},
        {section: "osd", label: "OSD and notifications", objectName: "osd-position"},
        {section: "bar-settings", label: "Bar", objectName: "bar-position"},
        {section: "bar-settings", label: "Bar settings", objectName: "bar-position"},
        {section: "bar-settings", label: "Bar position", objectName: "bar-position"},
        {section: "bar-settings", label: "Separate bar groups", objectName: "bar-separate-groups"},
        {section: "bar-settings", label: "Bar border", objectName: "bar-border"},
        {section: "bar-settings", label: "Edge inset", objectName: "bar-edge-inset"},
        {section: "osd", label: "OSD position", objectName: "osd-position"},
        {section: "osd", label: "OSD and notifications", objectName: "osd-position"},
        {section: "osd", label: "Notification position", objectName: "notification-position"},
        {section: "bar-spacing", label: "Bar roundness", objectName: "bar-roundness"},
        {section: "bar-spacing", label: "Automatic bar roundness", objectName: "bar-roundness-automatic"},
        {section: "bar-spacing", label: "Bar density", objectName: "bar-density"},
        {section: "bar-spacing", label: "Automatic bar density", objectName: "bar-density-automatic"}
    ]

    sectionMap: [
        {id: "bar-settings", item: barSettingsSection},
        {id: "osd", item: osdSection},
        {id: "bar-spacing", item: spacingSection}
    ]

    ColumnLayout {
        id: barSettingsSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Text {
            text: "Bar settings"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.scaledSpacing(12)
            rowSpacing: Theme.scaledSpacing(8)

            Text { text: "Bar position"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }

            BloxComboBox {
                objectName: "bar-position"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                model: ["left", "right", "top", "bottom"]
                currentIndex: Math.max(0, model.indexOf(root.windowOwner.settingsValue(
                    "bar.layout.position", root.layout.position || "top")))
                onActivated: (index, value) => root.windowOwner.writeSettingsValue("bar.layout.position", value)
            }

            BloxCheckBox {
                Layout.columnSpan: 2
                objectName: "bar-separate-groups"
            text: "Separate bar groups"
                checked: root.windowOwner.settingsValue("bar.layout.separateGroups", root.layout.separateGroups === true)
                enabled: root.windowOwner.settingsController.settings !== null
                onToggled: value => root.windowOwner.writeSettingsValue("bar.layout.separateGroups", value)
            }

            BloxCheckBox {
                Layout.columnSpan: 2
                objectName: "bar-border"
            text: "Bar border"
                checked: root.windowOwner.settingsValue("bar.style.border", root.style.border === true)
                enabled: root.windowOwner.settingsController.settings !== null
                onToggled: value => root.windowOwner.writeSettingsValue("bar.style.border", value)
            }

            BloxSlider {
                Layout.columnSpan: 2
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                objectName: "bar-edge-inset"
            label: "Edge inset"
                from: 0
                to: 24
                decimals: 0
                value: root.windowOwner.settingsValue("bar.style.edgeInset", root.style.edgeInset || 0)
                onMoved: value => root.windowOwner.writeSettingsValue("bar.style.edgeInset", Math.round(value))
            }
        }
    }

    ColumnLayout {
        id: osdSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)

        Text {
            text: "OSD and notifications"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.scaledSpacing(12)
            rowSpacing: Theme.scaledSpacing(8)

            Text { text: "OSD position"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxComboBox {
                objectName: "osd-position"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre-top", "centre-bottom"]
                currentIndex: Math.max(0, model.indexOf(root.windowOwner.settingsValue(
                    "osd.position", root.settings.osd && root.settings.osd.position || "centre-bottom")))
                onActivated: (index, value) => root.windowOwner.writeSettingsValue("osd.position", value)
            }

            Text { text: "Notification position"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxComboBox {
                objectName: "notification-position"
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                model: ["top-left", "top-right", "bottom-left", "bottom-right", "centre-top", "centre-bottom"]
                currentIndex: Math.max(0, model.indexOf(root.windowOwner.settingsValue(
                    "notifications.position", root.settings.notifications && root.settings.notifications.position || "top-right")))
                onActivated: (index, value) => root.windowOwner.writeSettingsValue("notifications.position", value)
            }
        }
    }

    ColumnLayout {
        id: spacingSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        Text {
            text: "Bar spacing"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)
            BloxCheckBox {
                objectName: "bar-roundness-automatic"
                text: "Automatic"
                checked: root.windowOwner.settingsValue("bar.style.radiusAutomatic", root.style.radiusAutomatic !== false)
                onToggled: value => root.windowOwner.writeSettingsValue("bar.style.radiusAutomatic", value)
            }
            BloxSlider {
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                    && !root.windowOwner.settingsValue("bar.style.radiusAutomatic", root.style.radiusAutomatic !== false)
                objectName: "bar-roundness"
                label: "Bar roundness"
                from: 0
                to: 2
                value: root.windowOwner.settingsValue("bar.style.radiusAutomatic", root.style.radiusAutomatic !== false)
                    ? Theme.radiusScale : root.windowOwner.settingsValue("bar.style.radiusScale",
                        root.style.radiusScale === undefined ? 1.25 : root.style.radiusScale)
                onMoved: value => root.windowOwner.writeSettingsValue("bar.style.radiusScale", value)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)
            BloxCheckBox {
                objectName: "bar-density-automatic"
                text: "Automatic"
                checked: root.windowOwner.settingsValue("bar.style.densityAutomatic", root.style.densityAutomatic !== false)
                onToggled: value => root.windowOwner.writeSettingsValue("bar.style.densityAutomatic", value)
            }
            BloxSlider {
                Layout.fillWidth: true
                enabled: root.windowOwner.settingsController.settings !== null
                    && !root.windowOwner.settingsValue("bar.style.densityAutomatic", root.style.densityAutomatic !== false)
                objectName: "bar-density"
                label: "Bar density"
                from: 0.75
                to: 1.5
                value: root.windowOwner.settingsValue("bar.style.densityAutomatic", root.style.densityAutomatic !== false)
                    ? Theme.densityScale : root.windowOwner.settingsValue("bar.style.densityScale",
                        root.style.densityScale === undefined ? 1 : root.style.densityScale)
                onMoved: value => root.windowOwner.writeSettingsValue("bar.style.densityScale", value)
            }
        }

        SettingsSubpageButton {
            Layout.fillWidth: true
            text: "Advanced bar layout"
            detail: "Offsets, window shape and per-bar overrides"
            iconName: "wrench"
            onClicked: root.windowOwner.openSettingsSection("bar", "position-offsets")
        }
    }
}
