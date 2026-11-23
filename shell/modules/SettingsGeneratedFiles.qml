import QtQuick
import QtQuick.Layouts
import qs.shared as Shared

ColumnLayout {
    id: root
    required property var windowOwner
    required property var groups
    required property var composition
    required property var targetLabelFor
    spacing: Shared.Theme.scaledSpacing(9)

    Text {
        text: "Generated files"
        color: Shared.Theme.foreground
        font.family: Shared.Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }
    Text {
        Layout.fillWidth: true
        text: root.composition.generation ? "From " + root.composition.generation.themeId + ". Apply changes to update these files."
            : root.windowOwner.compositionProviderController.status === "error" ? root.windowOwner.compositionProviderController.errorMessage
            : root.windowOwner.compositionProviderController.status === "loading" ? "Reading generated files…" : "No generated files yet."
        color: Shared.Theme.muted
        font.family: Shared.Theme.bodyFontFamily
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }
    Repeater {
        model: root.groups
        delegate: ColumnLayout {
            id: group
            required property var modelData
            Layout.fillWidth: true
            spacing: Shared.Theme.scaledSpacing(6)
            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: root.targetLabelFor(group.modelData.target)
                    color: Shared.Theme.blue
                    font.family: Shared.Theme.monoFontFamily
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideRight
                }
                Shared.BloxButton {
                    visible: group.modelData.files.length > 1
                    objectName: "generated-download-all"
                    text: "Download all (.zip)"
                    iconName: "download-simple"
                    compact: true
                    onClicked: root.windowOwner.downloadGeneratedArchive(group.modelData.target)
                }
            }
            Flow {
                Layout.fillWidth: true
                spacing: Shared.Theme.scaledSpacing(8)
                Repeater {
                    model: group.modelData.files
                    Shared.BloxButton {
                        required property var modelData
                        objectName: "generated-file-" + modelData.relativePath
                        width: Math.min(implicitWidth, parent.width)
                        text: modelData.name || modelData.relativePath.slice(modelData.relativePath.lastIndexOf("/") + 1)
                        iconName: "download-simple"
                        onClicked: root.windowOwner.downloadGeneratedFile(group.modelData.target, modelData.relativePath)
                    }
                }
            }
        }
    }
}
