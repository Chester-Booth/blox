import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared

ColumnLayout {
    id: root
    required property var value
    property string prefix: "settings"
    property var path: []
    property int selectedIndex: -1
    property var selectedName: null
    property int editingSession: 0
    readonly property bool hasSelection: array ? selectedIndex >= 0 : selectedName !== null
    readonly property bool focused: hasSelection || path.length > 0
    property string validationError: ""
    readonly property var plainValue: value === undefined ? {} : JSON.parse(JSON.stringify(value))
    readonly property var container: path.reduce((current, key) => current[key], plainValue)
    readonly property bool array: Array.isArray(container)
    readonly property var keys: container && typeof container === "object" ? Object.keys(container) : []
    readonly property string selectedKey: array ? String(selectedIndex) : selectedName === null ? "" : selectedName
    readonly property var selectedValue: hasSelection && Object.prototype.hasOwnProperty.call(container, selectedKey) ? container[selectedKey] : undefined
    readonly property var types: ["String", "Number", "Boolean", "Null", "Object", "Array"]
    signal edited(var value)
    spacing: Theme.scaledSpacing(8)
    onEditingSessionChanged: { path = []; clearSelection(); validationError = ""; }

    function clearSelection() { selectedIndex = -1; selectedName = null; }
    function select(index) {
        if (array) selectedIndex = index;
        else selectedName = keys[index];
    }

    function typeOf(value) {
        value = value === undefined ? undefined : JSON.parse(JSON.stringify(value));
        return value === null ? "Null" : Array.isArray(value) ? "Array" : typeof value === "object" ? "Object"
            : typeof value === "number" ? "Number" : typeof value === "boolean" ? "Boolean" : "String";
    }
    // JSON keys are data, including __proto__. Never invoke an inherited setter.
    function setEntry(container, key, value) {
        Object.defineProperty(container, key, {value: value, writable: true, enumerable: true, configurable: true});
    }
    // QV4's var signal conversion also needs data-only objects at every depth.
    function copyData(value) {
        if (Array.isArray(value)) return value.map(copyData);
        if (value !== null && typeof value === "object") {
            const result = Object.create(null);
            Object.keys(value).forEach(key => setEntry(result, key, copyData(value[key])));
            return result;
        }
        return value;
    }
    function changeContainer(next) {
        const result = JSON.parse(JSON.stringify(value));
        if (!path.length) { edited(copyData(next)); return; }
        const parent = path.slice(0, -1).reduce((current, key) => current[key], result);
        setEntry(parent, path[path.length - 1], next);
        edited(copyData(result));
    }
    function replace(value) {
        const next = JSON.parse(JSON.stringify(container));
        setEntry(next, selectedKey, value);
        changeContainer(next);
    }
    function rename(key) {
        if (key !== selectedKey && keys.indexOf(key) >= 0) {
            validationError = "Setting keys must be unique.";
            return;
        }
        validationError = "";
        const next = Object.create(null);
        keys.forEach(existing => setEntry(next, existing === selectedKey ? key : existing, container[existing]));
        changeContainer(next);
        selectedName = key;
    }
    function add() {
        const index = keys.length;
        if (array) {
            changeContainer(container.concat([""]));
            selectedIndex = index;
        }
        else {
            const next = JSON.parse(JSON.stringify(container));
            let key = "entry";
            for (let index = 2; keys.indexOf(key) >= 0; ++index) key = "entry-" + index;
            setEntry(next, key, "");
            changeContainer(next);
            // Follow the key because QML can reorder object keys across bindings.
            selectedName = key;
        }
        validationError = "";
    }
    function remove() {
        const next = JSON.parse(JSON.stringify(container));
        if (array) next.splice(selectedIndex, 1);
        else delete next[selectedKey];
        clearSelection();
        validationError = "";
        changeContainer(next);
    }
    function move(delta) {
        const other = selectedIndex + delta;
        if (!array || other < 0 || other >= keys.length) return;
        const next = container.slice();
        [next[selectedIndex], next[other]] = [next[other], next[selectedIndex]];
        changeContainer(next);
        selectedIndex = other;
    }
    BloxButton {
        objectName: root.prefix + "-back"
        visible: root.hasSelection || root.path.length > 0
        iconName: "caret-left"
        text: root.path.length ? String(root.path[root.path.length - 1]) : "Settings"
        onClicked: {
            if (root.hasSelection) root.clearSelection();
            else root.path = root.path.slice(0, -1);
            root.validationError = "";
        }
    }
    Repeater {
        model: !root.hasSelection ? root.keys.length : 0
        delegate: SettingsWidgetSummary {
            required property int index
            objectName: root.prefix + "-entry-" + index
            label: root.keys[index]
            summary: root.typeOf(root.container[root.keys[index]])
            onClicked: root.select(index)
        }
    }
    ColumnLayout {
        visible: root.hasSelection
        Layout.fillWidth: true
        SettingsWidgetScalarField {
            visible: !root.array
            fieldName: "key"
            controlName: root.prefix + "-key"
            rule: ({type: "string"})
            value: root.selectedKey
            onEdited: value => root.rename(value)
        }
        SettingsWidgetScalarField {
            fieldName: "type"
            controlName: root.prefix + "-type"
            rule: ({enum: root.types})
            value: root.typeOf(root.selectedValue)
            onEdited: value => {
                const defaults = {String: "", Number: 0, Boolean: false, Null: null, Object: {}, Array: []};
                root.replace(defaults[value]);
            }
        }
        Loader {
            Layout.fillWidth: true
            active: root.hasSelection
            sourceComponent: ["Object", "Array"].indexOf(root.typeOf(root.selectedValue)) >= 0 ? nested : scalar
        }
        RowLayout {
            Layout.fillWidth: true
            BloxButton { visible: root.array; compact: true; iconName: "caret-left"; enabled: root.selectedIndex > 0; Accessible.name: "Move earlier"; onClicked: root.move(-1) }
            BloxButton { visible: root.array; compact: true; iconName: "caret-right"; enabled: root.selectedIndex < root.keys.length - 1; Accessible.name: "Move later"; onClicked: root.move(1) }
            BloxButton { objectName: root.prefix + "-remove"; text: "Remove entry"; iconName: "minus-square"; onClicked: root.remove() }
        }
    }
    BloxButton { objectName: root.prefix + "-add"; visible: !root.hasSelection; text: "Add entry"; iconName: "plus"; onClicked: root.add() }
    Component {
        id: scalar
        SettingsWidgetScalarField {
            fieldName: "value"
            controlName: root.prefix + "-value"
            rule: ({type: root.typeOf(root.selectedValue).toLowerCase()})
            value: root.selectedValue
            onEdited: value => root.replace(value)
        }
    }
    Component {
        id: nested
        SettingsWidgetSummary {
            objectName: root.prefix + "-open"
            label: "Open entries"
            summary: String(root.selectedValue ? Object.keys(root.selectedValue).length : 0)
            onClicked: {
                const path = root.path.concat([root.selectedKey]);
                root.clearSelection();
                root.path = path;
                root.validationError = "";
            }
        }
    }
}
