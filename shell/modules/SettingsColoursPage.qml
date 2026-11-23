import QtQuick
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var controller: windowOwner.themeEditorController
    readonly property var candidate: controller ? controller.candidate : null
    readonly property bool editable: controller && controller.themeControlsEnabled && !controller.busy

    sectionMap: [
        {id: "semantic", item: semanticSection},
        {id: "terminal", item: terminalSection},
        {id: "fonts", item: fontsSection},
        {id: "font-samples", item: samplesSection},
        {id: "icons", item: iconSection}
    ]

    searchTargetMap: [
        {section: "semantic", label: "Colours & type", objectName: "semantic-color-background"},
        {section: "semantic", label: "Semantic palette", objectName: "semantic-color-background"},
        {section: "semantic", label: "Background colour", objectName: "semantic-color-background"},
        {section: "semantic", label: "Surface colour", objectName: "semantic-color-surface"},
        {section: "semantic", label: "Alternate surface colour", objectName: "semantic-color-surface-alt"},
        {section: "semantic", label: "Foreground colour", objectName: "semantic-color-foreground"},
        {section: "semantic", label: "Muted colour", objectName: "semantic-color-muted"},
        {section: "semantic", label: "Accent colour", objectName: "semantic-color-accent"},
        {section: "semantic", label: "Danger colour", objectName: "semantic-color-danger"},
        {section: "semantic", label: "Success colour", objectName: "semantic-color-success"},
        {section: "semantic", label: "Warning colour", objectName: "semantic-color-warning"},
        {section: "semantic", label: "Info colour", objectName: "semantic-color-info"},
        {section: "semantic", label: "Mauve colour", objectName: "semantic-color-mauve"},
        {section: "semantic", label: "Teal colour", objectName: "semantic-color-teal"},
        {section: "semantic", label: "Selection background colour", objectName: "semantic-color-selection-background"},
        {section: "semantic", label: "Selection foreground colour", objectName: "semantic-color-selection-foreground"},
        {section: "semantic", label: "Border colour", objectName: "semantic-color-border"},
        {section: "terminal", label: "Terminal palette", objectName: "terminal-color-0"},
        {section: "terminal", label: "Terminal colour 0", objectName: "terminal-color-0"},
        {section: "terminal", label: "Terminal colour 1", objectName: "terminal-color-1"},
        {section: "terminal", label: "Terminal colour 2", objectName: "terminal-color-2"},
        {section: "terminal", label: "Terminal colour 3", objectName: "terminal-color-3"},
        {section: "terminal", label: "Terminal colour 4", objectName: "terminal-color-4"},
        {section: "terminal", label: "Terminal colour 5", objectName: "terminal-color-5"},
        {section: "terminal", label: "Terminal colour 6", objectName: "terminal-color-6"},
        {section: "terminal", label: "Terminal colour 7", objectName: "terminal-color-7"},
        {section: "terminal", label: "Terminal colour 8", objectName: "terminal-color-8"},
        {section: "terminal", label: "Terminal colour 9", objectName: "terminal-color-9"},
        {section: "terminal", label: "Terminal colour 10", objectName: "terminal-color-10"},
        {section: "terminal", label: "Terminal colour 11", objectName: "terminal-color-11"},
        {section: "terminal", label: "Terminal colour 12", objectName: "terminal-color-12"},
        {section: "terminal", label: "Terminal colour 13", objectName: "terminal-color-13"},
        {section: "terminal", label: "Terminal colour 14", objectName: "terminal-color-14"},
        {section: "terminal", label: "Terminal colour 15", objectName: "terminal-color-15"},
        {section: "fonts", label: "Fonts", objectName: "font-ui"},
        {section: "fonts", label: "UI font", objectName: "font-ui"},
        {section: "fonts", label: "Mono font", objectName: "font-mono"},
        {section: "fonts", label: "Panel font", objectName: "font-panel"},
        {section: "font-samples", label: "Font samples", objectName: "font-samples-box"},
        {section: "icons", label: "Icon theme", objectName: "icon-theme-selector"}
    ]

    function terminalColour(key) {
        if (candidate && candidate.overrides && candidate.overrides.ansi && candidate.overrides.ansi[key])
            return candidate.overrides.ansi[key];
        return controller && controller.previewData && controller.previewData.ansi
            ? controller.previewData.ansi[key] || Theme.background : Theme.background;
    }

    ColumnLayout {
        id: semanticSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Semantic colours"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: Theme.scaledSpacing(10)
            rowSpacing: Theme.scaledSpacing(8)
            Repeater {
                model: root.controller ? root.controller.semanticKeys : []
                delegate: ColumnLayout {
                    required property string modelData
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(3)
                    Text {
                        text: modelData.replace(/_/g, " ")
                        color: Theme.muted
                        font.family: Theme.monoFontFamily
                        font.pixelSize: 10
                    }
                    SettingsColourSwatch {
                        objectName: "semantic-color-" + modelData.replace(/_/g, "-")
                        Layout.fillWidth: true
                        enabled: root.editable
                        windowOwner: root.windowOwner
                        key: modelData
                        value: root.candidate && root.candidate.colours ? root.candidate.colours[modelData] : Theme.background
                        onPicked: value => root.controller.setColour(modelData, value)
                    }
                }
            }
        }
    }

    ColumnLayout {
        id: terminalSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Terminal colours"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: Theme.scaledSpacing(10)
            rowSpacing: Theme.scaledSpacing(8)
            Repeater {
                model: root.controller ? root.controller.ansiKeys : []
                delegate: ColumnLayout {
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(3)
                    Text { text: "color" + index; color: Theme.muted; font.family: Theme.monoFontFamily; font.pixelSize: 10 }
                    SettingsColourSwatch {
                        objectName: "terminal-color-" + index
                        Layout.fillWidth: true
                        enabled: root.editable
                        windowOwner: root.windowOwner
                        key: modelData
                        target: "ansi"
                        value: root.terminalColour(modelData)
                        onPicked: value => root.controller.setOverride("ansi", modelData, value)
                    }
                }
            }
        }
    }

    ColumnLayout {
        id: fontsSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Fonts"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: Theme.scaledSpacing(10)
            ColumnLayout {
                Layout.fillWidth: true
                Text { text: "ui"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 11 }
                BloxFontPicker {
                    objectName: "font-ui"
                    Layout.fillWidth: true
                    enabled: root.editable
                    families: root.controller ? root.controller.fontFamilies : []
                    value: root.candidate && root.candidate.fonts ? root.candidate.fonts.ui : ""
                    onAccepted: family => root.controller.setFont("ui", family)
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Text { text: "mono"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 11 }
                BloxFontPicker {
                    objectName: "font-mono"
                    Layout.fillWidth: true
                    enabled: root.editable
                    families: root.controller ? root.controller.fontFamilies : []
                    value: root.candidate && root.candidate.fonts ? root.candidate.fonts.mono : ""
                    onAccepted: family => root.controller.setFont("mono", family)
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Text { text: "panel · proportional fonts recommended"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 11; elide: Text.ElideRight }
                BloxFontPicker {
                    objectName: "font-panel"
                    Layout.fillWidth: true
                    enabled: root.editable
                    families: root.controller ? root.controller.fontFamilies : []
                    value: root.candidate && root.candidate.fonts ? root.candidate.fonts.panel : ""
                    onAccepted: family => root.controller.setFont("panel", family)
                }
            }
        }
    }

    ColumnLayout {
        id: samplesSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Font samples"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        Rectangle {
            objectName: "font-samples-box"
            Layout.fillWidth: true
            Layout.preferredHeight: 116
            color: Theme.background
            border.color: Theme.border
            radius: Theme.scaledRadius(7)
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(12)
                spacing: Theme.scaledSpacing(7)
                Text {
                    text: "Interface — Notifications and theme picker 0123456789"
                    color: Theme.foreground
                    font.family: root.candidate && root.candidate.fonts ? root.candidate.fonts.ui : Theme.bodyFontFamily
                    font.pixelSize: 16
                }
                Text {
                    text: "const accent = \"#89b4fa\";  {} [] () => ⚡󰍹"
                    color: Theme.foreground
                    font.family: root.candidate && root.candidate.fonts ? root.candidate.fonts.mono : Theme.monoFontFamily
                    font.pixelSize: 14
                }
                Text {
                    text: "Panel 󰕾 󰂄 󰤨 󰔛 󰖩"
                    color: Theme.foreground
                    font.family: root.candidate && root.candidate.fonts ? root.candidate.fonts.panel : Theme.fontFamily
                    font.pixelSize: 14
                }
            }
        }
    }

    ColumnLayout {
        id: iconSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(8)
        Text { text: "Icon theme"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(10)
            Text { text: "Theme"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxComboBox {
                objectName: "icon-theme-selector"
                Layout.preferredWidth: 220
                enabled: root.editable
                model: root.controller ? root.controller.iconThemeNames : []
                currentIndex: root.controller ? Math.max(0, root.controller.iconThemeOptions.findIndex(entry => entry.id === (root.candidate && root.candidate.icons ? root.candidate.icons.theme : ""))) : 0
                onActivated: index => {
                    const option = root.controller.iconThemeOptions[index];
                    if (option)
                        root.controller.setIconTheme(option.id);
                }
            }
            Item { Layout.fillWidth: true }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(18)
            Repeater {
                model: root.controller ? root.controller.iconSampleKeys : []
                delegate: ColumnLayout {
                    required property string modelData
                    spacing: Theme.scaledSpacing(3)
                    PhosphorIcon {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        iconName: modelData
                        iconColor: Theme.foreground
                    }
                    Text {
                        text: modelData
                        color: Theme.muted
                        font.family: Theme.monoFontFamily
                        font.pixelSize: 9
                    }
                }
            }
        }
    }
}
