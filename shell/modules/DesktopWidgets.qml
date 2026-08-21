import "../services"
import "../shared"
import "../shared" as Shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

// Renders configured desktop widgets and owns their edit session.
Scope {
    id: root

    property string scriptRoot: Quickshell.shellDir + "/scripts"
    property bool editMode: false
    property bool editWorkspaceEntered: false
    property string editReturnWorkspace: ""
    property var editItems: []

    function cloneItems(items) {
        return JSON.parse(JSON.stringify(items || []));
    }

    function beginEdit() {
        if (editMode)
            return "editing";

        editItems = cloneItems(Theme.widgetItems.filter((item) => {
            return item.enabled;
        }));
        editReturnWorkspace = Hyprland.focusedWorkspace ? String(Hyprland.focusedWorkspace.id) : "";
        editMode = true;
        editWorkspaceEntered = true;
        Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"name:blox-widget-edit\" })"]);
        return "editing";
    }

    function cancelEdit() {
        editMode = false;
        editItems = [];
        const returnWorkspace = leaveEditWorkspace();
        Theme.widgetEditModeFinished("", returnWorkspace);
        return "cancelled";
    }

    function leaveEditWorkspace() {
        if (!editWorkspaceEntered)
            return editReturnWorkspace;

        const returnWorkspace = editReturnWorkspace;
        editWorkspaceEntered = false;
        editReturnWorkspace = "";
        Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + (returnWorkspace || "previous") + "\" })"]);
        return returnWorkspace;
    }

    function saveEdit() {
        const editedById = {
        };
        editItems.forEach((item) => {
            return editedById[item.id] = item;
        });
        Theme.widgetItems = Theme.widgetItems.map((item) => {
            return editedById[item.id] || item;
        });
        const payload = JSON.stringify(Theme.widgetItems);
        editMode = false;
        editItems = [];
        const returnWorkspace = leaveEditWorkspace();
        Theme.widgetEditModeFinished(payload, returnWorkspace);
        return payload;
    }

    function replaceEditItem(index, item) {
        const items = editItems.slice();
        items[index] = item;
        editItems = items;
    }

    function run(command) {
        if (command.length === 0)
            return ;

        Quickshell.execDetached(["sh", "-c", command]);
    }

    function commandFor(command) {
        return String(command || "").replace(/\$SCRIPT_ROOT/g, root.scriptRoot);
    }

    function activeWorkspaceEmpty() {
        return workspaceState.json.empty === true;
    }

    // Keep empty-workspace visibility in sync with Hyprland events and a
    // periodic fallback refresh.
    ScriptPoller {
        id: workspaceState

        command: [root.scriptRoot + "/widgets/workspace-empty.sh"]
        interval: 300000
    }

    Connections {
        function onWidgetEditModeRequested() {
            root.beginEdit();
        }

        function onWidgetEditModeCancelRequested() {
            if (root.editMode)
                root.cancelEdit();

        }

        target: Theme
    }

    Connections {
        function onRawEvent(event) {
            if (event.name === "workspace" || event.name === "workspacev2" || event.name === "openwindow" || event.name === "closewindow")
                workspaceState.refresh();

        }

        target: Hyprland
    }

    Variants {
        model: Theme.widgetItems.filter((item) => {
            return item.enabled;
        })

        PanelWindow {
            id: widgetWindow

            required property var modelData
            readonly property bool atLeft: modelData.anchor === "top-left" || modelData.anchor === "bottom-left"
            readonly property bool atRight: modelData.anchor === "top-right" || modelData.anchor === "bottom-right"
            readonly property bool atTop: modelData.anchor === "top-left" || modelData.anchor === "top-right"
            readonly property bool atBottom: modelData.anchor === "bottom-left" || modelData.anchor === "bottom-right"

            screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
            implicitWidth: modelData.anchor === "centre" ? 1 : widgetRenderer.width
            implicitHeight: modelData.anchor === "centre" ? 1 : widgetRenderer.height
            exclusiveZone: 0
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            color: "transparent"
            visible: !root.editMode && (modelData.visibility !== "empty-workspace" || root.activeWorkspaceEmpty())
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "blox-widget-" + modelData.id
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors {
                left: widgetWindow.atLeft || modelData.anchor === "centre"
                right: widgetWindow.atRight || modelData.anchor === "centre"
                top: widgetWindow.atTop || modelData.anchor === "centre"
                bottom: widgetWindow.atBottom || modelData.anchor === "centre"
            }

            margins {
                left: widgetWindow.atLeft ? modelData.offset_x : 0
                right: widgetWindow.atRight ? modelData.offset_x : 0
                top: widgetWindow.atTop ? modelData.offset_y : 0
                bottom: widgetWindow.atBottom ? modelData.offset_y : 0
            }

            Shared.DesktopWidget {
                id: widgetRenderer

                x: widgetWindow.modelData.anchor === "centre" ? Math.round((parent.width - width) / 2) + widgetWindow.modelData.offset_x : 0
                y: widgetWindow.modelData.anchor === "centre" ? Math.round((parent.height - height) / 2) + widgetWindow.modelData.offset_y : 0
                widget: widgetWindow.modelData
                scriptRoot: root.scriptRoot
                renderUpdates: widgetWindow.visible
                maximumWidth: widgetWindow.screen ? Math.max(80, widgetWindow.screen.width - (widgetWindow.modelData.anchor === "centre" ? Math.abs(Number(widgetWindow.modelData.offset_x || 0)) * 2 : Math.max(0, Number(widgetWindow.modelData.offset_x || 0)))) : 0
                maximumHeight: widgetWindow.screen ? Math.max(48, widgetWindow.screen.height - (widgetWindow.modelData.anchor === "centre" ? Math.abs(Number(widgetWindow.modelData.offset_y || 0)) * 2 : Math.max(0, Number(widgetWindow.modelData.offset_y || 0)))) : 0
                onLeftClicked: {
                    root.run(root.commandFor(widgetWindow.modelData.left_click_command));
                    actionRefresh.restart();
                }
                onRightClicked: {
                    root.run(root.commandFor(widgetWindow.modelData.right_click_command));
                    actionRefresh.restart();
                }
            }

            Timer {
                id: actionRefresh

                interval: 500
                onTriggered: widgetRenderer.refresh()
            }

            // A centred widget's anchored layer surface spans the whole
            // output.  Limit its input region to the renderer so its
            // transparent area cannot steal clicks from other widgets.
            mask: Region {
                item: widgetRenderer
            }

        }

    }

    WidgetEditMode {
        active: root.editMode
        items: root.editItems
        onItemChanged: (index, item) => {
            return root.replaceEditItem(index, item);
        }
        onExitRequested: root.cancelEdit()
        onSaveRequested: root.saveEdit()
    }

    IpcHandler {
        function open() : string {
            return root.beginEdit();
        }

        function close() : string {
            return root.cancelEdit();
        }

        function save() : string {
            return root.saveEdit();
        }

        function status() : string {
            return JSON.stringify({
                "active": root.editMode,
                "items": root.editItems
            });
        }

        target: "widget-edit"
    }

}
