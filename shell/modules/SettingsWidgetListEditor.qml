import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared

ColumnLayout {
    id: root
    required property var value
    property string prefix: "command"
    property bool command: true
    property bool expanded: false
    readonly property var entries: {
        const plain = value === undefined ? [] : JSON.parse(JSON.stringify(value));
        return Array.isArray(plain) ? plain : [];
    }
    signal edited(var value)
    spacing: Theme.scaledSpacing(6)

    function replace(index, text) {
        const next = entries.slice();
        next[index] = text;
        edited(next);
    }
    function remove(index) {
        const next = entries.slice();
        next.splice(index, 1);
        edited(next);
    }
    function move(index, delta) {
        const next = entries.slice();
        const other = index + delta;
        if (other < (command ? 1 : 0) || other >= next.length) return;
        [next[index], next[other]] = [next[other], next[index]];
        edited(next);
    }
    RowLayout {
        visible: root.command
        Layout.fillWidth: true
        Label { Layout.preferredWidth: root.width < 360 ? 84 : 114; text: "Command"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
        BloxTextField {
            objectName: root.prefix + ".0"
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.entries.length ? String(root.entries[0]) : ""
            onTextEdited: value => root.replace(0, value)
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Label { Layout.preferredWidth: root.width < 360 ? 84 : 114; text: root.command ? "Arguments" : "Interfaces"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
        BloxButton {
            objectName: root.prefix + "-expand"
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            elideText: true
            text: root.expanded ? "Collapse" : Math.max(0, root.entries.length - (root.command ? 1 : 0)) + (root.command ? " arguments" : " interfaces")
            onClicked: root.expanded = !root.expanded
        }
        BloxButton {
            objectName: root.prefix + "-add"
            compact: true
            iconName: "plus"
            Accessible.name: root.command ? "Add argument" : "Add interface"
            onClicked: {
                root.expanded = true;
                root.edited((root.command && !root.entries.length ? [""] : root.entries).concat([""]));
            }
        }
    }
    Repeater {
        // A count model keeps the focused TextInput alive while its value changes.
        model: root.expanded ? Math.max(0, root.entries.length - (root.command ? 1 : 0)) : 0
        delegate: ColumnLayout {
            id: entry
            required property int index
            readonly property int entryIndex: index + (root.command ? 1 : 0)
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(4)
            RowLayout {
                Layout.fillWidth: true
                BloxTextField {
                    objectName: root.prefix + "." + entry.entryIndex
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: String(root.entries[entry.entryIndex] ?? "")
                    onTextEdited: value => root.replace(entry.entryIndex, value)
                }
                BloxButton { objectName: root.prefix + "-earlier-" + entry.entryIndex; compact: true; iconName: "caret-left"; enabled: entry.index > 0; Accessible.name: "Move earlier"; onClicked: root.move(entry.entryIndex, -1) }
                BloxButton { objectName: root.prefix + "-later-" + entry.entryIndex; compact: true; iconName: "caret-right"; enabled: entry.entryIndex < root.entries.length - 1; Accessible.name: "Move later"; onClicked: root.move(entry.entryIndex, 1) }
                BloxButton { objectName: root.prefix + "-remove-" + entry.entryIndex; compact: true; iconName: "minus-square"; Accessible.name: "Remove entry"; onClicked: root.remove(entry.entryIndex) }
            }
        }
    }
}
