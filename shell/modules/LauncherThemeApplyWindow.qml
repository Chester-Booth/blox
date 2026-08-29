import qs.shared
import QtQuick
import QtQuick.Controls
import Quickshell

FloatingWindow {
    id: root

    required property LauncherMainController controller
    property var targetScreen
    readonly property int targetWindowHeight: Math.min(targetScreen ? targetScreen.height - 80 : 900, Math.max(680, 232 + Math.ceil(controller.applyProgressRows.length / 2) * 56))
    readonly property int preferredWindowHeight: controller.applyGuideTarget.length > 0 ? Math.min(targetScreen ? targetScreen.height - 80 : 900, 760) : controller.applyProgressShowTargets ? targetWindowHeight : 430

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
            showCompleteButton: true
            pendingQuickshellReload: controller.applyQuickshellReloadPending
            onRetryRequested: (target) => {
                return controller.retryThemeTarget(target);
            }
            onGuideRequested: (target) => {
                return controller.applyGuideTarget = target;
            }
            onCompleteRequested: controller.completeThemeApply()
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleBar.bottom
            anchors.margins: Theme.scaledSpacing(28)
            spacing: Theme.scaledSpacing(8)
            visible: controller.applyGuideTarget.length > 0

            Text {
                text: controller.applyGuideTarget === "obsidian" ? "Obsidian application guide" : "Stylus application guide"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 22
                font.bold: true
            }

            Text {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                text: "In your browser, press Ctrl+O and open the generated Stylus file at:"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            Row {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                spacing: Theme.scaledSpacing(8)

                Text {
                    width: parent.width - copyStylusPath.width - parent.spacing
                    text: Theme.stateRoot + "/blox-theme/current/stylus/blox-system.user.css"
                    color: Theme.muted
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                    verticalAlignment: Text.AlignVCenter
                }

                CopyPathButton {
                    id: copyStylusPath

                    value: Theme.stateRoot + "/blox-theme/current/stylus/blox-system.user.css"
                }

            }

            Text {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                text: "After changing theme, open or reload this file, then click Install style the first time, or Reinstall style if the style is already installed."
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            Text {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                text: "If Stylus lists more than one Blox Web Theme, disable or remove the older copy first."
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            Row {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                spacing: Theme.scaledSpacing(8)

                Column {
                    width: (parent.width - parent.spacing) / 2
                    spacing: Theme.scaledSpacing(2)

                    Text {
                        width: parent.width
                        text: "First install"
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }

                    Image {
                        width: parent.width
                        height: 45
                        source: "../assets/stylus-install-style.png"
                        fillMode: Image.PreserveAspectFit
                    }
                }

                Column {
                    width: (parent.width - parent.spacing) / 2
                    spacing: Theme.scaledSpacing(2)

                    Text {
                        width: parent.width
                        text: "Already installed"
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }

                    Image {
                        width: parent.width
                        height: 45
                        source: "../assets/stylus-reinstall-style.png"
                        fillMode: Image.PreserveAspectFit
                    }
                }
            }

            Text {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                text: "Note: You may need to give Stylus permission to access local files in your extension settings."
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            Text {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                text: "Chrome or Chromium: Allow access to file URLs"
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            Image {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                height: 70
                source: "../assets/stylus-file-urls.png"
                fillMode: Image.PreserveAspectFit
            }

            Text {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                text: "Firefox or Zen: Access local files on your computer"
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            Image {
                visible: controller.applyGuideTarget === "stylus"
                width: parent.width
                height: 180
                source: "../assets/stylus-file-access-firefox.png"
                fillMode: Image.PreserveAspectFit
            }

            Text {
                visible: controller.applyGuideTarget === "obsidian"
                width: parent.width
                text: "1. Install and select the Minimal theme, then enable Style Settings.\n2. Open Style Settings and choose Import.\n3. Import ~/.local/state/blox-theme/current/obsidian/style-settings.json."
                color: Theme.foreground
                wrapMode: Text.Wrap
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
            }

        }

    }

}
