import QtQuick
import QtQuick.Layouts

Loader {
    id: root
    required property string fieldName
    required property var rule
    required property var value
    property string controlName: "widget-setting-" + fieldName
    property int editingSession: 0
    readonly property bool focused: item ? item.focused || false : false
    readonly property bool structured: !!rule && (rule.type === "array" || rule.type === "object" || !!rule.$ref)
    readonly property string validationError: item ? item.validationError || "" : ""
    signal edited(var value)
    Layout.fillWidth: true
    sourceComponent: !structured ? scalar : fieldName === "command" || fieldName === "interfaces" ? list
        : fieldName === "environment" ? environment : fieldName === "items" ? shortcuts : jsonEntries

    Component { id: scalar; SettingsWidgetScalarField { fieldName: root.fieldName; controlName: root.controlName; rule: root.rule || ({}); value: root.value; onEdited: value => root.edited(value) } }
    Component { id: list; SettingsWidgetListEditor { prefix: root.controlName; value: root.value; command: root.fieldName === "command"; onEdited: value => root.edited(value) } }
    Component { id: environment; SettingsWidgetMapEditor { prefix: root.controlName; value: root.value; onEdited: value => root.edited(value) } }
    Component { id: shortcuts; SettingsWidgetShortcuts { prefix: root.controlName; value: root.value; editingSession: root.editingSession; onEdited: value => root.edited(value) } }
    Component { id: jsonEntries; SettingsWidgetJsonEditor { prefix: root.controlName; value: root.value; editingSession: root.editingSession; onEdited: value => root.edited(value) } }
}
