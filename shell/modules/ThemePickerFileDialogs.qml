import qs.modules
import QtQuick
import QtQuick.Dialogs

Item {
    id: dialogs

    required property ThemePickerController controller
    required property var parentWindow

    function openWallpaper() {
        wallpaperDialog.open();
    }

    function openImport() {
        importDialog.open();
    }

    function openExport() {
        exportDialog.open();
    }

    function openGeneratedExport() {
        generatedExportDialog.open();
    }

    function openWidgetImport() {
        widgetImportDialog.open();
    }

    function openWidgetFile() {
        widgetFileDialog.open();
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
                paletteDelay.restart();

        }
    }

    FileDialog {
        id: importDialog

        parentWindow: dialogs.parentWindow
        title: "Import a theme"
        modality: Qt.WindowModal
        nameFilters: ["Blox themes (*.blox-theme *.json)", "All files (*)"]
        onAccepted: {
            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            controller.runApi("import", ["import", path]);
        }
    }

    FileDialog {
        id: exportDialog

        parentWindow: dialogs.parentWindow
        title: "Export theme"
        modality: Qt.WindowModal
        fileMode: FileDialog.SaveFile
        defaultSuffix: "blox-theme"
        nameFilters: ["Blox theme bundle (*.blox-theme)"]
        onAccepted: {
            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            const args = ["export", controller.candidate.id, "--output", path];
            if (controller.exportIncludeWallpaper)
                args.push("--include-wallpaper");

            if (!controller.exportIncludeWidgets)
                args.push("--exclude-widgets");

            controller.runApi("export", args);
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
        id: widgetFileDialog

        parentWindow: dialogs.parentWindow
        title: "Choose widget file"
        modality: Qt.WindowModal
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (!controller.widgetDraft)
                return ;

            const path = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""));
            controller.widgetDraft.content_command = "sed -n '1,200p' -- " + controller.shellQuote(path);
            controller.widgetDraft = JSON.parse(JSON.stringify(controller.widgetDraft));
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
            controller.runApi("widgets-export", ["widgets-export", JSON.stringify(controller.candidate.widgets || {
                "profile": "minimal"
            }), "--output", path]);
        }
    }

}
