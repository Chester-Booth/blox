import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared

ColumnLayout {
    id: root
    required property string fieldName
    required property var rule
    required property var value
    property string controlName: "widget-setting-" + fieldName
    property string label: labels[fieldName] || fieldName
    property string scalarError: ""
    readonly property string validationError: scalarError
    signal edited(var value)
    readonly property var labels: ({style: "Presentation", timezone: "Time zone", format: "Time format", showSeconds: "Seconds",
        player: "Player", showArtwork: "Artwork", intervalSeconds: "Update interval, seconds", historySize: "History samples",
        interfaces: "Interfaces", path: "Calendar file", daysAhead: "Days ahead", maxEvents: "Maximum events", title: "Title",
        text: "Note", directory: "Directory", showHidden: "Hidden files", maxEntries: "Maximum entries", items: "Shortcuts",
        provider: "Provider", latitude: "Latitude", longitude: "Longitude", command: "Command",
        workingDirectory: "Working directory", maxRuntimeSeconds: "Maximum runtime, seconds", environment: "Environment", columns: "Columns", rows: "Rows",
        timeoutSeconds: "Timeout, seconds", fontFamily: "Font", fontSize: "Font size", padding: "Padding", restartPolicy: "Automatic restart",
        manifest: "Trusted manifest", providers: "Providers", layouts: "Declared layouts", settings: "Settings",
        key: "Key", type: "Type", value: "Value", id: "ID", label: "Label", sizing: "Sizing"})
    Layout.fillWidth: true
    spacing: Theme.scaledSpacing(6)
    onRuleChanged: { if (rule.type !== "number" && rule.type !== "integer") scalarError = ""; }
    function resetInputState() {
        scalarError = "";
        if (controlLoader.item && controlLoader.item.inputText !== undefined)
            controlLoader.item.inputText = value === undefined || value === null ? "" : String(value);
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(10)
        Label {
            Layout.preferredWidth: root.width < 360 ? 84 : 114
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: Theme.scaledSpacing(10)
            text: root.label
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
        Loader {
            id: controlLoader
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            sourceComponent: root.rule.enum ? choice : root.rule.type === "boolean" ? toggle
                : root.rule.type === "null" ? nullValue : root.fieldName === "text" || root.fieldName === "value" && root.rule.type === "string" ? note : scalar
        }
    }
    Component {
        id: choice
        BloxComboBox {
            objectName: root.controlName
            model: root.rule.enum || []
            currentIndex: model.indexOf(root.value)
            onActivated: (index, value) => root.edited(value)
        }
    }
    Component {
        id: toggle
        BloxCheckBox { objectName: root.controlName; checked: root.value === true; onToggled: value => root.edited(value) }
    }
    Component {
        id: scalar
        BloxTextField {
            id: field
            property string inputText: root.value === undefined || root.value === null ? "" : String(root.value)
            objectName: root.controlName
            text: inputText
            onEditorFocusedChanged: {
                if (!editorFocused && !root.scalarError)
                    inputText = root.value === undefined || root.value === null ? "" : String(root.value);
            }
            onVisibleChanged: {
                if (visible && !root.scalarError)
                    inputText = root.value === undefined || root.value === null ? "" : String(root.value);
            }
            Connections {
                target: root
                function onValueChanged() {
                    if (!field.editorFocused || !field.visible)
                        field.inputText = root.value === undefined || root.value === null ? "" : String(root.value);
                }
            }
            onTextEdited: value => {
                inputText = value;
                const numeric = root.rule.type === "number" || root.rule.type === "integer";
                if (numeric && (!value.trim() || !Number.isFinite(Number(value)))) {
                    root.scalarError = "Enter a finite number for " + root.label.toLowerCase() + ".";
                    return;
                }
                root.scalarError = "";
                root.edited(numeric ? Number(value) : value);
            }
        }
    }
    Component {
        id: nullValue
        Label { objectName: root.controlName; text: "Null"; color: Theme.muted; font.family: Theme.bodyFontFamily }
    }
    Component {
        id: note
        ScrollView {
            implicitHeight: root.fieldName === "text" ? 120 : 84
            clip: true
            contentWidth: availableWidth
            TextArea {
                objectName: root.controlName
                text: root.value === undefined ? "" : String(root.value)
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                background: Rectangle { color: Theme.background; radius: Theme.scaledRadius(6); border.color: parent.activeFocus ? Theme.blue : Theme.border }
                onTextEdited: root.edited(text)
            }
        }
    }
}
