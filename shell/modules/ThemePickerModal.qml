import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: modalFocusScope

    required property ThemePickerController controller

    function focusInitial() {
        if (controller.modalKind === "new")
            creationFlow.focusInitial();
        else if (controller.modalKind === "widget")
            widgetFlow.focusInitial();
        else if (controller.modalKind === "duplicate" || controller.modalKind === "rename")
            actionFlow.focusInitial();
        else if (modalCancelButton.visible)
            modalCancelButton.forceActiveFocus();
        else
            modalFocusScope.forceActiveFocus();
    }

    anchors.fill: parent
    visible: controller.modalKind.length > 0
    focus: visible
    z: 50

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha("#000000", 0.68)
    }

    MouseArea {
        id: modalInputBlocker

        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        preventStealing: true
    }

    Rectangle {
        id: modalCard

        anchors.centerIn: parent
        width: controller.modalKind === "progress" ? Math.min(770, modalFocusScope.width - 80) : 500
        height: controller.modalKind === "guide" ? Math.min(modalFocusScope.height - 80, 620) : Math.min(modalFocusScope.height - 80, implicitHeight)
        implicitHeight: modalColumn.implicitHeight + 40
        radius: Theme.scaledRadius(10)
        color: Theme.surface
        border.color: Theme.border
        clip: true

        MouseArea {
            id: modalCardInputBlocker

            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            preventStealing: true
        }

        ColumnLayout {
            id: modalColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: Theme.scaledSpacing(20)
            spacing: Theme.scaledSpacing(12)

            Label {
                visible: controller.modalKind !== "progress"
                Layout.fillWidth: true
                text: controller.modalKind === "new" ? "New theme" : controller.modalKind === "widget" ? (controller.widgetEditIndex >= 0 ? "Edit widget" : "New widget") : controller.modalKind === "progress" ? "Applying theme" : controller.modalKind === "guide" ? "Manual application guide" : controller.modalKind === "delete" ? "Delete theme permanently?" : controller.modalKind === "wallpaper-remove" ? "Remove wallpaper from library?" : controller.modalKind === "duplicate" ? "Duplicate theme" : controller.modalKind === "rename" ? "Rename display name" : controller.modalKind === "export" ? "Export theme" : "Discard unsaved changes?"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 19
                font.bold: true
            }

            Text {
                visible: controller.modalKind === "new" || controller.modalKind === "navigate" || controller.modalKind === "generate-current" || controller.modalKind === "close" || controller.modalKind === "delete" || controller.modalKind === "wallpaper-remove" || controller.modalKind === "export"
                Layout.fillWidth: true
                text: controller.modalKind === "new" ? controller.creationBusy ? "Creating the theme from the selected inputs…" : controller.newFlowPage === "blank" ? "Create a blank editable theme." : "Choose a wallpaper and the palette generator to use." : controller.modalKind === "progress" ? controller.applyProgressComplete ? "Application finished. Review any follow-up actions below." : "Generating and applying each enabled target…" : controller.modalKind === "delete" ? "This removes the editable source. The action cannot be undone." : controller.modalKind === "wallpaper-remove" ? controller.wallpaperRemovalMessage() : controller.modalKind === "export" ? "Create a portable bundle. Fonts, GTK, icon and cursor themes remain dependency notes." : "The temporary Quickshell preview will be restored to the active theme."
                color: controller.modalKind === "wallpaper-remove" && (controller.wallpaperRemovalUsers.length > 0 || controller.wallpaperRemovalError.length > 0) ? Theme.red : Theme.muted
                wrapMode: Text.Wrap
                font.family: Theme.bodyFontFamily
            }

            ThemePickerCreationFlow {
                id: creationFlow

                controller: modalFocusScope.controller
            }

            ScrollView {
                id: progressScroll

                visible: controller.modalKind === "progress" || controller.modalKind === "guide"
                Layout.fillWidth: true
                Layout.fillHeight: controller.modalKind === "guide"
                Layout.preferredHeight: controller.modalKind === "progress" ? controller.applyProgressShowTargets ? 570 : 300 : 0
                clip: true
                contentWidth: availableWidth

                ThemePickerProgressFlow {
                    id: progressFlow

                    width: progressScroll.availableWidth
                    height: implicitHeight
                    controller: modalFocusScope.controller
                }

            }

            ThemePickerWidgetDialog {
                id: widgetFlow

                controller: modalFocusScope.controller
            }

            ThemePickerActionDialog {
                id: actionFlow

                controller: modalFocusScope.controller
            }

            RowLayout {
                Layout.fillWidth: true

                Text {
                    id: duplicateIdFooter

                    visible: controller.modalKind === "duplicate" || controller.modalKind === "new" && !controller.creationBusy
                    Layout.fillWidth: true
                    text: controller.modalKind === "new" ? controller.newThemeId : controller.duplicateId
                    color: Theme.muted
                    elide: Text.ElideMiddle
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 10
                }

                Item {
                    visible: controller.modalKind !== "duplicate" && controller.modalKind !== "new" && controller.modalKind !== "export" && controller.modalKind !== "widget"
                    Layout.fillWidth: true
                }

                BloxButton {
                    visible: controller.modalKind === "guide" && controller.guideTarget === "stylus"
                    iconName: "download-simple"
                    text: "Download file"
                    onClicked: controller.downloadGeneratedFile("stylus", "stylus/blox-system.user.css")
                }

                BloxButton {
                    id: modalCancelButton

                    visible: controller.modalKind !== "progress" || controller.applyProgressComplete
                    iconName: controller.modalKind === "guide" ? "x" : ""
                    text: controller.modalKind === "guide" ? "Back" : controller.modalKind === "progress" ? controller.applyQuickshellReloadPending ? "Complete and reload" : "Complete" : "Cancel"
                    onClicked: {
                        if (controller.modalKind === "guide")
                            controller.closeGuide();
                        else if (controller.modalKind === "progress")
                            controller.completeApply();
                        else
                            controller.dismissModal();
                    }
                }

                BloxButton {
                    visible: controller.modalKind === "new" && !controller.creationBusy
                    text: "Create"
                    enabled: controller.newThemeId.trim().length > 0 && controller.newThemeName.trim().length > 0 && (controller.newFlowPage === "blank" || controller.newWallpaper.trim().length > 0 && controller.paletteOptions.some((entry) => {
                        return entry.backend === controller.generatorBackend && entry.mode === controller.newVariant && entry.available;
                    }))
                    onClicked: controller.startNewTheme(controller.newFlowPage === "wallpaper")
                }

                BloxButton {
                    visible: controller.modalKind === "widget"
                    text: "Save widget"
                    enabled: controller.widgetDraft && controller.widgetDraft.name.trim().length > 0
                    onClicked: controller.saveWidgetDraft()
                }

                BloxButton {
                    visible: false
                }

                BloxButton {
                    visible: controller.modalKind !== "new" && controller.modalKind !== "progress" && controller.modalKind !== "guide" && controller.modalKind !== "widget"
                    text: controller.modalKind === "delete" ? "Delete" : controller.modalKind === "wallpaper-remove" ? "Remove" : controller.modalKind === "duplicate" ? "Duplicate" : controller.modalKind === "rename" ? "Rename" : controller.modalKind === "export" ? "Choose destination" : "Discard"
                    destructive: controller.modalKind === "delete" || controller.modalKind === "wallpaper-remove" || controller.modalKind === "close" || controller.modalKind === "navigate" || controller.modalKind === "generate-current"
                    enabled: controller.modalConfirmationEnabled()
                    onClicked: controller.confirmModal()
                }

            }

        }

    }

}
