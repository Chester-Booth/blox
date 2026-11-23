import QtQuick
import QtQuick.Window
import QtTest
import qs.shared
import qs.services
import "../../shell/services" as Services
import "../../shell/modules" as Modules
import "../../widgets/qml/Blox/Widgets" as Widgets

TestCase {
    id: testCase
    name: "SettingsGateway"
    when: windowShown
    property var host: null

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
            property alias gateway: gateway
            property alias settingsOwner: settingsOwner
            property alias notes: notes
            property alias actions: actions
            Services.SettingsController { id: settingsOwner; enableColdRecovery: false }
            Services.SettingsGateway { id: gateway; settingsController: settingsOwner }
            Widgets.WidgetHost {
                id: notes
                widget: Theme.widgetItems[0]
                provider: provider
                placementBounds: Qt.rect(0, 0, 1000, 760)
                onActionRequested: (action, payload) => actions.dispatch(widget.id, action, payload)
            }
            Services.WidgetActionController { id: actions; settingsWindow: gateway }
            Modules.SettingsApplyReviewPage {
                // The launcher owns this page even before quick Apply is shown.
                visible: false
                windowOwner: SettingsApplyController.windowOwner
                flowState: SettingsApplyController
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
            settings: {title: "Note", text: "First gateway action"}}]};
    }
    function finishSettingsRead() {
        const loaded = document("../fixtures/settings-owner-results.json").success;
        loaded.data.settings = {widgets: profile(), targets: {gtk: {enabled: true}}};
        host.settingsOwner.finish(loaded);
    }
    function initTestCase() { failOnWarning(/.*/); }
    function init() {
        SettingsApplyController.editor = null;
        SettingsApplyController.windowOwner = null;
        SettingsApplyController.compositionProvider = null;
        SettingsApplyController.settingsProvider = null;
        SettingsApplyController.busy = false;
        SettingsApplyController.externalRequestId = "";
        SettingsApplyController.externalResult = null;
        SettingsApplyController.externalApplyResult = null;
        SettingsApplyController.selectedThemeId = "";
        SettingsApplyController.applyState = "ready";
        SettingsApplyController.journalReleased = true;
        SettingsApplyController.recoveryAvailable = false;
        SettingsApplyController.contextResetPending = false;
        SettingsApplyController.quickWindowOpen = false;
        SettingsApplyController.coldPreviewRestorePending = false;
        SettingsApplyController.coldPreviewRestored = false;
        SettingsApplyController.coldApplyPending = false;
        findChild(SettingsApplyController, "settings-apply-cold-preview").running = false;
        SettingsApplyController.operation = "status";
        Theme.widgetItems = profile().widgets;
        host = fixture.createObject(testCase);
        verify(host);
        compare(host.gateway.window, null);
        compare(SettingsApplyController.settingsProvider, host.settingsOwner);
        tryCompare(host.notes, "phase", "visible");
    }
    function cleanup() {
        SettingsApplyController.editor = null;
        SettingsApplyController.windowOwner = null;
        SettingsApplyController.compositionProvider = null;
        SettingsApplyController.settingsProvider = null;
        SettingsApplyController.busy = false;
        host.close();
        host.destroy();
        host = null;
        Theme.widgetItems = [];
        wait(0);
    }
    function endpoint() { return findChild(host.gateway, "settings-ui-ipc"); }
    function test_cold_status_and_close_do_not_construct_window() {
        const ipc = endpoint();
        verify(ipc);
        compare(ipc.target, "settingsUi");
        compare(JSON.parse(ipc.status()), {open: false, category: "review", page: "landing", section: "", theme: ""});
        compare(ipc.close(), "closed");
        compare(host.gateway.window, null);
        compare(SettingsApplyController.windowOwner, null);
        compare(SettingsApplyController.editor, null);
        verify(!host.settingsOwner.busy);
    }
    function test_ipc_open_close_and_toggle_retain_same_owner() {
        const ipc = endpoint();
        compare(ipc.open(), "open");
        const settings = host.gateway.window;
        verify(settings);
        compare(SettingsApplyController.windowOwner, settings);
        compare(SettingsApplyController.editor, settings.themeEditorController);
        compare(SettingsApplyController.compositionProvider, settings.compositionProviderController);
        verify(JSON.parse(ipc.status()).open);
        compare(ipc.close(), "closed");
        compare(host.gateway.window, settings);
        compare(ipc.toggle(), "open");
        compare(host.gateway.window, settings);
        compare(ipc.toggle(), "closed");
    }
    function test_first_note_button_creates_ui_and_waits_for_current_get() {
        const button = findChild(host.notes.view, "notes-edit-button");
        verify(button);
        mouseClick(button);
        compare(host.actions.lastResult.code, "ok");
        const settings = host.gateway.window;
        verify(settings);
        verify(settings.windowOpen);
        compare(settings.pendingWidgetEditorId, "cold-note");
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        settings.loadWidgetMetadata("catalogue", JSON.stringify(document("../../widgets/catalogue.json")));
        settings.loadWidgetMetadata("schema", JSON.stringify(document("../../widgets/schema/profile.schema.json")));
        const editor = settings.themeEditorController;
        const candidate = document("fixtures/resolved-sparse-theme.json");
        candidate.id = Theme.activeThemeId;
        candidate.widgets = profile();
        editor.busy = false;
        editor.candidate = candidate;
        editor.selectedId = Theme.activeThemeId;
        wait(0);
        verify(editor.modalKind !== "widget");
        finishSettingsRead();
        settings.pollSettingsRead();
        SettingsApplyController.busy = false;
        tryCompare(editor, "modalKind", "widget");
        compare(editor.widgetDraft.id, "cold-note");
        compare(editor.widgetDraft.settings.text, "First gateway action");
    }
    function test_dirty_close_keeps_draft_and_loaded_owner() {
        compare(host.gateway.openWindow(), "open");
        const settings = host.gateway.window;
        settings.draftUserEdited = true;
        settings.draftUserWrites = {notes: "Unsaved draft"};
        compare(host.gateway.closeWindow(), "confirmation-required");
        compare(host.gateway.window, settings);
        verify(settings.windowOpen);
        compare(settings.draftUserWrites.notes, "Unsaved draft");
    }
    function test_external_apply_cold_read_does_not_construct_ui() {
        const response = SettingsApplyController.beginExternal("external-theme", "external-theme");
        compare(response.code, "pending");
        compare(host.gateway.window, null);
        verify(host.settingsOwner.busy);
        finishSettingsRead();
        tryCompare(SettingsApplyController, "coldPreviewRestorePending", true);
        compare(SettingsApplyController.operation, "status");
        verify(SettingsApplyController.previewPreparing);
        findChild(SettingsApplyController, "settings-apply-cold-preview").finish(0, 0);
        tryCompare(SettingsApplyController, "operation", "review");
        verify(SettingsApplyController.busy);
        compare(SettingsApplyController.pollExternal(response.data.requestId).code, "pending");
        compare(host.gateway.window, null);
        compare(SettingsApplyController.windowOwner, null);
        compare(SettingsApplyController.editor, null);
    }
    function test_first_open_during_external_apply_preserves_request() {
        finishSettingsRead();
        const response = SettingsApplyController.beginExternal("external-theme", "external-reference");
        compare(response.code, "pending");
        verify(SettingsApplyController.coldPreviewRestorePending);
        findChild(SettingsApplyController, "settings-apply-cold-preview").finish(0, 0);
        tryCompare(SettingsApplyController, "operation", "review");
        compare(SettingsApplyController.operation, "review");
        compare(host.gateway.window, null);
        compare(endpoint().open(), "open");
        verify(host.gateway.window);
        compare(SettingsApplyController.selectedThemeId, "external-theme");
        compare(SettingsApplyController.externalThemeReference, "external-reference");
        compare(SettingsApplyController.externalRequestId, response.data.requestId);
        compare(SettingsApplyController.operation, "review");
        verify(SettingsApplyController.busy);
        wait(0);
        compare(SettingsApplyController.selectedThemeId, "external-theme");
        compare(SettingsApplyController.operation, "review");
        compare(SettingsApplyController.pollExternal(response.data.requestId).code, "pending");
    }
    function test_open_during_cold_restore_waits_for_ui_read_then_resumes() {
        finishSettingsRead();
        const response = SettingsApplyController.beginExternal("external-theme", "external-reference");
        verify(SettingsApplyController.coldPreviewRestorePending);
        compare(endpoint().open(), "open");
        const settings = host.gateway.window;
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        findChild(SettingsApplyController, "settings-apply-cold-preview").finish(0, 0);
        wait(0);
        compare(SettingsApplyController.operation, "status");
        verify(SettingsApplyController.coldApplyPending);
        // Opening Settings must not let a competing status request replace
        // the external request while its preview restoration is pending.
        verify(!SettingsApplyController.busy);
        verify(!SettingsApplyController.request("status"));
        finishSettingsRead();
        settings.pollSettingsRead();
        const editor = settings.themeEditorController;
        editor.busy = false;
        tryCompare(editor, "settingsApplyPreviewPending", true);
        editor.settingsApplyPreviewPending = false;
        editor.settingsApplyPreviewPrepared(true, "");
        tryCompare(SettingsApplyController, "operation", "review");
        verify(SettingsApplyController.busy);
        compare(SettingsApplyController.externalThemeReference, "external-reference");
        compare(SettingsApplyController.pollExternal(response.data.requestId).code, "pending");
    }
    function test_create_from_wallpaper_forwards_first_action() {
        compare(endpoint().createFromWallpaper(), "opening");
        verify(host.gateway.window);
        verify(host.gateway.window.windowOpen);
        compare(host.gateway.window.pendingThemeAction, "new-wallpaper");
    }
    function test_layout_edit_signal_creates_window_and_preserves_pending_read() {
        Theme.widgetLayoutEditRequested();
        const settings = host.gateway.window;
        verify(settings);
        verify(settings.windowOpen);
        verify(settings.pendingWidgetLayoutEdit);
        tryVerify(() => settings.pendingSettingsRequestId.length > 0);
        const openingGeneration = settings.settingsOpeningGeneration;
        const requestId = settings.pendingSettingsRequestId;
        Theme.widgetLayoutEditRequested();
        compare(host.gateway.window, settings);
        compare(settings.settingsOpeningGeneration, openingGeneration);
        compare(settings.pendingSettingsRequestId, requestId);
        verify(settings.pendingWidgetLayoutEdit);
    }
    function test_first_launcher_quick_apply_creates_its_callback_owner() {
        finishSettingsRead();
        SettingsApplyController.quickApply({id: "quick-theme", name: "Quick theme"});
        verify(host.gateway.window);
        compare(SettingsApplyController.windowOwner, host.gateway.window);
        verify(!host.gateway.window.windowOpen);
        compare(SettingsApplyController.selectedThemeId, "quick-theme");
        compare(SettingsApplyController.selectedThemeName, "Quick theme");
        const editor = host.gateway.window.themeEditorController;
        verify(editor.settingsApplyPreviewPending);
        editor.settingsApplyPreviewPending = false;
        editor.settingsApplyPreviewPrepared(true, "");
        tryCompare(SettingsApplyController, "busy", true);
        compare(SettingsApplyController.operation, "review");
    }
}
