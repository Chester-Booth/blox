import QtQuick
import qs.modules
import qs.shared

Item {
    id: host
    required property int captureWidth
    required property int captureHeight
    required property string catalogueJson
    required property string schemaJson
    width: captureWidth
    height: captureHeight
    property var widgetCatalogue: JSON.parse(catalogueJson)
    property var widgetSchema: JSON.parse(schemaJson)
    property var widgetRegistry: ({example: {layouts:["native","fit"], providers:["clock"]}})
    property bool mutationProtected: false
    property bool applyingSettingsDraft: false
    property var staged: ({schemaVersion:1,widgets:[]})
    property alias controller: controller
    property alias modal: modal
    function focusModal() { modal.forceActiveFocus(); }
    function find(name, parent) {
        parent = parent || host;
        if (parent.objectName === name) return parent;
        for (const child of parent.children) {
            const result = find(name, child);
            if (result) return result;
        }
        return null;
    }
    function configure(json) {
        const options = JSON.parse(json);
        const flow = find("widget-editor");
        flow.changeKind(options.kind || "command");
        if (options.kind === "qml") {
            flow.chooseManifest("example");
            controller.updateWidgetOption("settings", {title:"Clock",palette:{accent:"blue"}});
        }
        if (options.kind === "weather") {
            controller.updateWidgetOption("latitude",51.5);
            controller.updateWidgetOption("longitude",-0.1);
        }
        if (options.kind === "shortcuts") controller.updateWidgetOption("items",[{id:"terminal",label:"Terminal",command:["kitty","--class","notes"]}]);
        if (options.kind === "network") controller.updateWidgetOption("interfaces",["wlan0"]);
        if (["command","terminal"].indexOf(options.kind) >= 0) {
            controller.updateWidgetDraft({name:options.kind === "terminal" ? "Tree" : "Todo"});
            controller.updateWidgetOption("command", options.kind === "terminal" ? ["cbonsai","-l"] : ["/home/blox/Code/blox/shell/scripts/widgets/todo-content.sh"]);
            controller.updateWidgetOption("workingDirectory", "/home/blox/Todo");
            controller.updateWidgetOption("environment", {LANG:"en_GB.UTF-8"});
        }
        if (options.kind === "command") {
            controller.updateWidgetOption("intervalSeconds",60);
            controller.updateWidgetOption("timeoutSeconds",15);
            controller.updateWidgetOption("fontFamily",Theme.monoFontFamily);
            controller.updateWidgetOption("fontSize",14);
            controller.updateWidgetOption("padding",24);
            controller.updateWidgetOption("actions", {left:{kind:"run",command:["blox-widget-action","todo","next"],workingDirectory:"/home/blox/Todo",environment:{LANG:"en_GB.UTF-8"},timeoutSeconds:5},right:{kind:"launch",command:["kitty"]}});
            if (options.action && options.actionKind) {
                const actions = JSON.parse(JSON.stringify(controller.widgetDraft.settings.actions));
                actions[options.action] = options.actionKind === "none" ? null : options.actionKind === "launch"
                    ? {kind:"launch",command:["kitty"]} : {kind:"run",command:["blox-widget-action","todo","next"],workingDirectory:"/home/blox/Todo",environment:{LANG:"en_GB.UTF-8"},timeoutSeconds:5};
                controller.updateWidgetOption("actions",actions);
            }
        }
        if (options.kind === "terminal" && options.restart) controller.updateWidgetOption("restartPolicy",options.restart);
        controller.updateWidgetDraft({appearance:{presentation:"compact",backgroundOpacity:0.8,scrollbars:"auto"},
            placement:{anchor:"top-left",x:35,y:40,width:425,height:350,sizing:"fixed"}});
        if (options.selected) controller.updateWidgetDraft({workspaces:{mode:"include",ids:[2,"special:notes"],ranges:[[4,6]]}});
        flow.currentTab = options.tab || 0;
        flow.contentAdvanced = !!options.advanced && flow.currentTab === 0;
        if (options.action) flow.actionSide = options.action;
        host.forceActiveFocus();
    }
    Rectangle { anchors.fill: parent; color: Theme.background }
    SettingsThemeEditorController {
        id: controller
        host: host
        widgetProfileProvider: function() { return host.staged; }
        widgetProfileWriter: function(profile) { host.staged = profile; return true; }
    }
    SettingsEditorModal { id: modal; controller: controller; anchors.fill: parent }
    Component.onCompleted: {
        controller.candidate = {id:"fixture",widgets:{schemaVersion:1,widgets:[]}};
        controller.openWidgetEditor(-1);
    }
}
