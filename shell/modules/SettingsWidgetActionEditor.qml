import QtQuick
import QtQuick.Layouts
import qs.shared

ColumnLayout {
    id: root
    required property var value
    required property var rule
    property string side: "left"
    property bool advanced: false
    property int editingSession: 0
    property var runDraft: null
    property var commandDraft: [""]
    readonly property string prefix: "settings.actions." + side
    readonly property var action: value ? JSON.parse(JSON.stringify(value)) : null
    readonly property string actionKind: action && typeof action === "object" ? action.kind : "none"
    readonly property var actionRule: rule ? rule.oneOf.find(branch => branch.properties && branch.properties.kind.const === actionKind) : null
    readonly property string validationError: environment.validationError
    signal edited(var value)
    spacing: Theme.scaledSpacing(8)
    onEditingSessionChanged: {
        runDraft = null;
        commandDraft = [""];
        advanced = false;
    }

    function replace(key, value) {
        const next = Object.assign({}, root.value);
        next[key] = value;
        edited(next);
    }
    function changeKind(kind) {
        if (kind === actionKind) return;
        if (action && action.command) commandDraft = JSON.parse(JSON.stringify(action.command));
        if (actionKind === "run") runDraft = JSON.parse(JSON.stringify(action));
        if (kind === "none") { edited(null); return; }
        const command = JSON.parse(JSON.stringify(commandDraft));
        edited(kind === "launch" ? {kind: "launch", command: command}
            : Object.assign({kind: "run", workingDirectory: "", environment: {}, timeoutSeconds: 5}, runDraft || {}, {command:command}));
        advanced = false;
    }
    SettingsWidgetScalarField {
        fieldName: "kind"
        label: root.side === "left" ? "Left click" : "Right click"
        controlName: root.prefix + ".kind"
        rule: ({enum:["None", "Run", "Launch"]})
        value: root.actionKind === "run" ? "Run" : root.actionKind === "launch" ? "Launch" : "None"
        onEdited: value => root.changeKind(value.toLowerCase())
    }
    SettingsWidgetListEditor {
        visible: root.actionKind !== "none"
        prefix: root.prefix + ".command"
        value: root.action ? root.action.command || [] : []
        onEdited: value => root.replace("command", value)
    }
    BloxButton { objectName: root.prefix + "-advanced"; visible: root.actionKind === "run"; text: root.advanced ? "Less" : "Advanced"; iconName: "gear-six"; onClicked: root.advanced = !root.advanced }
    ColumnLayout {
        visible: root.actionKind === "run" && root.advanced
        Layout.fillWidth: true
        SettingsWidgetScalarField {
            fieldName: "timeoutSeconds"
            controlName: root.prefix + ".timeoutSeconds"
            rule: root.actionRule ? root.actionRule.properties.timeoutSeconds || {} : ({})
            value: root.value && root.value.timeoutSeconds !== undefined ? root.value.timeoutSeconds : ""
            onEdited: value => root.replace("timeoutSeconds", value)
        }
        SettingsWidgetScalarField {
            fieldName: "workingDirectory"
            controlName: root.prefix + ".workingDirectory"
            rule: ({type:"string"})
            value: root.value ? root.value.workingDirectory || "" : ""
            onEdited: value => root.replace("workingDirectory", value)
        }
        SettingsWidgetMapEditor {
            id: environment
            prefix: root.prefix + ".environment"
            value: root.value && root.value.environment ? root.value.environment : ({})
            onEdited: value => root.replace("environment", value)
        }
    }
}
