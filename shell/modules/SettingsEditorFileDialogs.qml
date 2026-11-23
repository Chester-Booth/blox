import qs.modules
import QtQuick
import QtQuick.Dialogs

Item {
    id: dialogs

    required property SettingsThemeEditorController controller
    required property var parentWindow
    property var externalParentWindow: null

    function openWallpaper() {
        wallpaperDialog.open();
    }



    function openGeneratedExport() {
        generatedExportDialog.parentWindow = externalParentWindow || parentWindow;
        generatedExportDialog.open();
        externalParentWindow = null;
    }

    function openWidgetImport() {
        widgetImportDialog.open();
    }

    function openWidgetExport() {
        widgetExportDialog.open();
    }

    visible: false

    FileDialog {
        id: wallpaperDialog

        parentWindow: dialogs.parentWindow
        title: "Choose a wallpaper"
        modality: Qt.WindowModal
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp)", "All files (*)"]
        onAccepted: {
            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            if (controller.wallpaperDialogTarget === "new")
                controller.newWallpaper = path;
            else if (controller.wallpaperDialogTarget === "library")
                controller.importWallpaper(path);
            else
                controller.setWallpaperPath(path);
            if (controller.wallpaperDialogTarget === "new")
                controller.schedulePaletteRequest();

        }
    }





    FileDialog {
        id: generatedExportDialog

        parentWindow: dialogs.parentWindow
        title: "Download " + controller.generatedDownloadFile
        modality: Qt.WindowModal
        fileMode: FileDialog.SaveFile
        defaultSuffix: controller.generatedDownloadArchive ? "zip" : controller.generatedDownloadFile.indexOf(".") >= 0 ? controller.generatedDownloadFile.slice(controller.generatedDownloadFile.lastIndexOf(".") + 1) : "txt"
        nameFilters: controller.generatedDownloadArchive ? ["Zip archive (*.zip)"] : ["Generated file (*.*)"]
        onAccepted: {
            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            const args = ["export-target", controller.generatedDownloadTarget, "--output", path];
            if (controller.generatedDownloadArchive)
                args.push("--archive");
            else
                args.push("--file", controller.generatedDownloadFile);
            controller.runApi("export-target", args);
        }
    }

    FileDialog {
        id: widgetImportDialog

        parentWindow: dialogs.parentWindow
        title: "Import widgets"
        modality: Qt.WindowModal
        nameFilters: ["Blox widgets (*.json)"]
        onAccepted: {
            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            controller.runApi("widgets-import", ["widgets-import", path]);
        }
    }

    FileDialog {
        id: widgetExportDialog

        parentWindow: dialogs.parentWindow
        title: "Export widgets"
        modality: Qt.WindowModal
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: ["Blox widgets (*.json)"]
        onAccepted: {
            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            controller.runApi("widgets-export", ["widgets-export", JSON.stringify(controller.widgetProfileDocument()), "--output", path]);
        }
    }

}
