import QtQuick
import QtQuick.Window
import QtTest
import qs.modules
import qs.shared

TestCase {
    id: test
    name: "SettingsWidgetDataSafety"
    when: windowShown
    property var window: null
    property var catalogue: null
    property var schema: null
    property var validationCases: []
    property var validationRegistry: ({example: {layouts:["native","fit"], providers:["clock"]}})
    SettingsWidgetController { id: validator; host: window ? window.controller : null }
    SignalSpy { id: clickSpy; signalName: "clicked" }
    Component {
        id: fixture
        Window {
            id: host
            width: 800
            height: 640
            visible: true
            property var widgetCatalogue: test.catalogue
            property var widgetSchema: test.schema
            property var widgetRegistry: test.validationRegistry
            property bool mutationProtected: false
            property bool applyingSettingsDraft: false
            property bool rejectStage: false
            property var staged: ({schemaVersion:1, widgets:[]})
            property alias controller: controller
            property alias modal: modal
            function focusModal() { modal.forceActiveFocus(); modal.focusInitial(); }
            SettingsThemeEditorController {
                id: controller
                host: host
                widgetProfileProvider: function() { return host.staged; }
                widgetProfileWriter: function(profile) {
                    if (host.rejectStage) return false;
                    host.staged = profile;
                    return true;
                }
            }
            SettingsEditorModal { id: modal; controller: controller; anchors.fill: parent }
        }
    }
    function read(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        verify(request.responseText.length > 0, "Missing or empty test fixture: " + path);
        return JSON.parse(request.responseText);
    }
    function expandValidationCases(data) {
        // The focused runner supplies its full generated array. Standalone runs use compact recipes.
        if (Array.isArray(data)) return data;
        compare(data.version, 1);
        return data.cases.map(sample => {
            const widget = plain(data.bases[sample.kind]);
            for (const change of sample.changes) {
                let parent = widget;
                for (const key of change.path.slice(0, -1)) parent = parent[key];
                let value = change.value;
                if (change.keyText !== undefined) {
                    value = Object.create(null);
                    setData(value, change.keyText.repeat(change.repeat), plain(change.value));
                } else if (change.text !== undefined) {
                    value = (change.prefix || "") + change.text.repeat(change.repeat);
                }
                setData(parent, change.path[change.path.length - 1], value);
            }
            return {name:sample.name, widget:widget, backendValid:sample.backendValid, formatCase:sample.formatCase};
        });
    }
    function initTestCase() {
        failOnWarning(/.*/);
        catalogue = read("../../widgets/catalogue.json");
        schema = read("../../widgets/schema/profile.schema.json");
        validationCases = expandValidationCases(read("validation-cases.json"));
        verify(validationCases.length > 0, "Validation fixture must contain cases");
        const names = new Set();
        for (const sample of validationCases) {
            verify(typeof sample.name === "string" && sample.name.length > 0);
            verify(!names.has(sample.name), "Duplicate validation case: " + sample.name);
            names.add(sample.name);
            compare(typeof sample.backendValid, "boolean", sample.name + " has a Python expectation");
        }
        // Supply registry declarations for schema boundary IDs without changing production trust.
        const registry = Object.create(null);
        setData(registry, "example", {layouts:["native","fit"], providers:["clock"]});
        for (const sample of validationCases) {
            if (sample.widget.kind === "qml") setData(registry, sample.widget.settings.manifest, registry.example);
        }
        validationRegistry = registry;
    }
    function init() {
        window = fixture.createObject(test);
        verify(window);
        window.controller.candidate = {id:"fixture", widgets:{schemaVersion:1,widgets:[]}};
        window.controller.openWidgetEditor(-1);
        window.requestActivate();
        wait(10);
    }
    function cleanup() { window.close(); window.destroy(); window = null; wait(0); }
    function item(name) { const result = findChild(window.modal, name); verify(result, name); return result; }
    function flow() { return item("widget-editor"); }
    function tab(name) { click("widget-tab-" + name); }
    function reveal(control) {
        wait(5);
        const scroll = item("widget-editor-scroll");
        const point = control.mapToItem(scroll.contentItem.contentItem, 0, 0);
        scroll.contentItem.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.availableHeight, point.y));
        wait(0);
    }
    function click(name) {
        const control = item(name);
        verify(control.visible, name + " visible");
        verify(control.enabled, name + " enabled");
        if (!name.startsWith("widget-tab-") && name !== "widget-save-button") reveal(control);
        wait(5);
        clickSpy.target = null;
        clickSpy.signalName = typeof control.clicked === "function" ? "clicked" : "toggled";
        clickSpy.target = control;
        clickSpy.clear();
        mouseClick(control, control.width / 2, control.height / 2, Qt.LeftButton, Qt.NoModifier, 1);
        wait(0);
        compare(clickSpy.count, 1, name + " receives the pointer click");
    }
    function edit(name, text) {
        const control = item(name);
        verify(control.visible, name + " visible");
        reveal(control);
        if (typeof control.focusEditor === "function") control.focusEditor(true);
        else { control.forceActiveFocus(); control.selectAll(); }
        keyClick(Qt.Key_Backspace);
        for (const character of text) keyClick(character);
        wait(0);
        compare(control.text, text, name + " keeps every typed character");
        verify(control.editorFocused || control.activeFocus, name + " keeps focus");
    }
    function choose(name, index) {
        const control = item(name);
        reveal(control);
        control.forceActiveFocus();
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Home);
        // BloxComboBox exposes the popup highlight through arrow keys.
        keyClick(Qt.Key_Up);
        for (let i = 0; i < control.model.length; ++i) keyClick(Qt.Key_Up);
        for (let i = 0; i < index; ++i) keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        tryCompare(control, "currentIndex", index, 500, name);
        if (control.popup) tryVerify(() => !control.popup.visible, 500, name + " popup closes");
    }
    function kind(kind) { choose("widgetKind", catalogue.widgets.findIndex(entry => entry.kind === kind)); }
    function save() { verify(item("widget-save-button").enabled, window.controller.widgetDraftError || flow().inputError); click("widget-save-button"); tryCompare(window.controller, "modalKind", ""); }
    function plain(value) { return JSON.parse(JSON.stringify(value)); }
    function setData(object, key, value) {
        Object.defineProperty(object, key, {value: value, enumerable: true, writable: true, configurable: true});
    }
    function canonical(value) {
        if (Array.isArray(value)) return value.map(canonical);
        if (value !== null && typeof value === "object") {
            const result = Object.create(null);
            Object.keys(value).sort().forEach(key => setData(result, key, canonical(value[key])));
            return result;
        }
        return value;
    }
    function assertJson(actual, expected) { compare(JSON.stringify(canonical(plain(actual))), JSON.stringify(canonical(plain(expected)))); }
    function qmlSettings(value) {
        kind("qml"); choose("widgetManifest", 0);
        window.controller.updateWidgetOption("settings", value);
        click("widget-qml-settings");
        return item("widget-setting-settings-add").parent;
    }
    function selectKey(editor, key) {
        const index = editor.keys.indexOf(key);
        verify(index >= 0, "own entry " + key);
        editor.select(index); wait(0);
    }
    function openKey(editor, key) { selectKey(editor, key); click("widget-setting-settings-open"); }
    function saveReopen(expected) {
        const profile = plain(window.controller.widgetDraft);
        save();
        assertJson(window.staged.widgets[0], profile);
        assertJson(window.staged.widgets[0].settings.settings, expected);
        window.controller.openWidgetEditor(0); wait(30);
        assertJson(window.controller.widgetDraft.settings.settings, expected);
    }
    function test_special_keys_save_and_reopen_data() {
        const rows = [];
        for (const key of ["__proto__", "constructor", "prototype", "0", "01", "hasOwnProperty", "toString"])
            for (const location of ["root", "nested", "array"]) rows.push({tag: key + "-" + location, key: key, location: location});
        return rows;
    }
    function test_special_keys_save_and_reopen(data) {
        const branch = JSON.parse('{"sibling":12,"constructor":{"keep":"constructor"},"prototype":{"keep":"prototype"},"__proto__":{"keep":"proto"}}');
        setData(branch, data.key, {safe: true, sibling: [false, null, "keep"]});
        const original = data.location === "root" ? branch : data.location === "nested"
            ? {outer: branch, sibling: {keep: true}} : {outer: [null, branch, {keep: true}], sibling: 12};
        const expected = plain(original);
        const expectedBranch = data.location === "root" ? expected : data.location === "nested" ? expected.outer : expected.outer[1];
        expectedBranch[data.key].safe = false;
        const editor = qmlSettings(original);
        if (data.location !== "root") openKey(editor, "outer");
        if (data.location === "array") { editor.select(1); click("widget-setting-settings-open"); }
        openKey(editor, data.key); selectKey(editor, "safe");
        click("widget-setting-settings-value");
        assertJson(window.controller.widgetDraft.settings.settings, expected);
        compare(Object.prototype.safe, undefined);
        compare(Object.prototype.keep, undefined);
        saveReopen(expected);
    }
    function test_special_key_replace_rename_add_remove_and_array_move() {
        const expected = JSON.parse('{"__proto__":true,"constructor":"keep","prototype":["one","two"],"sibling":12}');
        const editor = qmlSettings(expected);
        selectKey(editor, "__proto__"); click("widget-setting-settings-value"); expected.__proto__ = false;
        assertJson(window.controller.widgetDraft.settings.settings, expected);
        click("widget-setting-settings-back"); selectKey(editor, "constructor");
        edit("widget-setting-settings-key", "__proto__");
        compare(item("widget-save-button").enabled, false);
        edit("widget-setting-settings-key", "renamed");
        setData(expected, "renamed", expected.constructor); delete expected.constructor;
        click("widget-setting-settings-back"); click("widget-setting-settings-add");
        edit("widget-setting-settings-key", "constructor");
        setData(expected, "constructor", "");
        edit("widget-setting-settings-value", "new value"); expected.constructor = "new value";
        click("widget-setting-settings-remove"); delete expected.constructor;
        selectKey(editor, "__proto__"); click("widget-setting-settings-remove"); delete expected.__proto__;
        click("widget-setting-settings-add"); edit("widget-setting-settings-key", "__proto__");
        edit("widget-setting-settings-value", "literal"); setData(expected, "__proto__", "literal");
        click("widget-setting-settings-back"); openKey(editor, "prototype");
        editor.select(0); editor.move(1); expected.prototype = ["two", "one"];
        assertJson(window.controller.widgetDraft.settings.settings, expected);
        compare(Object.getPrototypeOf(plain(window.controller.widgetDraft.settings.settings)), Object.prototype);
        saveReopen(expected);
    }
    function test_special_keys_container_types() {
        const expected = JSON.parse('{"__proto__":true,"constructor":true,"prototype":true,"sibling":12}');
        const editor = qmlSettings(expected);
        for (const key of ["__proto__", "constructor", "prototype"]) {
            selectKey(editor, key);
            for (const type of ["String", "Number", "Null", "Object", "Array", "Boolean"]) {
                choose("widget-setting-settings-type", editor.types.indexOf(type));
                setData(expected, key, type === "Object" ? {} : type === "Array" ? [] : type === "Null" ? null
                    : type === "Number" ? 0 : type === "Boolean" ? false : "");
                assertJson(window.controller.widgetDraft.settings.settings, expected);
            }
            click("widget-setting-settings-back");
        }
        saveReopen(expected);
    }
    function test_combined_special_key_path_remains_json() {
        const expected = JSON.parse('{"__proto__":{"constructor":{"prototype":[null,{"__proto__":{"polluted":false,"sibling":12},"keep":true}]},"keep":true},"sibling":12}');
        const editor = qmlSettings(expected);
        for (const key of ["__proto__", "constructor", "prototype"]) openKey(editor, key);
        editor.select(1); click("widget-setting-settings-open");
        openKey(editor, "__proto__"); selectKey(editor, "polluted");
        click("widget-setting-settings-value");
        expected.__proto__.constructor.prototype[1].__proto__.polluted = true;
        assertJson(window.controller.widgetDraft.settings.settings, expected);
        compare(Object.prototype.polluted, undefined);
        compare(({}).polluted, undefined);
        saveReopen(expected);
    }
    function test_workspace_quotes_ranges_save_reopen() {
        tab("display"); choose("widgetWorkspaceMode", 1);
        const ids = [2, "desk,work", "2", "special:notes", -3, "say \"hi\", here", "C:\\desk,work", "tail\\", "__proto__"];
        edit("widgetWorkspaceIds", flow().workspaceIdsText(ids));
        assertJson(window.controller.widgetDraft.workspaces.ids, ids);
        edit("widgetWorkspaceRanges", "-9--5, -2-0, 4-6");
        assertJson(window.controller.widgetDraft.workspaces.ranges, [[-9,-5],[-2,0],[4,6]]);
        const namesFirst = ["desk,work", -3, "2", "", "  spaced  ", "tab\tcomma,", "line\ncomma,"];
        // Empty names are invalid schema values, but the formatter must still round-trip them exactly.
        flow().editWorkspaceIds(flow().workspaceIdsText(namesFirst));
        assertJson(window.controller.widgetDraft.workspaces.ids, namesFirst);
        compare(item("widget-save-button").enabled, false);
        for (const invalid of ['2,,3', '2,', ',2', '2, "unfinished', '2, "bad\\q"', '2, "name"junk']) {
            flow().editWorkspaceIds(invalid);
            compare(item("widget-save-button").enabled, false, invalid);
        }
        for (const values of [["desk,work", 2, "2"], ids]) {
            flow().editWorkspaceIds(flow().workspaceIdsText(values));
            assertJson(window.controller.widgetDraft.workspaces.ids, values);
        }
        edit("widgetWorkspaceRanges", "6-4"); compare(item("widget-save-button").enabled, false);
        edit("widgetWorkspaceRanges", "-9--5, -2-0, 4-6");
        const expected = plain(window.controller.widgetDraft);
        save(); assertJson(window.staged.widgets[0], expected);
        window.controller.openWidgetEditor(0); wait(30); tab("display");
        compare(item("widgetWorkspaceIds").text, flow().workspaceIdsText(ids));
        compare(item("widgetWorkspaceRanges").text, "-9--5, -2-0, 4-6");
        flow().editWorkspaceIds(item("widgetWorkspaceIds").text);
        assertJson(window.controller.widgetDraft, expected);
    }
    function test_unicode_real_save_and_reopen() {
        const emoji = "\ud83d\ude00";
        const key = emoji.repeat(128);
        const value = {}; setData(value, key, emoji.repeat(16384)); value.sibling = 12;
        qmlSettings(value);
        window.controller.updateWidgetDraft({workspaces: {mode: "include", ids: [emoji.repeat(65), emoji.repeat(128)], ranges: []}});
        compare(window.controller.widgetDraftError, "");
        saveReopen(value);
        window.controller.dismissModal(); tryCompare(window.controller, "modalKind", ""); kindAfterNewCommand();
        const args = ["producer", emoji.repeat(3000)];
        window.controller.updateWidgetOption("command", args);
        compare(window.controller.widgetDraftError, ""); save();
        assertJson(window.staged.widgets[0].settings.command, args);
        window.controller.openWidgetEditor(0); wait(30);
        assertJson(window.controller.widgetDraft.settings.command, args);
    }
    function kindAfterNewCommand() { window.controller.openWidgetEditor(-1); wait(30); kind("command"); }
    function test_unicode_minimum_and_invalid_utf8() {
        const emoji = "\ud83d\ude00";
        compare(validator.fieldError(emoji, {type:"string", minLength:2}, "value").length > 0, true);
        compare(validator.fieldError(emoji, {type:"string", minLength:1, maxLength:1}, "value"), "");
        for (const invalid of ["\ud800", "\udfff", "\ud800x", "\ud800\ud800", "x\udfff", emoji + "\ud800"]) {
            verify(validator.fieldError(invalid, {type:"string", "x-blox-maxUtf8Bytes":16384}, "value").length > 0);
        }
    }
    function test_differential_authoritative_boundaries() {
        const results = [];
        const mismatches = [];
        let accepted = 0;
        let rejected = 0;
        for (const sample of validationCases) {
            const error = validator.profileError([sample.widget]);
            results.push({name:sample.name, backendValid:sample.backendValid, localValid:!error, error:error});
            if (sample.formatCase) { compare(!error, true); compare(sample.backendValid, false); }
            else {
                if (sample.backendValid) accepted++; else rejected++;
                if (!error !== sample.backendValid) mismatches.push(sample.name + ": " + error + "; Python: " + sample.backendError);
            }
        }
        console.log("DIFFERENTIAL " + JSON.stringify(results));
        compare(results.length, validationCases.length);
        verify(accepted > 0 && rejected > 0, "Exercise both accepted and rejected schema boundaries");
        compare(mismatches, [], "QV4 and authoritative Python validation must agree outside backend formats");
    }
}
