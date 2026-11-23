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
        {section: "shape-density", label: "Roundness scale", objectName: "theme-roundness-scale"},
        {section: "shape-density", label: "Density scale", objectName: "theme-density-scale"},
        {section: "shape-density", label: "Window gap", objectName: "theme-window-gap"}
    ]
    sectionMap: [{id: "shape-density", item: shapeSection}]

    ColumnLayout {
        id: shapeSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(12)

        Text { text: "Shape & density"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 17; font.bold: true }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 230
            radius: Theme.scaledRadius(10)
            color: Theme.withAlpha(Theme.foreground, 0.03)
            border.color: Theme.border
            clip: true
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
            enabled: root.editable && root.candidate
            objectName: "theme-roundness-scale"
            label: "Roundness"
            from: 0
            to: 2
            value: root.candidate && root.candidate.shape ? root.candidate.shape.radius_scale : 1.25
            onMoved: value => root.controller.setShapeValue("radius_scale", value)
        }

        BloxSlider {
            Layout.fillWidth: true
            enabled: root.editable && root.candidate
            objectName: "theme-density-scale"
            label: "Density"
            from: 0.75
            to: 1.5
            value: root.candidate && root.candidate.shape ? root.candidate.shape.density_scale : 1
            onMoved: value => root.controller.setShapeValue("density_scale", value)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(12)
            BloxCheckBox {
                Layout.alignment: Qt.AlignBottom
                text: "Automatic"
                enabled: root.editable && root.candidate
                checked: !root.candidate || !root.candidate.shape || root.candidate.shape.window_gap === undefined
                    || root.candidate.shape.window_gap === null
                onToggled: value => root.controller.setAutomaticWindowGap(value)
            }
            BloxSlider {
                Layout.fillWidth: true
                enabled: root.editable && root.candidate && root.candidate.shape
                    && root.candidate.shape.window_gap !== undefined && root.candidate.shape.window_gap !== null
                objectName: "theme-window-gap"
                label: "Window gap"
                from: 0
                to: 30
                decimals: 0
                value: root.controller ? root.controller.effectiveWindowGap() : 5
                onMoved: value => root.controller.setShapeValue("window_gap", Math.round(value))
            }
        }
    }
}
