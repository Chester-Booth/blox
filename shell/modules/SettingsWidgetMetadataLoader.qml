import QtQuick
import Quickshell
import Quickshell.Io
import qs.shared

// Loads desktop widget catalogue, profile schema, and trusted registry metadata
// on demand when the Settings window is open.
Scope {
    id: root

    property bool active: false
    property string widgetSourceRoot: ""
    property var widgetCatalogue: null
    property var widgetSchema: null
    property var widgetRegistry: ({})
    property string widgetCatalogueError: ""
    property string widgetSchemaError: ""
    property string widgetRegistryError: ""
    property var widgetRegistryErrors: []
    property string widgetRegistryOutput: ""
    property string widgetRegistryStderr: ""
    readonly property alias registryProcess: widgetRegistryProcess
    readonly property string widgetMetadataError: widgetCatalogueError || widgetSchemaError || widgetRegistryError

    function loadMetadata(kind, text) {
        try {
            const document = JSON.parse(text);
            if (kind === "catalogue") {
                if (!document || document.schemaVersion !== 1 || !Array.isArray(document.widgets))
                    throw new Error("Expected the version 1 widget catalogue.");
                widgetCatalogue = document;
                widgetCatalogueError = "";
            } else {
                if (!document || !document.$defs || !document.properties || !document.properties.widgets
                        || !document.properties.widgets.items || !Array.isArray(document.properties.widgets.items.oneOf))
                    throw new Error("Expected the widget profile schema.");
                widgetSchema = document;
                widgetSchemaError = "";
            }
        } catch (error) {
            if (kind === "catalogue") {
                widgetCatalogue = null;
                widgetCatalogueError = "Could not parse the widget catalogue. " + error.message;
            } else {
                widgetSchema = null;
                widgetSchemaError = "Could not parse the widget schema. " + error.message;
            }
        }
    }

    function finishRegistry(exitCode, exitStatus) {
        if (!active) return;
        let response = null;
        try { response = JSON.parse(widgetRegistryOutput); }
        catch (error) {
            widgetRegistry = ({});
            widgetRegistryError = widgetRegistryStderr.trim() || "Could not parse the trusted widget registry. " + error.message;
            return;
        }
        if (exitCode !== 0 || exitStatus !== 0 || !response || response.ok !== true
                || !response.registry || typeof response.registry !== "object" || Array.isArray(response.registry)
                || !Array.isArray(response.errors)) {
            widgetRegistry = ({});
            widgetRegistryError = response && response.error && response.error.message
                ? response.error.message : widgetRegistryStderr.trim() || "Could not load the trusted widget registry.";
            return;
        }
        widgetRegistry = response.registry;
        widgetRegistryErrors = response.errors || [];
        widgetRegistryError = widgetRegistryErrors.map(entry => entry.package + ": " + entry.message).join("\n");
        Theme.widgetRegistry = response.registry;
        Theme.widgetRegistryLoaded = true;
    }

    FileView {
        path: root.active ? root.widgetSourceRoot + "/catalogue.json" : ""
        preload: root.active
        printErrors: false
        onLoaded: { if (root.active) root.loadMetadata("catalogue", text()); }
        onLoadFailed: {
            if (!root.active) return;
            root.widgetCatalogue = null;
            root.widgetCatalogueError = "Could not read the widget catalogue.";
        }
    }

    FileView {
        path: root.active ? root.widgetSourceRoot + "/schema/profile.schema.json" : ""
        preload: root.active
        printErrors: false
        onLoaded: { if (root.active) root.loadMetadata("schema", text()); }
        onLoadFailed: {
            if (!root.active) return;
            root.widgetSchema = null;
            root.widgetSchemaError = "Could not read the widget profile schema.";
        }
    }

    Process {
        id: widgetRegistryProcess
        command: ["python3", "-m", "blox_widgets.cli", "registry"]
        environment: ({PYTHONPATH: root.widgetSourceRoot + "/lib"})
        running: root.active
        onStarted: {
            root.widgetRegistry = ({});
            root.widgetRegistryErrors = [];
            root.widgetRegistryError = "";
            root.widgetRegistryOutput = "";
            root.widgetRegistryStderr = "";
        }
        onExited: (exitCode, exitStatus) => root.finishRegistry(exitCode, exitStatus)
        stdout: StdioCollector { onStreamFinished: root.widgetRegistryOutput = this.text }
        stderr: StdioCollector { onStreamFinished: root.widgetRegistryStderr = this.text }
    }
}
