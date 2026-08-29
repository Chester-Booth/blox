import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    required property ThemePickerController controller

    visible: controller.modalKind === "progress" || controller.modalKind === "guide"
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(12)

    ThemeApplyProgress {
        visible: controller.modalKind === "progress"
        Layout.fillWidth: true
        Layout.preferredHeight: controller.applyProgressShowTargets ? 570 : 280
        themeName: controller.candidate ? controller.candidate.name : "Theme"
        stages: controller.applyProgressStages
        targets: controller.applyProgressRows
        progress: controller.applyProgressValue
        message: controller.applyProgressMessage
        showTargets: controller.applyProgressShowTargets
        complete: controller.applyProgressComplete
        error: controller.errorMessage
        onRetryRequested: (target) => {
            return controller.retryApplyTarget(target);
        }
        onGuideRequested: (target) => {
            controller.openGuide(target, "progress");
        }
    }

    ColumnLayout {
        visible: controller.modalKind === "guide"
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(6)

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "In your browser, press Ctrl+O and open the Stylus file at:"
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
                text: Theme.stateRoot + "/blox-theme/current/stylus/blox-system.user.css"
                color: Theme.muted
                font.family: Theme.monoFontFamily
                elide: Text.ElideMiddle
            }

            CopyPathButton {
                value: Theme.stateRoot + "/blox-theme/current/stylus/blox-system.user.css"
            }

        }

        Text {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            text: "Then click Install style."
            color: Theme.foreground
            wrapMode: Text.Wrap
        }

        Image {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            Layout.preferredHeight: 45
            Layout.maximumHeight: 45
            height: 45
            source: "../assets/stylus-install-style.png"
            fillMode: Image.PreserveAspectFit
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
            text: "1. Install and select the Minimal theme, then enable the Style Settings plugin.\n2. Open Style Settings in its own pane and choose Import.\n3. Select the generated style-settings.json file and confirm the import."
            color: Theme.foreground
            wrapMode: Text.Wrap
        }

    }

}
