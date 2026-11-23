import QtQuick
import QtQuick.Window
import QtTest
import qs.modules
import qs.shared

TestCase {
    id: test
    name: "SettingsWidgetCompact"
    when: windowShown
    property var window: null
    property var catalogue: null
    property var schema: null
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
            property var widgetRegistry: ({example: {layouts:["native","fit"], providers:["clock"]}})
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
        return JSON.parse(request.responseText);
    }
    function initTestCase() {
        failOnWarning(/.*/);
        catalogue = read("../../widgets/catalogue.json");
        schema = read("../../widgets/schema/profile.schema.json");
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
    function test_real_tabs_command_actions_and_staging_roundtrip() {
        kind("command");
        edit("widget-setting-command.0", "producer");
        click("widget-setting-command-add");
        edit("widget-setting-command.1", "literal;arg");
        click("widget-setting-command-add");
        edit("widget-setting-command.2", "two words");
        click("widget-setting-command-earlier-2");
        compare(window.controller.widgetDraft.settings.command, ["producer","two words","literal;arg"]);
        click("widget-content-advanced");
        edit("widget-setting-intervalSeconds", "71.25");
        edit("widget-setting-workingDirectory", "/tmp/example");
        click("widget-setting-environment-add");
        edit("widget-setting-environment.key.0", "LANG");
        edit("widget-setting-environment.value.0", "en_GB.UTF-8");
        tab("actions");
        click("widget-action-left");
        choose("settings.actions.left.kind", 1);
        edit("settings.actions.left.command.0", "action");
        click("settings.actions.left.command-add");
        edit("settings.actions.left.command.1", "next");
        click("settings.actions.left-advanced");
        edit("settings.actions.left.timeoutSeconds", "10");
        click("settings.actions.left.environment-add");
        edit("settings.actions.left.environment.key.0", "EXAMPLE");
        edit("settings.actions.left.environment.value.0", "literal");
        click("widget-action-back");
        click("widget-action-right");
        choose("settings.actions.right.kind", 2);
        edit("settings.actions.right.command.0", "kitty");
        click("settings.actions.right.command-add");
        edit("settings.actions.right.command.1", "--class");
        compare(Object.keys(window.controller.widgetDraft.settings.actions.right).sort(), ["command","kind"]);
        tab("appearance");
        choose("widgetPresentation", 1);
        edit("widget-setting-fontSize", "17");
        tab("display");
        choose("widgetWorkspaceMode", 1);
        edit("widgetWorkspaceIds", '2, "2", special:notes');
        edit("widgetWorkspaceRanges", "4-6, -5--1");
        tab("placement");
        edit("widgetPlacement-width", "425");
        choose("widgetPlacement-sizing", 1);
        const expected = JSON.parse(JSON.stringify(window.controller.widgetDraft));
        save();
        compare(window.staged.widgets[0], expected);
        compare(window.controller.candidate.widgets.widgets.length, 0);
        window.controller.openWidgetEditor(0);
        wait(0);
        compare(window.controller.widgetDraft, expected);
        compare(item("widget-setting-command.0").text, "producer");
        tab("actions"); click("widget-action-left");
        compare(item("settings.actions.left.command.0").text, "action");
        tab("placement"); compare(item("widgetPlacement-sizing").currentIndex, 1);
    }
    function test_validation_guard_checks_current_nested_draft_and_local_input() {
        kind("command"); edit("widget-setting-command.0", "producer");
        tab("actions"); click("widget-action-left"); choose("settings.actions.left.kind", 1);
        edit("settings.actions.left.command.0", "action");
        click("settings.actions.left-advanced");
        edit("settings.actions.left.timeoutSeconds", "121");
        compare(item("widget-save-button").enabled, false);
        verify(!window.controller.saveWidgetDraft());
        compare(window.staged.widgets.length, 0);
        edit("settings.actions.left.timeoutSeconds", "120");
        compare(item("widget-save-button").enabled, true);
        edit("settings.actions.left.timeoutSeconds", "-");
        compare(item("widget-save-button").enabled, false);
        edit("settings.actions.left.timeoutSeconds", "5");
        click("settings.actions.left.environment-add");
        edit("settings.actions.left.environment.key.0", "BLOX_WIDGET_ACTION_CONTEXT");
        compare(item("widget-save-button").enabled, false);
        edit("settings.actions.left.environment.key.0", "EXAMPLE");
        click("settings.actions.left.environment-add");
        edit("settings.actions.left.environment.key.1", "EXAMPLE");
        compare(item("widget-save-button").enabled, false);
        edit("settings.actions.left.environment.key.1", "SECOND");
        compare(item("widget-save-button").enabled, true);
        choose("settings.actions.left.kind", 2);
        compare(Object.keys(window.controller.widgetDraft.settings.actions.left).sort(), ["command","kind"]);
        compare(window.controller.widgetDraft.settings.actions.left.command, ["action"]);
        choose("settings.actions.left.kind", 1);
        compare(window.controller.widgetDraft.settings.actions.left.timeoutSeconds, 5);
        compare(window.controller.widgetDraft.settings.actions.left.environment, {EXAMPLE:"",SECOND:""});
        choose("settings.actions.left.kind", 0);
        compare(window.controller.widgetDraft.settings.actions.left, null);
        compare(item("widget-save-button").enabled, true);
        window.rejectStage = true;
        click("widget-save-button");
        compare(window.controller.modalKind, "widget");
        compare(window.staged.widgets.length, 0);
        window.rejectStage = false;
        // A new edit refreshes the staging error, as in the existing model.
        window.controller.updateWidgetDraft({name:"Producer"});
        save();
    }
    function test_kind_changes_keep_common_values_and_each_kind_draft() {
        kind("terminal"); edit("widget-setting-command.0", "terminal");
        click("widget-content-advanced"); choose("widget-setting-restartPolicy", 1);
        edit("widget-setting-columns", "120");
        tab("display"); choose("widgetWorkspaceMode", 1); edit("widgetWorkspaceIds", "special:desk");
        tab("content"); flow().contentAdvanced = false; wait(0);
        kind("clock");
        compare(item("widget-tab-actions").enabled, false);
        compare(window.controller.widgetDraft.workspaces.ids, ["special:desk"]);
        compare(window.controller.widgetDraft.settings.showSeconds, false);
        kind("terminal");
        compare(window.controller.widgetDraft.settings.command, ["terminal"]);
        click("widget-content-advanced");
        compare(item("widget-setting-columns").text, "120");
        compare(item("widget-setting-restartPolicy").currentIndex, 1);
        save();
    }
    function test_cancelled_local_errors_do_not_block_a_new_session() {
        kind("command"); edit("widget-setting-command.0", "producer");
        window.controller.updateWidgetOption("environment", {FIRST:"one",SECOND:"two"});
        save();
        window.controller.openWidgetEditor(0); wait(30);
        click("widget-content-advanced");
        edit("widget-setting-intervalSeconds", "-");
        compare(item("widget-save-button").enabled, false);
        window.controller.dismissModal(); tryCompare(window.controller,"modalKind","");
        window.controller.openWidgetEditor(0); wait(30);
        compare(item("widget-save-button").enabled, true);
        compare(item("widget-setting-intervalSeconds").text, "60");
        click("widget-content-advanced"); click("widget-setting-environment-expand");
        edit("widget-setting-environment.key.1", "FIRST");
        compare(item("widget-save-button").enabled, false);
        window.controller.dismissModal(); tryCompare(window.controller,"modalKind","");
        window.controller.openWidgetEditor(0); wait(30);
        compare(item("widget-save-button").enabled, true);
        compare(item("widget-setting-environment.key.1").text, "SECOND");
        compare(window.controller.widgetDraft.settings.environment, {FIRST:"one",SECOND:"two"});
    }
    function test_shortcuts_and_nested_typed_qml_editors() {
        kind("shortcuts");
        click("widget-setting-items-add");
        edit("widget-setting-items-id", "terminal");
        edit("widget-setting-items-label", "Terminal");
        edit("widget-setting-items.command.0", "kitty");
        click("widget-setting-items.command-add");
        edit("widget-setting-items.command.1", "--class");
        click("widget-setting-items-back");
        click("widget-setting-items-add");
        edit("widget-setting-items-id", "browser");
        edit("widget-setting-items-label", "Browser");
        edit("widget-setting-items.command.0", "firefox");
        compare(window.controller.widgetDraft.settings.items[0].command, ["kitty","--class"]);
        const shortcuts = JSON.parse(JSON.stringify(window.controller.widgetDraft.settings.items));
        click("widget-setting-items-back");
        kind("qml"); choose("widgetManifest", 0);
        click("widget-qml-settings");
        click("widget-setting-settings-add");
        edit("widget-setting-settings-key", "palette");
        choose("widget-setting-settings-type", 4);
        click("widget-setting-settings-open");
        click("widget-setting-settings-add");
        edit("widget-setting-settings-key", "accent");
        edit("widget-setting-settings-value", "blue");
        compare(window.controller.widgetDraft.settings.settings.palette.accent, "blue");
        tab("appearance"); tab("content");
        compare(item("widget-setting-settings-value").text, "blue");
        click("widget-setting-settings-back");
        click("widget-setting-settings-back");
        click("widget-setting-settings-add");
        edit("widget-setting-settings-key", "0");
        edit("widget-setting-settings-key", "values");
        choose("widget-setting-settings-type", 5);
        click("widget-setting-settings-open");
        click("widget-setting-settings-add");
        choose("widget-setting-settings-type", 1);
        edit("widget-setting-settings-value", "42.5");
        click("widget-setting-settings-back");
        click("widget-setting-settings-add");
        choose("widget-setting-settings-type", 2);
        click("widget-setting-settings-value");
        click("widget-setting-settings-back");
        click("widget-setting-settings-add");
        choose("widget-setting-settings-type", 3);
        save();
        const settings = window.staged.widgets[0].settings.settings;
        compare(Object.keys(settings).sort(), ["palette","values"]);
        compare(settings.palette.accent, "blue");
        compare(settings.values, [42.5,true,null]);
        window.controller.openWidgetEditor(0); wait(0);
        kind("shortcuts");
        // A new session starts from catalogue defaults, not the previous editor session.
        compare(window.controller.widgetDraft.settings.items, []);
        window.controller.updateWidgetOption("items", shortcuts);
        save();
        compare(window.staged.widgets[0].settings.items, shortcuts);
    }
    function test_all_kind_fields_exist_and_defaults_roundtrip() {
        for (const entry of catalogue.widgets) {
            kind(entry.kind);
            if (entry.kind === "weather") { window.controller.updateWidgetOption("latitude",51.5); window.controller.updateWidgetOption("longitude",-0.1); }
            if (entry.kind === "command" || entry.kind === "terminal") edit("widget-setting-command.0", entry.kind);
            if (entry.kind === "qml") choose("widgetManifest",0);
            const properties = schema.$defs[entry.kind + "Settings"].properties;
            for (const key of Object.keys(properties)) {
                if (["actions","manifest"].indexOf(key) >= 0) continue;
                const name = "widget-setting-" + key;
                verify(findChild(window.modal, name) || findChild(window.modal, name + ".0") || findChild(window.modal, name + "-add"), entry.kind + "." + key);
            }
            save();
            window.controller.openWidgetEditor(0); wait(0);
            compare(window.controller.widgetDraft.settings, window.staged.widgets[0].settings);
        }
    }
    function test_tab_keyboard_navigation_and_compact_frame() {
        const card = item("settings-modal-card");
        compare(card.width, 620); compare(card.height, 440);
        const first = item("widget-tab-content"); first.forceActiveFocus();
        keyClick(Qt.Key_Right); compare(flow().currentTab, 2);
        keyClick(Qt.Key_End); compare(flow().currentTab, 4);
        keyClick(Qt.Key_Home); compare(flow().currentTab, 0);
        kind("command");
        first.forceActiveFocus(); keyClick(Qt.Key_Right); compare(flow().currentTab, 1);
        keyClick(Qt.Key_Left); compare(flow().currentTab, 0);
        window.width = 400; window.height = 340; wait(0);
        compare(card.width, 360); compare(card.height, 300);
        const tabs = item("widget-tabs");
        verify(tabs.contentWidth > tabs.width);
        item("widget-tab-content").forceActiveFocus(); keyClick(Qt.Key_End);
        compare(flow().currentTab, 4);
        verify(tabs.contentX > 0);
        wait(20);
        const scroll = item("widget-editor-scroll");
        const scrollbar = item("widget-editor-scrollbar");
        verify(scrollbar.visible);
        verify(scrollbar.x >= scroll.width - scrollbar.width - 1);
        const start = scrollbar.height * scrollbar.size / 2;
        mouseDrag(scrollbar, scrollbar.width / 2, start, 0, scrollbar.height - start - 2, Qt.LeftButton, Qt.NoModifier, 10);
        verify(scroll.contentItem.contentY > 0);
        const saveButton = item("widget-save-button");
        const title = item("settings-modal-title");
        verify(title.mapToItem(window.contentItem, 0, 0).y >= 0);
        verify(saveButton.mapToItem(window.contentItem, 0, saveButton.height).y <= window.height);
        edit("widgetPlacement-height", "640");
        compare(window.controller.widgetDraft.placement.height, 640);
    }
    function test_other_modal_sizing_stays_unchanged() {
        const card = item("settings-modal-card");
        window.controller.showModal("rename"); wait(0);
        compare(card.width, 500);
        verify(card.height < 440);
        window.controller.showModal("guide"); wait(0);
        compare(card.width, 500);
        compare(card.height, Math.min(window.height - 80,620));
    }
}
