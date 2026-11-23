import QtQuick
import QtQuick.Dialogs
import Quickshell

Item {
    id: root
    required property var flowState
    required property var parentWindow
    visible: false

    function openCurrent() {
        if (flowState.dialogKind === "file-open")
            importDialog.open();
        else if (flowState.dialogKind === "file-save") {
            exportDialog.selectedFile = flowState.saveFileUrl;
            exportDialog.open();
        }
    }

    Component.onCompleted: Qt.callLater(openCurrent)

    Connections {
        target: root.flowState
        function onDialogKindChanged() { Qt.callLater(root.openCurrent) }
    }

    FileDialog {
        id: importDialog
        parentWindow: root.parentWindow._backingWindow
        title: "Import a theme"
        modality: Qt.WindowModal
        fileMode: FileDialog.OpenFile
        nameFilters: ["Blox themes (*.blox-theme *.json)", "All files (*)"]
        onAccepted: {
            root.flowState.inspectImport(decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")));
        }
        onRejected: root.flowState.closeBundleDialog()
    }

    FileDialog {
        id: exportDialog
        parentWindow: root.parentWindow._backingWindow
        title: "Download theme"
        modality: Qt.WindowModal
        fileMode: FileDialog.SaveFile
        defaultSuffix: "blox-theme"
        nameFilters: ["Blox theme bundle (*.blox-theme)"]
        onAccepted: {
            root.flowState.saveExport(decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")));
        }
        onRejected: {
            root.flowState.dialogKind = "export-review";
            root.flowState.bundleStep = "contents";
        }
    }
}
