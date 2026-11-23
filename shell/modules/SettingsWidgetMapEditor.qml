import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared

ColumnLayout {
    id: root
    required property var value
    property string prefix: "environment"
    property bool expanded: false
    readonly property var keys: value && typeof value === "object" && !Array.isArray(value) ? Object.keys(value) : []
    readonly property string validationError: {
        for (let i = 0; i < rows.count; ++i) {
            const row = rows.itemAt(i);
            if (row && row.keyError) return row.keyError;
        }
        return "";
    }
    signal edited(var value)
    spacing: Theme.scaledSpacing(6)
    function resetInputState() {
        for (let index = 0; index < rows.count; ++index) rows.itemAt(index).resetInputState();
    }

    function add() {
        const next = Object.assign({}, value);
        let key = "VARIABLE";
        for (let i = 2; keys.indexOf(key) >= 0; ++i) key = "VARIABLE_" + i;
        next[key] = "";
        expanded = true;
        edited(next);
    }
    function replace(index, key, text) {
        const next = Object.create(null);
        keys.forEach((existing, i) => next[i === index ? key : existing] = i === index ? text : value[existing]);
        edited(next);
    }
    RowLayout {
        Layout.fillWidth: true
        Label { Layout.preferredWidth: root.width < 360 ? 84 : 114; text: "Environment"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
        BloxButton { objectName: root.prefix + "-expand"; Layout.fillWidth: true; Layout.minimumWidth: 0; elideText: true; text: root.expanded ? "Collapse" : root.keys.length + " variables"; onClicked: root.expanded = !root.expanded }
        BloxButton { objectName: root.prefix + "-add"; compact: true; iconName: "plus"; Accessible.name: "Add environment variable"; onClicked: root.add() }
    }
    Repeater {
        id: rows
        model: root.keys.length
        delegate: ColumnLayout {
            id: row
            required property int index
            property string keyError: ""
            function resetInputState() {
                keyError = "";
                keyField.text = Qt.binding(() => root.keys[row.index] ?? "");
            }
            visible: root.expanded
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(4)
            RowLayout {
                Layout.fillWidth: true
                BloxTextField {
                    id: keyField
                    objectName: root.prefix + ".key." + row.index
                    Layout.preferredWidth: Math.max(60, root.width * 0.3)
                    Layout.minimumWidth: 0
                    text: root.keys[row.index] ?? ""
                    onTextEdited: value => {
                        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) {
                            row.keyError = "Environment names need a letter or underscore first, followed by letters, numbers or underscores.";
                            return;
                        }
                        if (value !== root.keys[row.index] && root.keys.indexOf(value) >= 0) {
                            row.keyError = "Environment names must be unique.";
                            return;
                        }
                        row.keyError = "";
                        root.replace(row.index, value, root.value[root.keys[row.index]]);
                    }
                }
                BloxTextField {
                    objectName: root.prefix + ".value." + row.index
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: String(root.value[root.keys[row.index]] ?? "")
                    onTextEdited: value => root.replace(row.index, root.keys[row.index], value)
                }
                BloxButton {
                    objectName: root.prefix + "-remove-" + row.index
                    compact: true
                    iconName: "minus-square"
                    Accessible.name: "Remove environment variable"
                    onClicked: {
                        const next = Object.assign({}, root.value);
                        delete next[root.keys[row.index]];
                        row.keyError = "";
                        root.edited(next);
                    }
                }
            }
        }
    }
}
