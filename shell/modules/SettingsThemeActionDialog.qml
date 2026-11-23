import qs.modules
import qs.shared
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    required property SettingsThemeEditorController controller

    function focusInitial() {
        if (controller.modalKind === "duplicate")
            duplicateNameField.focusEditor(true);
        else if (controller.modalKind === "rename")
            renameNameField.focusEditor(true);
    }

    visible: controller.modalKind === "duplicate" || controller.modalKind === "rename"
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(12)

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





}
