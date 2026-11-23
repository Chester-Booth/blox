import QtQuick
import QtQuick.Layouts
import qs.shared

ColumnLayout {
    id: root
    required property var value
    property string prefix: "settings.items"
    property int selectedIndex: -1
    property int editingSession: 0
    readonly property bool focused: selected !== null
    readonly property var entries: {
        const plain = value === undefined ? [] : JSON.parse(JSON.stringify(value));
        return Array.isArray(plain) ? plain : [];
    }
    readonly property var selected: selectedIndex >= 0 && selectedIndex < entries.length ? entries[selectedIndex] : null
    signal edited(var value)
    spacing: Theme.scaledSpacing(8)
    onEditingSessionChanged: selectedIndex = -1

    function replace(key, value) {
        const next = JSON.parse(JSON.stringify(entries));
        next[selectedIndex][key] = value;
        edited(next);
    }
    function move(delta) {
        const next = entries.slice();
        const other = selectedIndex + delta;
        [next[selectedIndex], next[other]] = [next[other], next[selectedIndex]];
        edited(next);
        selectedIndex = other;
    }
    BloxButton { objectName: root.prefix + "-back"; visible: root.selected !== null; iconName: "caret-left"; text: "Shortcuts"; onClicked: root.selectedIndex = -1 }
    Repeater {
        model: root.selected ? 0 : root.entries.length
        delegate: SettingsWidgetSummary {
            required property int index
            objectName: root.prefix + "-entry-" + index
            label: root.entries[index].label || root.entries[index].id
            summary: (root.entries[index].command || []).join(" ")
            onClicked: root.selectedIndex = index
        }
    }
    ColumnLayout {
        visible: root.selected !== null
        Layout.fillWidth: true
        SettingsWidgetScalarField { fieldName: "id"; controlName: root.prefix + "-id"; rule: ({type:"string"}); value: root.selected ? root.selected.id : ""; onEdited: value => root.replace("id", value) }
        SettingsWidgetScalarField { fieldName: "label"; controlName: root.prefix + "-label"; rule: ({type:"string"}); value: root.selected ? root.selected.label : ""; onEdited: value => root.replace("label", value) }
        SettingsWidgetListEditor { prefix: root.prefix + ".command"; value: root.selected ? root.selected.command : []; onEdited: value => root.replace("command", value) }
        RowLayout {
            BloxButton { compact: true; iconName: "caret-left"; enabled: root.selectedIndex > 0; Accessible.name: "Move shortcut earlier"; onClicked: root.move(-1) }
            BloxButton { compact: true; iconName: "caret-right"; enabled: root.selectedIndex < root.entries.length - 1; Accessible.name: "Move shortcut later"; onClicked: root.move(1) }
            BloxButton {
                objectName: root.prefix + "-remove"
                text: "Remove"
                iconName: "minus-square"
                onClicked: {
                    const next = root.entries.slice();
                    next.splice(root.selectedIndex, 1);
                    root.selectedIndex = -1;
                    root.edited(next);
                }
            }
        }
    }
    BloxButton {
        visible: !root.selected
        objectName: root.prefix + "-add"
        text: "Add shortcut"
        iconName: "plus"
        onClicked: {
            const index = root.entries.length;
            let id = "shortcut";
            for (let index = 2; root.entries.some(entry => entry.id === id); ++index) id = "shortcut-" + index;
            root.edited(root.entries.concat([{id: id, label: "Shortcut", command: [""]}]));
            root.selectedIndex = index;
        }
    }
}
