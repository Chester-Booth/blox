import qs.modules
import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: modalFocusScope

    required property SettingsThemeEditorController controller

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

    Keys.onEscapePressed: event => {
        if (controller.busy || controller.creationBusy) {
            event.accepted = true;
            return;
        }
        controller.dismissModal();
        event.accepted = true;
    }

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
        objectName: "settings-modal-card"

        anchors.centerIn: parent
        width: Math.max(0, Math.min(controller.modalKind === "widget" ? 620 : 500, modalFocusScope.width - 40))
        height: controller.modalKind === "widget" ? Math.max(0, Math.min(440, modalFocusScope.height - 40))
            : controller.modalKind === "guide" ? Math.min(modalFocusScope.height - 80, 620) : Math.min(modalFocusScope.height - 80, implicitHeight)
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

            RowLayout {
                Layout.fillWidth: true
                Label {
                    objectName: "settings-modal-title"
                    Layout.fillWidth: true
                    text: controller.modalKind === "new" ? "New theme" : controller.modalKind === "widget" ? (controller.widgetEditIndex >= 0 ? "Edit widget" : "New widget") : controller.modalKind === "guide" ? "Manual application guide" : controller.modalKind === "delete" ? "Delete theme permanently?" : controller.modalKind === "wallpaper-remove" ? "Remove wallpaper from library?" : controller.modalKind === "duplicate" ? "Duplicate theme" : controller.modalKind === "rename" ? "Rename display name" : "Discard unsaved changes?"
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 19
                    font.bold: true
                }
                BloxButton {
                    visible: controller.modalKind === "widget"
                    compact: true
                    iconName: "x"
                    Accessible.name: "Close"
                    onClicked: controller.dismissModal()
                }
            }

            Text {
                visible: (controller.modalKind === "new" && (controller.creationBusy || controller.newFlowPage !== "blank")) || controller.modalKind === "navigate" || controller.modalKind === "close" || controller.modalKind === "delete" || controller.modalKind === "wallpaper-remove"
                Layout.fillWidth: true
                text: controller.modalKind === "new" ? controller.creationBusy ? "Creating the theme from the selected inputs…" : "Choose a wallpaper and the palette generator to use." : controller.modalKind === "delete" ? "This removes the editable source. The action cannot be undone." : controller.modalKind === "wallpaper-remove" ? controller.wallpaperRemovalMessage() : "The temporary Quickshell preview will be restored to the active theme."
                color: controller.modalKind === "wallpaper-remove" && (controller.wallpaperRemovalUsers.length > 0 || controller.wallpaperRemovalError.length > 0) ? Theme.red : Theme.muted
                wrapMode: Text.Wrap
                font.family: Theme.bodyFontFamily
            }

            SettingsThemeCreationFlow {
                id: creationFlow

                controller: modalFocusScope.controller
            }



            ScrollView {
                id: guideScroll
                visible: controller.modalKind === "guide"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                SettingsThemeGuide {
                    width: guideScroll.availableWidth
                    controller: modalFocusScope.controller
                }
            }

            SettingsWidgetEditor {
                id: widgetFlow
                objectName: "widget-editor"
                visible: controller.modalKind === "widget"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                controller: modalFocusScope.controller
            }

            SettingsThemeActionDialog {
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
                    visible: controller.modalKind !== "duplicate" && controller.modalKind !== "new" && controller.modalKind !== "widget"
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

                    visible: true
                    iconName: controller.modalKind === "guide" ? "x" : ""
                    text: controller.modalKind === "guide" ? "Back" : "Cancel"
                    onClicked: {
                        if (controller.modalKind === "guide")
                            controller.closeGuide();
                        else
                            controller.dismissModal();
                    }
                }

                Item { visible: controller.modalKind === "widget"; Layout.fillWidth: true }

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
                    objectName: "widget-save-button"
                    text: "Save widget"
                    enabled: controller.widgetControlsEnabled && controller.widgetDraft && controller.widgetDraft.name.trim().length > 0
                        && controller.widgetDraftError.length === 0 && widgetFlow.inputError.length === 0
                    onClicked: controller.saveWidgetDraft()
                }

                BloxButton {
                    visible: false
                }

                BloxButton {
                    visible: controller.modalKind !== "new" && controller.modalKind !== "guide" && controller.modalKind !== "widget"
                    text: controller.modalKind === "delete" ? "Delete" : controller.modalKind === "wallpaper-remove" ? "Remove" : controller.modalKind === "duplicate" ? "Duplicate" : controller.modalKind === "rename" ? "Rename" : "Discard"
                    destructive: controller.modalKind === "delete" || controller.modalKind === "wallpaper-remove" || controller.modalKind === "close" || controller.modalKind === "navigate"
                    enabled: controller.modalConfirmationEnabled()
                    onClicked: controller.confirmModal()
                }

            }

        }

    }

}
