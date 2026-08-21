import "."
import "../shared"
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    required property ThemePickerController controller

    function focusInitial() {
        if (controller.modalKind === "duplicate")
            duplicateNameField.focusEditor(true);
        else if (controller.modalKind === "rename")
            renameNameField.focusEditor(true);
    }

    visible: controller.modalKind === "duplicate" || controller.modalKind === "rename" || controller.modalKind === "export"
    Layout.fillWidth: true
    spacing: 12

    BloxTextField {
        id: duplicateNameField

        visible: controller.modalKind === "duplicate"
        Layout.fillWidth: true
        placeholderText: "My Theme - Copy"
        text: controller.duplicateName
        onTextChanged: {
            controller.duplicateName = text;
            controller.duplicateId = controller.duplicateIdForName(text);
        }
        onAccepted: {
            if (controller.modalConfirmationEnabled())
                controller.confirmModal();

        }
    }

    BloxTextField {
        id: renameNameField

        visible: controller.modalKind === "rename"
        Layout.fillWidth: true
        placeholderText: "My Theme"
        text: controller.renameName
        onTextChanged: controller.renameName = text
        onAccepted: {
            if (controller.modalConfirmationEnabled())
                controller.confirmModal();

        }
    }

    BloxCheckBox {
        visible: controller.modalKind === "export"
        text: "Include wallpaper in bundle"
        checked: controller.exportIncludeWallpaper
        onToggled: controller.exportIncludeWallpaper = checked
    }

    BloxCheckBox {
        visible: controller.modalKind === "export"
        text: "Include widgets in bundle"
        checked: controller.exportIncludeWidgets
        onToggled: controller.exportIncludeWidgets = checked
    }

}
