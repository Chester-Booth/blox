import "../shared"
import QtQuick
import QtQuick.Controls
import Quickshell

FloatingWindow {
    id: root

    required property LauncherMainController controller
    property var targetScreen
    readonly property int targetWindowHeight: Math.min(targetScreen ? targetScreen.height - 80 : 900, Math.max(680, 232 + Math.ceil(controller.applyProgressRows.length / 2) * 56))
    readonly property int preferredWindowHeight: controller.applyProgressShowTargets ? targetWindowHeight : 430

    title: "Blox Theme Application"
    implicitWidth: 770
    implicitHeight: preferredWindowHeight
    minimumSize: Qt.size(680, preferredWindowHeight)
    screen: targetScreen
    visible: controller.applyWindowOpen
    color: "transparent"
    onClosed: controller.dismissThemeApply()

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(1)
        radius: Theme.scaledRadius(9)
        color: Theme.background
        border.color: Theme.border
        border.width: 1
        clip: true

        Item {
            id: titleBar

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 48

            DragHandler {
                target: null
                acceptedButtons: Qt.LeftButton
                onActiveChanged: {
                    if (active)
                        root.contentItem.QsWindow.window.startSystemMove();

                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.scaledSpacing(20)
                anchors.verticalCenter: parent.verticalCenter
                text: "Theme application"
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
            }

            BloxButton {
                anchors.right: parent.right
                anchors.rightMargin: Theme.scaledSpacing(12)
                anchors.verticalCenter: parent.verticalCenter
                text: controller.applyGuideTarget.length ? "Back" : controller.applyingTheme ? "Cancel" : "Close"
                onClicked: {
                    if (controller.applyGuideTarget.length)
                        controller.applyGuideTarget = "";
                    else
                        controller.dismissThemeApply();
                }
            }

        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            height: 1
            color: Theme.border
        }

        ThemeApplyProgress {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.scaledSpacing(28)
            visible: !controller.applyGuideTarget.length
            themeName: controller.applyingThemeName
            stages: controller.applyProgressStages
            targets: controller.applyProgressRows
            progress: controller.applyProgressValue
            message: controller.applyProgressMessage
            showTargets: controller.applyProgressShowTargets
            complete: controller.applyProgressComplete
            error: controller.applyError
            showCloseButton: false
            onRetryRequested: (target) => {
                return controller.retryThemeTarget(target);
            }
            onGuideRequested: (target) => {
                return controller.applyGuideTarget = target;
            }
            onCloseRequested: controller.dismissThemeApply()
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            anchors.margins: Theme.scaledSpacing(28)
            spacing: Theme.scaledSpacing(16)
            visible: controller.applyGuideTarget.length > 0

            Text {
                text: controller.applyGuideTarget === "obsidian" ? "Obsidian application guide" : "Stylus application guide"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 22
                font.bold: true
            }

            Text {
                width: parent.width
                text: controller.applyGuideTarget === "obsidian" ? "1. Install and select the Minimal theme, then enable Style Settings.\n2. Open Style Settings and choose Import.\n3. Import ~/.local/state/blox-theme/current/obsidian/style-settings.json." : "1. Open the Stylus extension dashboard.\n2. Choose Import.\n3. Import ~/.local/state/blox-theme/current/stylus/blox-system.user.css and enable it."
                color: Theme.foreground
                wrapMode: Text.Wrap
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
            }

        }

    }

}
