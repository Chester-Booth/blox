import qs.modules
import qs.shared
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    required property SettingsThemeEditorController controller
    Layout.fillWidth: true
    ColumnLayout {
        visible: controller.modalKind === "guide"
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(6)

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "In your browser, press Ctrl+O and open the generated Stylus file at:"
            color: Theme.foreground
            wrapMode: Text.Wrap
        }

        RowLayout {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)

            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: Theme.themeStateRoot + "/current/stylus/blox-system.user.css"
                color: Theme.muted
                font.family: Theme.monoFontFamily
                elide: Text.ElideMiddle
            }

            CopyPathButton {
                value: Theme.themeStateRoot + "/current/stylus/blox-system.user.css"
            }

        }

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "After changing theme, open or reload this file, then click Install style the first time, or Reinstall style if the style is already installed."
            color: Theme.foreground
            wrapMode: Text.Wrap
        }

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "If Stylus lists more than one Blox Web Theme, disable or remove the older copy first."
            color: Theme.muted
            wrapMode: Text.Wrap
        }

        RowLayout {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)

            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Theme.scaledSpacing(2)

                Text {
                    Layout.fillWidth: true
                    text: "First install"
                    color: Theme.muted
                    wrapMode: Text.Wrap
                }

                Image {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 45
                    Layout.maximumHeight: 45
                    fillMode: Image.PreserveAspectFit
                    source: "../assets/stylus-install-style.png"
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Theme.scaledSpacing(2)

                Text {
                    Layout.fillWidth: true
                    text: "Already installed"
                    color: Theme.muted
                    wrapMode: Text.Wrap
                }

                Image {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 45
                    Layout.maximumHeight: 45
                    fillMode: Image.PreserveAspectFit
                    source: "../assets/stylus-reinstall-style.png"
                }
            }
        }

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "Note: You may need to give Stylus permission to access local files in your extension settings."
            color: Theme.muted
            wrapMode: Text.Wrap
        }

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "Chrome or Chromium: Allow access to file URLs"
            color: Theme.muted
            wrapMode: Text.Wrap
        }

        Image {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            height: 70
            source: "../assets/stylus-file-urls.png"
            fillMode: Image.PreserveAspectFit
        }

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "Firefox or Zen: Access local files on your computer"
            color: Theme.muted
            wrapMode: Text.Wrap
        }

        Image {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            Layout.preferredHeight: 180
            Layout.maximumHeight: 180
            height: 180
            Layout.topMargin: -Theme.scaledSpacing(6)
            source: "../assets/stylus-file-access-firefox.png"
            fillMode: Image.PreserveAspectFit
        }

        Text {
            visible: controller.guideTarget === "obsidian"
            Layout.fillWidth: true
            text: "Obsidian updates live when it is open. When it is closed, Blox saves the native theme package and selection for the next launch. Blox restores the previous theme when the target is disabled. If more than one vault is open, set BLOX_OBSIDIAN_VAULT to its ID or absolute path and apply again."
            color: Theme.foreground
            wrapMode: Text.Wrap
        }

    }

}
