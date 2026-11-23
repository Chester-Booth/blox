import QtQuick
import QtTest
import qs.services
import qs.shared

TestCase {
    name: "SettingsApplyController"
    QtObject {
        id: fakeEditor
        property bool dirty: true
        property bool busy: false
        property bool candidateValid: true
        property string selectedId: "edited-theme"
        property string errorMessage: ""
        property int saves: 0
        property bool previewReady: true
        property bool settingsApplyPreviewPending: false
        property int previewReleases: 0
        signal settingsApplyPreviewPrepared(bool successful, string message)
        function prepareForSettingsApply() {
            settingsApplyPreviewPending = !previewReady;
            return previewReady;
        }
        function releaseSettingsApplyPreview() { previewReleases++; }
        function saveCandidate(after) { saves++; busy = true; }
    }
    QtObject {
        id: fakeSettings
        property bool busy: false
        property bool recovering: false
        property int readCalls: 0
        property var readResult: null
        function begin(operation, request) {
            readCalls++; busy = true;
            return JSON.stringify({version: 1, ok: true, code: "pending", message: "", data: {requestId: "cold-read"}});
        }
        function poll(requestId) {
            return JSON.stringify(busy ? {version: 1, ok: true, code: "pending", message: "", data: {requestId: requestId}} : readResult);
        }
        property var settings: ({targets: {gtk: {enabled: true}}})
    }
    QtObject {
        id: fakeWindow
        property int settingsPreparations: 0
        property bool rejectPreparation: false
        property bool settingsMutationPending: false
        property bool applyingSettingsDraft: false
        property bool refreshMakesSettingsBusy: false
        function refreshAfterApply() { if (refreshMakesSettingsBusy) fakeSettings.busy = true; }
        function prepareSettingsForApply() {
            settingsPreparations++;
            if (rejectPreparation) {
                SettingsApplyController.abortPreparation("Settings revision conflict");
                return false;
            }
            return true;
        }
    }
    function cleanup() {
        SettingsApplyController.editor = null;
        SettingsApplyController.settingsProvider = null;
    }
    function init() {
        SettingsApplyController.coldPreviewRestorePending = false;
        SettingsApplyController.coldPreviewRestored = false;
        SettingsApplyController.coldApplyPending = false;
        findChild(SettingsApplyController, "settings-apply-cold-preview").running = false;
        fakeEditor.previewReady = true;
        fakeEditor.settingsApplyPreviewPending = false;
        fakeEditor.previewReleases = 0;
        fakeWindow.settingsPreparations = 0;
        fakeWindow.rejectPreparation = false;
        fakeWindow.refreshMakesSettingsBusy = false;
        fakeWindow.settingsMutationPending = false;
        fakeWindow.applyingSettingsDraft = false;
        SettingsApplyController.busy = false;
        SettingsApplyController.externalRequestId = "";
        SettingsApplyController.externalResult = null;
        SettingsApplyController.externalApplyResult = null;
        SettingsApplyController.windowOwner = null;
        SettingsApplyController.operation = "apply";
        SettingsApplyController.applyState = "ready";
        SettingsApplyController.failureMessage = "";
        SettingsApplyController.journalReleased = true;
        SettingsApplyController.transactionPhase = "none";
        SettingsApplyController.contextResetPending = false;
        fakeSettings.busy = false; fakeSettings.recovering = false; fakeSettings.readCalls = 0;
        fakeSettings.settings = {targets: {gtk: {enabled: true}}};
        fakeSettings.readResult = {version: 1, ok: true, code: "ok", message: "", data: {}};
        SettingsApplyController.recoveryAvailable = false;
        SettingsApplyController.actions = {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false};
    }
    function test_null_editor_restore_failure_blocks_review_and_retry_restores_again() {
        SettingsApplyController.editor = null;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.operation = "status";
        const started = SettingsApplyController.beginExternal("cold-theme", "/isolated/cold-theme.json");
        compare(started.code, "pending");
        const restore = findChild(SettingsApplyController, "settings-apply-cold-preview");
        verify(restore.running);
        compare(restore.command[restore.command.length - 1], "restore");
        verify(SettingsApplyController.previewPreparing);
        verify(!SettingsApplyController.busy);
        compare(SettingsApplyController.operation, "status");
        restore.stderr.text = "Compositor restore failed";
        restore.stderr.streamFinished();
        restore.finish(1, 0);
        compare(SettingsApplyController.applyState, "failure-before-write");
        compare(SettingsApplyController.failureMessage, "Compositor restore failed");
        compare(SettingsApplyController.pollExternal(started.data.requestId).code, "failed");
        verify(!SettingsApplyController.coldApplyPending);
        compare(SettingsApplyController.operation, "status");
        SettingsApplyController.retryApply();
        verify(restore.running);
        verify(SettingsApplyController.previewPreparing);
        restore.finish(0, 0);
        tryCompare(SettingsApplyController, "operation", "review");
        verify(SettingsApplyController.busy);
    }
    function test_null_editor_failed_exec_does_not_leave_apply_pending() {
        SettingsApplyController.editor = null;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.operation = "status";
        const started = SettingsApplyController.beginExternal("cold-theme", "cold-theme");
        const restore = findChild(SettingsApplyController, "settings-apply-cold-preview");
        verify(restore.running);
        restore.running = false;
        tryCompare(SettingsApplyController, "coldPreviewRestorePending", false);
        compare(SettingsApplyController.pollExternal(started.data.requestId).code, "failed");
        compare(SettingsApplyController.operation, "status");
        verify(!SettingsApplyController.previewPreparing);
        verify(!SettingsApplyController.coldApplyPending);
    }
    function test_null_editor_restore_resumes_after_new_owner_read_finishes() {
        SettingsApplyController.editor = null;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.operation = "status";
        const started = SettingsApplyController.beginExternal("cold-theme", "cold-reference");
        SettingsApplyController.windowOwner = fakeWindow;
        fakeWindow.settingsMutationPending = true;
        findChild(SettingsApplyController, "settings-apply-cold-preview").finish(0, 0);
        wait(0);
        compare(SettingsApplyController.operation, "status");
        verify(SettingsApplyController.coldApplyPending);
        fakeWindow.settingsMutationPending = false;
        tryCompare(SettingsApplyController, "operation", "review");
        verify(!SettingsApplyController.coldApplyPending);
        compare(SettingsApplyController.externalThemeReference, "cold-reference");
        compare(SettingsApplyController.pollExternal(started.data.requestId).code, "pending");
    }
    function test_retry_restored_failure_runs_full_review_and_retained_failure_blocks_it() {
        fakeEditor.dirty = false; fakeEditor.busy = false;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.applyState = "failure-activate-restored";
        verify(SettingsApplyController.canRetryApply);
        SettingsApplyController.retryApply();
        compare(SettingsApplyController.operation, "review");
        SettingsApplyController.busy = false;
        SettingsApplyController.operation = "apply";
        SettingsApplyController.journalReleased = false;
        SettingsApplyController.recoveryAvailable = true;
        verify(!SettingsApplyController.canRetryApply);
        SettingsApplyController.retryApply();
        compare(SettingsApplyController.operation, "apply");
    }
    function test_edit_resets_released_failure_and_old_progress() {
        SettingsApplyController.applyState = "failure-before-write";
        SettingsApplyController.failureMessage = "Previous source failed";
        SettingsApplyController.applyProgress = 100;
        SettingsApplyController.applyTargets = [{target: "gtk", state: "failed"}];
        verify(SettingsApplyController.contextChanged());
        compare(SettingsApplyController.applyState, "ready");
        compare(SettingsApplyController.failureMessage, "");
        compare(SettingsApplyController.applyProgress, 0);
        compare(SettingsApplyController.applyTargets.length, 0);
    }
    function test_switch_acknowledges_complete_receipt_before_reset() {
        SettingsApplyController.journalReleased = false;
        SettingsApplyController.transactionPhase = "complete";
        SettingsApplyController.applyState = "success-restart";
        SettingsApplyController.reloadAfterFinish = true;
        verify(SettingsApplyController.contextChanged());
        verify(!SettingsApplyController.reloadAfterFinish);
        compare(SettingsApplyController.operation, "finish");
        verify(!SettingsApplyController.journalReleased);
        SettingsApplyController.busy = false;
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {code: "finished", journalReleased: true}});
        compare(SettingsApplyController.applyState, "ready");
        verify(SettingsApplyController.journalReleased);
        compare(SettingsApplyController.transactionPhase, "none");
    }
    function test_edit_cannot_forget_partial_or_recovery_transaction() {
        SettingsApplyController.journalReleased = false;
        SettingsApplyController.transactionPhase = "partial";
        SettingsApplyController.applyState = "failure-target-retained";
        verify(!SettingsApplyController.contextChanged());
        compare(SettingsApplyController.applyState, "failure-target-retained");
        verify(!SettingsApplyController.journalReleased);
    }
    function test_superseded_partial_requires_explicit_acknowledgement() {
        SettingsApplyController.operation = "status";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {
            phase: "partial", themeId: "old-theme", observationConflict: true,
            recoveryAvailable: false, targets: {kitty: {state: "failure", message: "Failed"}},
            actions: {retryFailedTargets: [], rollBack: false, keepSuccessfulChanges: false,
                cancel: false, abandonSuperseded: true}
        }});
        verify(!SettingsApplyController.contextChanged());
        SettingsApplyController.finishApply();
        compare(SettingsApplyController.operation, "status");
        verify(!SettingsApplyController.journalReleased);
        SettingsApplyController.abandonSupersededApply();
        compare(SettingsApplyController.operation, "abandon");
        SettingsApplyController.busy = false;
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {code: "abandoned", journalReleased: true}});
        verify(SettingsApplyController.journalReleased);
        compare(SettingsApplyController.applyState, "ready");
    }
    function test_partial_acknowledgement_cannot_release_an_unconfirmed_receipt() {
        SettingsApplyController.journalReleased = false;
        SettingsApplyController.transactionPhase = "partial";
        SettingsApplyController.abandonSupersededApply();
        compare(SettingsApplyController.operation, "apply");
        SettingsApplyController.operation = "abandon";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {code: "abandoned", journalReleased: false}});
        verify(!SettingsApplyController.journalReleased);
        compare(SettingsApplyController.transactionPhase, "partial");
    }
    function test_completed_reset_waits_for_initial_settings_read() {
        SettingsApplyController.settingsProvider = fakeSettings;
        fakeSettings.busy = true;
        SettingsApplyController.journalReleased = false;
        SettingsApplyController.transactionPhase = "complete";
        verify(!SettingsApplyController.contextChanged());
        verify(SettingsApplyController.contextResetPending);
        fakeSettings.busy = false;
        tryCompare(SettingsApplyController, "operation", "finish");
        verify(!SettingsApplyController.contextResetPending);
    }
    function test_status_can_check_retained_journal_during_settings_read() {
        SettingsApplyController.settingsProvider = fakeSettings;
        fakeSettings.busy = true;
        verify(SettingsApplyController.request("status"));
        compare(SettingsApplyController.operation, "status");
    }
    function test_stale_complete_status_acknowledges_without_rollback() {
        SettingsApplyController.operation = "status";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {
            phase: "complete", themeId: "old-theme", observationConflict: true,
            recoveryAvailable: false, targets: {}, actions: {rollBack: false}
        }});
        tryCompare(SettingsApplyController, "operation", "finish");
        verify(!SettingsApplyController.recoveryAvailable);
        verify(!SettingsApplyController.journalReleased);
    }
    function test_apply_waits_for_preview_restore_before_saving_settings_and_source() {
        fakeEditor.dirty = true; fakeEditor.busy = false; fakeEditor.candidateValid = true;
        fakeEditor.saves = 0; fakeEditor.previewReady = false;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.windowOwner = fakeWindow;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.startApply();
        verify(SettingsApplyController.previewPreparing);
        compare(fakeWindow.settingsPreparations, 0);
        compare(fakeEditor.saves, 0);
        fakeEditor.previewReady = true;
        fakeEditor.settingsApplyPreviewPending = false;
        fakeEditor.settingsApplyPreviewPrepared(true, "");
        tryCompare(fakeEditor, "saves", 1);
        compare(fakeWindow.settingsPreparations, 1);
        compare(SettingsApplyController.operation, "apply");
        // Keep the save timer parked until test cleanup detaches this editor.
        fakeEditor.busy = true;
    }
    function test_preview_restore_failure_aborts_before_any_save_or_apply() {
        fakeEditor.dirty = true; fakeEditor.busy = false; fakeEditor.candidateValid = true;
        fakeEditor.saves = 0; fakeEditor.previewReady = false;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.windowOwner = fakeWindow;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.startApply();
        fakeEditor.settingsApplyPreviewPending = false;
        fakeEditor.settingsApplyPreviewPrepared(false, "Compositor restore failed");
        compare(SettingsApplyController.applyState, "failure-before-write");
        compare(SettingsApplyController.failureMessage, "Compositor restore failed");
        compare(fakeWindow.settingsPreparations, 0);
        compare(fakeEditor.saves, 0);
        verify(!SettingsApplyController.busy);
        verify(fakeEditor.previewReleases > 0);
    }
    function test_retained_apply_does_not_resume_preview_until_released_and_done() {
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.journalReleased = false;
        SettingsApplyController.applyState = "success";
        compare(fakeEditor.previewReleases, 0);
        SettingsApplyController.applyState = "ready";
        compare(fakeEditor.previewReleases, 0);
        SettingsApplyController.journalReleased = true;
        compare(fakeEditor.previewReleases, 1);
    }
    function test_settings_commit_rejection_releases_preview_before_any_source_save() {
        fakeEditor.dirty = true; fakeEditor.busy = false; fakeEditor.candidateValid = true;
        fakeEditor.saves = 0; fakeEditor.previewReady = true;
        fakeWindow.rejectPreparation = true;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.windowOwner = fakeWindow;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.startApply();
        compare(SettingsApplyController.applyState, "failure-before-write");
        compare(SettingsApplyController.failureMessage, "Settings revision conflict");
        compare(fakeEditor.saves, 0);
        verify(fakeEditor.previewReleases > 0);
        verify(!SettingsApplyController.busy);
    }
    function test_busy_settings_do_not_acquire_a_preview_hold() {
        fakeEditor.dirty = true; fakeEditor.busy = false; fakeEditor.previewReady = false;
        fakeWindow.settingsMutationPending = true;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.windowOwner = fakeWindow;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.startApply();
        verify(!fakeEditor.settingsApplyPreviewPending);
        compare(fakeWindow.settingsPreparations, 0);
        verify(!SettingsApplyController.busy);
    }
    function test_apply_waits_for_imported_source_reload() {
        fakeEditor.dirty = false;
        fakeEditor.busy = true;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.selectedThemeId = "imported-theme";
        SettingsApplyController.startApply();
        compare(SettingsApplyController.operation, "apply");
        compare(SettingsApplyController.busy, false);
    }
    function test_apply_saves_edits_before_reviewing_the_source() {
        fakeEditor.dirty = true;
        fakeEditor.busy = false;
        fakeEditor.candidateValid = true;
        fakeEditor.saves = 0;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.startApply();
        compare(fakeEditor.saves, 1);
        compare(SettingsApplyController.operation, "apply");
        fakeEditor.dirty = false;
        fakeEditor.busy = false;
        tryCompare(SettingsApplyController, "operation", "review");
        compare(fakeEditor.saves, 1);
    }
    function test_invalid_edits_report_an_error_without_saving_or_applying() {
        fakeEditor.dirty = true;
        fakeEditor.busy = false;
        fakeEditor.candidateValid = false;
        fakeEditor.errorMessage = "Invalid colour";
        fakeEditor.saves = 0;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.selectedThemeId = fakeEditor.selectedId;
        SettingsApplyController.startApply();
        compare(fakeEditor.saves, 0);
        compare(SettingsApplyController.failureMessage, "Invalid colour");
    }
    function test_partial_result_keeps_backend_capabilities_and_target_states() {
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {phase: "partial", code: "partial", targets: {
            kitty: {state: "failure", message: "Socket unavailable"}, gtk: {state: "restart", message: "Restart needed"}, wallpaper: {state: "success"}
        }, actions: {retryFailedTargets: ["kitty"], keepSuccessfulChanges: true, rollBack: true, cancel: false}}});
        compare(SettingsApplyController.applyState, "failure-target-retained");
        compare(SettingsApplyController.applyTargets[0].state, "failed");
        compare(SettingsApplyController.applyTargets[1].state, "restart");
        compare(SettingsApplyController.applyTargets[2].state, "applied");
        compare(SettingsApplyController.actions.retryFailedTargets, ["kitty"]);
        verify(SettingsApplyController.actions.keepSuccessfulChanges);
        verify(!SettingsApplyController.actions.cancel);
    }
    function test_core_failure_has_no_guessed_retry_or_rollback() {
        SettingsApplyController.acceptResult({version: 1, ok: false, data: {phase: "restored", code: "core-failure", error: "Activation failed", targets: {gtk: {state: "unchanged"}}, actions: {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false}}});
        compare(SettingsApplyController.applyState, "failure-activate-restored");
        compare(SettingsApplyController.failureMessage, "Activation failed");
        verify(!SettingsApplyController.actions.rollBack);
        compare(SettingsApplyController.applyTargets[0].state, "unchanged");
    }
    function test_progress_uses_owner_events() {
        SettingsApplyController.acceptEvent({stage: "journal-durable"});
        compare(SettingsApplyController.applyStages[2].state, "active");
        SettingsApplyController.acceptEvent({stage: "core-verified"});
        compare(SettingsApplyController.applyStages[3].state, "active");
        SettingsApplyController.acceptEvent({stage: "target-result", target: "kitty", state: "failure"});
        verify(SettingsApplyController.applyTargets.some(row => row.target === "kitty" && row.state === "failed"));
    }
    function test_reload_waits_until_the_verified_journal_is_released() {
        Theme.reloadRequests = 0;
        SettingsApplyController.completeQuickshellReload();
        compare(Theme.reloadRequests, 0);
        SettingsApplyController.operation = "finish";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {code: "finished"}});
        verify(SettingsApplyController.restarting);
        compare(Theme.reloadRequests, 0);
        verify(!SettingsApplyController.reloadAfterFinish);
    }
    function test_done_after_rollback_does_not_finish_a_removed_journal() {
        SettingsApplyController.operation = "rollback";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {phase: "restored", code: "rolled-back", targets: {}, actions: {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false}}});
        verify(SettingsApplyController.journalReleased);
        SettingsApplyController.finishApply();
        compare(SettingsApplyController.applyState, "ready");
        verify(!SettingsApplyController.busy);
    }
    function test_retry_partial_and_success_remain_truthful() {
        SettingsApplyController.operation = "retry";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {phase: "partial", targets: {kitty: {state: "failure"}}}});
        compare(SettingsApplyController.applyState, "retry-failure");
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {phase: "complete", targets: {kitty: {state: "success"}}}});
        compare(SettingsApplyController.applyState, "retry-success");
    }
    function test_busy_rejects_second_mutation() {
        SettingsApplyController.busy = true;
        verify(!SettingsApplyController.request("rollback"));
    }
    function test_failed_restore_receipt_preserves_recovery_and_blocks_done() {
        SettingsApplyController.operation = "apply";
        SettingsApplyController.acceptResult({version: 1, ok: false, error: "core failed; restore incomplete", data: {
            phase: "restoring", journalReleased: false, recoveryAvailable: true, targets: {},
            actions: {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false}}});
        verify(!SettingsApplyController.journalReleased);
        verify(SettingsApplyController.recoveryAvailable);
        SettingsApplyController.finishApply();
        compare(SettingsApplyController.applyState, "failure-activate-retained");
        verify(!SettingsApplyController.busy);
        SettingsApplyController.rollBackApply();
        compare(SettingsApplyController.operation, "recover");
    }
    function test_proved_absent_journal_allows_before_write_error_to_close() {
        SettingsApplyController.acceptResult({version: 1, ok: false, error: "Invalid source", data: {
            phase: "none", journalReleased: true, recoveryAvailable: false}});
        verify(SettingsApplyController.journalReleased);
        verify(!SettingsApplyController.recoveryAvailable);
        compare(SettingsApplyController.applyState, "failure-before-write");
        SettingsApplyController.finishApply();
        compare(SettingsApplyController.applyState, "ready");
    }
    function test_unreadable_response_never_acknowledges_unknown_apply() {
        SettingsApplyController.acceptResult({version: 9});
        verify(!SettingsApplyController.journalReleased);
        verify(SettingsApplyController.recoveryAvailable);
        SettingsApplyController.finishApply();
        compare(SettingsApplyController.applyState, "failure-activate-retained");
    }
    function test_read_failure_does_not_invent_success() {
        SettingsApplyController.acceptResult({version: 1, ok: false, data: null, error: "Settings unavailable"});
        compare(SettingsApplyController.applyState, "failure-activate-retained");
        verify(!SettingsApplyController.journalReleased);
        verify(SettingsApplyController.recoveryAvailable);
        SettingsApplyController.finishApply();
        compare(SettingsApplyController.applyState, "failure-activate-retained");
        verify(!SettingsApplyController.busy);
        compare(SettingsApplyController.failureMessage, "Settings unavailable");
    }
    function test_external_apply_refuses_dirty_edits_and_retained_journal() {
        fakeEditor.dirty = true; fakeEditor.busy = false;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        compare(SettingsApplyController.beginExternal("other", "other").code, "conflict");
        fakeEditor.dirty = false;
        SettingsApplyController.journalReleased = false;
        compare(SettingsApplyController.beginExternal("other", "other").code, "busy");
    }
    function test_external_apply_drains_preview_and_preserves_source_reference() {
        fakeEditor.dirty = false; fakeEditor.busy = false; fakeEditor.previewReady = false;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        const response = SettingsApplyController.beginExternal("custom", "/isolated/custom.json");
        compare(response.code, "pending");
        verify(SettingsApplyController.previewPreparing);
        compare(SettingsApplyController.externalThemeReference, "/isolated/custom.json");
        compare(SettingsApplyController.pollExternal(response.data.requestId).code, "pending");
        SettingsApplyController.fail("Preview restore failed");
        compare(SettingsApplyController.pollExternal(response.data.requestId).ok, false);
        verify(!SettingsApplyController.externalPending);
    }
    function test_external_review_requires_explicit_ui_decisions() {
        SettingsApplyController.externalRequestId = "r1";
        SettingsApplyController.externalResult = null;
        SettingsApplyController.operation = "review";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {scripts: [{path: "script"}], drift: null}});
        compare(SettingsApplyController.pollExternal("r1").code, "conflict");
        compare(SettingsApplyController.applyState, "failure-before-write");
    }
    function test_external_completion_waits_for_refresh_then_finishes_journal() {
        SettingsApplyController.settingsProvider = fakeSettings;
        SettingsApplyController.windowOwner = fakeWindow;
        fakeWindow.refreshMakesSettingsBusy = true;
        SettingsApplyController.externalRequestId = "external-complete";
        SettingsApplyController.externalResult = null;
        SettingsApplyController.operation = "apply";
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {phase: "complete", targets: {}, actions: {retryFailedTargets: []}}});
        verify(fakeSettings.busy);
        verify(SettingsApplyController.contextResetPending);
        compare(SettingsApplyController.pollExternal("external-complete").code, "pending");
        fakeSettings.busy = false;
        tryCompare(SettingsApplyController, "operation", "finish");
        verify(!SettingsApplyController.contextResetPending);
        SettingsApplyController.busy = false;
        SettingsApplyController.acceptResult({version: 1, ok: true, data: {journalReleased: true}});
        const receipt = SettingsApplyController.pollExternal("external-complete");
        verify(receipt.ok);
        compare(receipt.data.phase, "complete");
        verify(SettingsApplyController.journalReleased);
        verify(!SettingsApplyController.externalPending);
    }
    function test_closed_window_external_apply_reads_cold_settings_before_preview_and_review() {
        fakeSettings.settings = null;
        fakeEditor.dirty = false; fakeEditor.busy = false; fakeEditor.previewReady = false;
        SettingsApplyController.editor = fakeEditor;
        SettingsApplyController.settingsProvider = fakeSettings;
        const started = SettingsApplyController.beginExternal("cold-theme", "/isolated/cold-theme.json");
        compare(started.code, "pending");
        compare(fakeSettings.readCalls, 1);
        verify(!SettingsApplyController.previewPreparing);
        compare(SettingsApplyController.pollExternal(started.data.requestId).code, "pending");
        fakeSettings.settings = {targets: {gtk: {enabled: true}}};
        fakeSettings.busy = false;
        tryCompare(SettingsApplyController, "previewPreparing", true);
        compare(SettingsApplyController.externalThemeReference, "/isolated/cold-theme.json");
        SettingsApplyController.fail("Fixture finished before native Apply");
    }
    function test_closed_window_external_apply_preserves_cold_read_failure_and_recovery_busy() {
        SettingsApplyController.settingsProvider = fakeSettings;
        fakeSettings.settings = null; fakeSettings.recovering = true;
        compare(SettingsApplyController.beginExternal("theme", "theme").code, "busy");
        compare(fakeSettings.readCalls, 0);
        fakeSettings.recovering = false;
        const started = SettingsApplyController.beginExternal("theme", "theme");
        fakeSettings.readResult = {version: 1, ok: false, code: "permission-denied", message: "Blocked Settings read", data: null};
        fakeSettings.busy = false;
        tryVerify(() => !SettingsApplyController.externalPending);
        compare(SettingsApplyController.pollExternal(started.data.requestId).code, "permission-denied");
    }
}
