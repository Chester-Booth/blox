import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: section

    required property ThemePickerController controller
    property string gtkDetail: "Existing and new GTK windows"
    property string quickshellDetail: "Launcher and notifications"

    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(5)

    Label {
        text: "Icon Theme"
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 17
        font.bold: true
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(12)

        BloxComboBox {
            id: iconThemeChoice

            Layout.fillWidth: true
            Layout.minimumWidth: 205
            model: controller.iconThemeNames
            currentIndex: controller.iconThemeIndex()
            onActivated: (index, value) => controller.setIconTheme(controller.iconThemeIdAt(index))
        }

        ColumnLayout {
            Layout.preferredWidth: 146
            spacing: Theme.scaledSpacing(2)

            Label {
                text: "Sample"
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: 9
            }

            RowLayout {
                spacing: Theme.scaledSpacing(7)

                Repeater {
                    model: controller.iconSampleKeys

                    Image {
                        required property string modelData

                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        source: controller.iconThemeSampleSource(controller.iconThemeValue(), modelData)
                        sourceSize: Qt.size(22, 22)
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        opacity: status === Image.Ready ? 1 : 0
                    }
                }
            }
        }

    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(16)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)

            BloxCheckBox {
                text: "GTK applications"
                enabled: controller.targetAvailable("gtk")
                checked: {
                    controller.candidateRevision;
                    return controller.candidate && controller.candidate.targets ? controller.candidate.targets.gtk === true : false;
                }
                onToggled: (value) => {
                    if (controller.candidate && value !== controller.candidate.targets.gtk)
                        controller.setTarget("gtk", value);
                }
            }

            Text {
                Layout.fillWidth: true
                text: section.gtkDetail
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)

            BloxCheckBox {
                text: "Quickshell"
                enabled: controller.targetAvailable("quickshell")
                checked: {
                    controller.candidateRevision;
                    return controller.candidate && controller.candidate.targets ? controller.candidate.targets.quickshell === true : false;
                }
                onToggled: (value) => {
                    if (controller.candidate && value !== controller.candidate.targets.quickshell)
                        controller.setTarget("quickshell", value);
                }
            }

            Text {
                Layout.fillWidth: true
                text: section.quickshellDetail
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }
    }
}
