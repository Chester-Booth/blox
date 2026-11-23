import QtQuick
import QtQuick.Window
import QtTest
import qs.shared
import "../../shell/modules" as Modules
import "../../shell/services" as Services
import "../../widgets/qml/Blox/Widgets" as Widgets

TestCase {
    id: testCase
    name: "NotesColdSettings"
    when: windowShown
    property var fixtureWindow: null

    QtObject {
        id: provider
        signal snapshotReady(string consumerId, var envelope)
        function subscribe(id, kind, options, generation) {
            Qt.callLater(() => provider.snapshotReady(id, {generation: generation, revision: 1,
                observedMonotonicMs: 1, state: "ready", value: {}, error: ""}));
        }
        function unsubscribe(id) {}
    }
    Component {
        id: fixture
        Window {
            width: 1000
            height: 760
            visible: true
            property alias settings: settingsSurface
            property alias settingsOwner: settingsOwner
            property alias notes: notes
            property alias actions: actions
            Services.SettingsController { id: settingsOwner; enableColdRecovery: false }
            Widgets.WidgetHost {
                id: notes
                widget: Theme.widgetItems[0]
                provider: provider
                placementBounds: Qt.rect(0, 0, 1000, 760)
                onActionRequested: (action, payload) => actions.dispatch(widget.id, action, payload)
            }
            Services.WidgetActionController {
                id: actions
                settingsWindow: settingsSurface
            }
            Modules.SettingsWindow {
                id: settingsSurface
                anchors.fill: parent
                settingsController: settingsOwner
            }
        }
    }
    function document(path) {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl(path), false);
        request.send();
        return JSON.parse(request.responseText);
    }
    function profile() {
        return {schemaVersion: 1, widgets: [{id: "cold-note", kind: "notes", name: "Notes", enabled: true,
            placement: {anchor: "top-left", x: 0, y: 0, width: 360, height: 300},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.5, scrollbars: "auto"}, fullscreen: {enabled: true, mode: "native"},
            settings: {title: "Note", text: "Cold start"}}]};
    }
    function editButton(item) {
        return findChild(item, "notes-edit-button");
    }
    function initTestCase() { failOnWarning(/.*/); }
    function prepareEditor(sourceProfile) {
        const settings = fixtureWindow.settings;
        settings.loadWidgetMetadata("catalogue", JSON.stringify(document("../../widgets/catalogue.json")));
        settings.loadWidgetMetadata("schema", JSON.stringify(document("../../widgets/schema/profile.schema.json")));
        const editor = settings.themeEditorController;
        const candidate = document("fixtures/resolved-sparse-theme.json");
        candidate.id = Theme.activeThemeId;
        candidate.widgets = sourceProfile || profile();
        // Match the theme API, which releases busy before assigning its candidate and ID.
        editor.busy = false;
        editor.candidate = candidate;
        editor.selectedId = Theme.activeThemeId;
        return editor;
    }
    function finishSettingsRead(widgets) {
        const loaded = document("../fixtures/settings-owner-results.json").success;
        loaded.data.settings = {widgets: widgets, targets: {}};
        fixtureWindow.settingsOwner.finish(loaded);
        fixtureWindow.settings.pollSettingsRead();
        Services.SettingsApplyController.busy = false;
    }
    function failSettingsRead() {
        const failure = document("../fixtures/settings-owner-results.json").validationFailure;
        failure.data.settings = null;
        fixtureWindow.settingsOwner.finish(failure);
        fixtureWindow.settings.pollSettingsRead();
        Services.SettingsApplyController.busy = false;
    }
    function init() {
        Services.SettingsApplyController.busy = false;
        Theme.widgetItems = profile().widgets;
        fixtureWindow = fixture.createObject(testCase);
        verify(fixtureWindow);
        tryCompare(fixtureWindow.notes, "phase", "visible");
        compare(fixtureWindow.settingsOwner.settings, null);
        verify(!fixtureWindow.settings.windowOpen);
    }
    function cleanup() {
        fixtureWindow.close();
        fixtureWindow.destroy();
        fixtureWindow = null;
        Theme.widgetItems = [];
        Services.SettingsApplyController.busy = false;
        wait(0);
    }
    function test_first_note_click_opens_settings_then_waits_for_hydration() {
        const settings = fixtureWindow.settings;
        const button = editButton(fixtureWindow.notes.view);
        verify(button);
        mouseClick(button);
        compare(fixtureWindow.actions.lastResult.code, "ok");
        verify(settings.windowOpen);
        compare(settings.pendingWidgetEditorId, "cold-note");
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);

        const editor = prepareEditor();
        wait(0);
        compare(settings.pendingWidgetEditorId, "cold-note");
        verify(editor.modalKind !== "widget");

        finishSettingsRead(profile());
        tryCompare(editor, "modalKind", "widget");
        compare(settings.pendingWidgetEditorId, "");
        compare(editor.widgetEditIndex, 0);
        compare(editor.widgetDraft.id, "cold-note");
        compare(editor.widgetDraft.settings.text, "Cold start");
    }
    function test_unknown_widget_does_not_open_cold_settings() {
        verify(!fixtureWindow.settings.openWidgetEditor("missing"));
        verify(!fixtureWindow.settings.windowOpen);
        compare(fixtureWindow.settings.pendingWidgetEditorId, "");
        compare(fixtureWindow.settingsOwner.settings, null);
        verify(!fixtureWindow.settingsOwner.busy);
    }
    function test_theme_and_get_order_preserves_current_persisted_note_data() {
        return [
            {tag: "cold-theme-first", cached: false, themeFirst: true},
            {tag: "cached-theme-first", cached: true, themeFirst: true},
            {tag: "get-first", cached: false, themeFirst: false}
        ];
    }
    function test_theme_and_get_order_preserves_current_persisted_note(data) {
        const settings = fixtureWindow.settings;
        if (data.cached) {
            const cached = document("../fixtures/settings-owner-results.json").success;
            cached.data.settings = {widgets: profile(), targets: {}};
            fixtureWindow.settingsOwner.finish(cached);
        }
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const stale = profile();
        stale.widgets[0].settings.text = "Old theme note";
        let editor = data.themeFirst ? prepareEditor(stale) : null;
        const current = profile();
        current.widgets[0].settings.text = "Current persisted note";
        finishSettingsRead(current);
        if (!data.themeFirst) editor = prepareEditor(stale);
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetDraft.settings.text, "Current persisted note");
    }
    function test_get_completion_preserves_explicit_note_draft() {
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const editor = prepareEditor();
        const edited = profile();
        edited.widgets[0].settings.text = "Unapplied note edit";
        Services.SettingsApplyController.busy = false;
        verify(settings.writeSettingsValue("widgets", edited));
        finishSettingsRead(profile());
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetDraft.settings.text, "Unapplied note edit");
        verify(settings.draftUserEdited);
    }
    function test_delayed_stage_preserves_explicit_bar_draft() {
        const cached = document("../fixtures/settings-owner-results.json").success;
        cached.data.settings = {widgets: profile(), targets: {}};
        fixtureWindow.settingsOwner.finish(cached);
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const editor = prepareEditor();
        const edited = editor.candidate.shell.bar.position === "bottom" ? "top" : "bottom";
        Services.SettingsApplyController.busy = false;
        verify(settings.writeSettingsValue("bar.layout.position", edited));
        finishSettingsRead(profile());
        compare(settings.draftSettingsWrites["bar.layout.position"], edited);
    }
    function test_inactive_theme_without_widgets_uses_current_settings() {
        const cached = document("../fixtures/settings-owner-results.json").success;
        cached.data.settings = {widgets: profile(), targets: {}};
        fixtureWindow.settingsOwner.finish(cached);
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        settings.loadWidgetMetadata("catalogue", JSON.stringify(document("../../widgets/catalogue.json")));
        settings.loadWidgetMetadata("schema", JSON.stringify(document("../../widgets/schema/profile.schema.json")));
        const editor = settings.themeEditorController;
        const resolved = document("fixtures/resolved-sparse-theme.json");
        resolved.id = "inactive-without-widgets";
        resolved.widgets = {schemaVersion: 1, widgets: []};
        editor.busy = false;
        editor.candidate = settings.prepareEditorSource(resolved, {id: resolved.id});
        editor.sourceTheme = {id: resolved.id};
        editor.selectedId = resolved.id;
        const current = profile();
        current.widgets[0].settings.text = "Current persisted note";
        finishSettingsRead(current);
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetDraft.settings.text, "Current persisted note");
    }
    function test_widget_removed_during_load_cannot_edit_another_entry() {
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        compare(fixtureWindow.actions.lastResult.code, "ok");
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const editor = prepareEditor();
        finishSettingsRead({schemaVersion: 1, widgets: []});
        tryCompare(settings, "pendingWidgetEditorId", "");
        verify(editor.modalKind !== "widget");
        compare(settings.settingsFeedback, "The widget no longer exists.");
    }
    function test_failed_first_get_cancels_pending_editor() {
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const editor = prepareEditor();
        failSettingsRead();
        wait(0);
        compare(settings.pendingWidgetEditorId, "");
        verify(!settings.widgetEditorReadReady);
        compare(fixtureWindow.settingsOwner.settings, null);
        verify(editor.modalKind !== "widget");
    }
    function test_failed_refresh_cannot_edit_cached_settings_and_retry_reads_again() {
        const cached = document("../fixtures/settings-owner-results.json").success;
        cached.data.settings = {widgets: profile(), targets: {}};
        fixtureWindow.settingsOwner.finish(cached);
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const oldRequest = settings.pendingSettingsRequestId;
        const editor = prepareEditor();
        failSettingsRead();
        wait(0);
        compare(settings.pendingWidgetEditorId, "");
        verify(!settings.widgetEditorReadReady);
        verify(editor.modalKind !== "widget");

        verify(fixtureWindow.actions.dispatch("cold-note", "edit", {}).ok);
        tryVerify(() => settings.pendingSettingsRequestId.length > 0 && settings.pendingSettingsRequestId !== oldRequest);
        finishSettingsRead(profile());
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetDraft.id, "cold-note");
    }
    function test_malformed_poll_result_cancels_pending_editor() {
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const editor = prepareEditor();
        fixtureWindow.settingsOwner.busy = false;
        fixtureWindow.settingsOwner.completedResult = "Invalid result";
        settings.pollSettingsRead();
        Services.SettingsApplyController.busy = false;
        wait(0);
        compare(settings.pendingWidgetEditorId, "");
        verify(!settings.widgetEditorReadReady);
        verify(editor.modalKind !== "widget");
    }
    function test_failed_get_cancels_cached_layout_edit_and_retry_reads_again() {
        const cached = document("../fixtures/settings-owner-results.json").success;
        cached.data.settings = {widgets: profile(), targets: {}};
        fixtureWindow.settingsOwner.finish(cached);
        const settings = fixtureWindow.settings;
        verify(settings.requestWidgetLayoutEdit());
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const oldRequest = settings.pendingSettingsRequestId;
        const editor = prepareEditor();
        failSettingsRead();
        wait(0);
        verify(!settings.pendingWidgetLayoutEdit);
        verify(!settings.widgetEditorReadReady);
        verify(!settings.widgetEditing);
        verify(!editor.widgetEditModePending);

        verify(settings.requestWidgetLayoutEdit());
        tryVerify(() => settings.pendingSettingsRequestId.length > 0 && settings.pendingSettingsRequestId !== oldRequest);
        verify(!settings.widgetEditing);
        finishSettingsRead(profile());
        tryCompare(settings, "widgetEditing", true);
        verify(!settings.pendingWidgetLayoutEdit);
        verify(editor.widgetEditModePending);
    }
    function test_old_get_cannot_satisfy_close_and_reopen() {
        const settings = fixtureWindow.settings;
        mouseClick(editButton(fixtureWindow.notes.view));
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const oldRequest = settings.pendingSettingsRequestId;
        const editor = prepareEditor();
        settings.windowOpen = false;
        compare(settings.pendingWidgetEditorId, "");
        verify(fixtureWindow.actions.dispatch("cold-note", "edit", {}).ok);
        compare(settings.pendingWidgetEditorId, "cold-note");
        finishSettingsRead(profile());
        verify(!settings.widgetEditorReadReady);
        verify(editor.modalKind !== "widget");
        tryVerify(() => settings.pendingSettingsRequestId.length > 0 && settings.pendingSettingsRequestId !== oldRequest);
        const latest = profile();
        latest.widgets[0].settings.text = "Read after reopening";
        finishSettingsRead(latest);
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetDraft.settings.text, "Read after reopening");
    }
}
