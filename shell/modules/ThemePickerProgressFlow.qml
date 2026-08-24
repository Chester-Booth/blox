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
            controller.guideTarget = target;
            controller.modalKind = "guide";
        }
    }

    ColumnLayout {
        visible: controller.modalKind === "guide"
        Layout.fillWidth: true

        Image {
            visible: controller.guideTarget === "stylus"
            Layout.fillWidth: true
            height: 180
            source: "../assets/stylus-import.png"
            fillMode: Image.PreserveAspectFit
        }

        Text {
            Layout.fillWidth: true
            text: controller.guideTarget === "obsidian" ? "1. Install and select the Minimal theme, then enable the Style Settings plugin.\n2. Open Style Settings in its own pane and choose Import.\n3. Select the generated style-settings.json file and confirm the import." : "1. Open the Stylus extension dashboard.\n2. Choose Import and select the generated blox-system.user.css file.\n3. Replace the previous Blox System Theme entry, then enable it."
            color: Theme.foreground
            wrapMode: Text.Wrap
        }

        BloxButton {
            visible: controller.guideTarget === "stylus"
            Layout.alignment: Qt.AlignRight
            iconName: "download-simple"
            text: "Download file"
            onClicked: controller.downloadGeneratedFile("stylus", "stylus/blox-system.user.css")
        }

    }

}
