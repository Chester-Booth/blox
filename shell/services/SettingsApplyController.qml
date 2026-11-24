pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.shared

// One Apply process serves Settings and the launcher's separate quick window.
Singleton {
    id: root
    property var settingsProvider: null
    property var compositionProvider: null
    property var editor: null
    property var windowOwner: null
    property string selectedThemeId: ""
    property string selectedThemeName: ""
    property string applyState: "ready"
    property int applyProgress: 0
    property string applyMessage: "Apply saved targets"
    property string failureMessage: ""
    property string guideTarget: ""
    property var applyTargets: []
    property var applyStages: stageRows("queued")
    property var actions: ({retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false})
    property bool reloadAfterFinish: false
    property bool journalReleased: true
    property string transactionPhase: "none"
    property bool contextResetPending: false
    readonly property bool restarting: restartProcess.running
    property bool recoveryAvailable: false
    property bool busy: false
    property bool coldPreviewRestorePending: false
    property bool coldPreviewRestored: false
    property bool coldApplyPending: false
    property string coldPreviewError: ""
    readonly property bool previewPreparing: coldApplyPending || coldPreviewRestorePending || (editor && editor.settingsApplyPreviewPending === true)
    property bool quickWindowOpen: false
    property bool driftReviewOpen: false
    property bool driftDetailsOpen: false
    property var drift: null
    property string operation: ""
    property var approvals: ({})
    readonly property bool dirty: selectedThemeId.length > 0
    readonly property bool canRetryApply: journalReleased && !recoveryAvailable && !busy
        && ["failure-before-write", "failure-cursor", "failure-activate-restored", "failure-target-rolledback"].indexOf(applyState) >= 0
    readonly property int reviewTargetCount: {
        if (windowOwner && typeof windowOwner.draftEnabledTargetCount === "number")
            return windowOwner.draftEnabledTargetCount;
        const targets = settingsProvider && settingsProvider.settings ? settingsProvider.settings.targets : null;
        return targets ? Object.keys(targets).filter(key => targets[key] && targets[key].enabled).length : 0;
    }
    readonly property string failureSummary: failureMessage
    readonly property var generation: compositionProvider ? compositionProvider.provenance.generation : null
    readonly property string generatedFilesTitle: generation ? "Generated files are from " + generation.themeId : "No generated files"
    readonly property string generatedFilesDetail: generation ? "Last applied " + generation.createdAt + " · Current edits have not changed these files" : "Current edits have not changed generated files"
    readonly property string guidePath: Theme.themeStateRoot + "/current/stylus/blox-system.user.css"
    property string externalThemeReference: ""
    property string externalRequestId: ""
    property var externalResult: null
    property var externalApplyResult: null
    readonly property bool externalPending: externalRequestId.length > 0 && externalResult === null

    function externalEnvelope(ok, code, message, data) {
        return {version: 1, ok: ok, code: code, message: message || "", data: data === undefined ? null : data};
    }
    function beginExternal(themeId, themeReference) {
        if (busy || previewPreparing || externalPending || !journalReleased
                || (settingsProvider && (settingsProvider.busy || settingsProvider.recovering)) || (editor && editor.busy))
            return externalEnvelope(false, "busy", "Settings Apply is busy or needs recovery");
        if ((editor && editor.dirty) || (windowOwner && (windowOwner.draftUserEdited || windowOwner.settingsMutationPending)))
            return externalEnvelope(false, "conflict", "Apply or discard the current Settings edits first");
        if (!settingsProvider)
            return externalEnvelope(false, "unavailable", "The shell Settings owner is unavailable");
        if (!themeId)
            return externalEnvelope(false, "invalid-data", "a theme is required");
        externalThemeReference = themeReference || themeId;
        externalRequestId = "apply-" + Date.now(); externalResult = null; externalApplyResult = null;
        selectedThemeId = themeId; selectedThemeName = themeId;
        if (!settingsProvider.settings) {
            const response = JSON.parse(settingsProvider.begin("get", "{}"));
            if (response.code !== "pending") { externalResult = response; return response; }
            quickRequestId = response.data.requestId;
            quickReadTimer.start();
        } else startApply();
        return externalEnvelope(true, "pending", "", {requestId: externalRequestId});
    }
    function pollExternal(requestId) {
        if (!requestId || requestId !== externalRequestId)
            return externalEnvelope(false, "invalid-data", "unknown Apply request");
        return externalResult || externalEnvelope(true, "pending", "", {requestId: externalRequestId});
    }
    IpcHandler {
        target: "settingsApply"
        function begin(themeId: string, themeReference: string) : string { return JSON.stringify(root.beginExternal(themeId, themeReference)); }
        function poll(requestId: string) : string { return JSON.stringify(root.pollExternal(requestId)); }
    }

    signal finished()

    // A completed receipt can be acknowledged without undoing newer edits.
    function resetResult() {
        contextResetPending = false;
        transactionPhase = "none";
        failureMessage = ""; applyMessage = "Apply saved targets";
        applyProgress = 0; applyTargets = []; applyStages = stageRows("queued");
        actions = {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false};
        approvals = ({}); drift = null; driftReviewOpen = false; driftDetailsOpen = false;
        reloadAfterFinish = false; recoveryAvailable = false; applyState = "ready";
    }
    function contextChanged() {
        if (busy || previewPreparing) return false;
        if (!journalReleased) {
            if (transactionPhase === "complete") {
                reloadAfterFinish = false;
                const started = request("finish");
                contextResetPending = !started;
                return started;
            }
            return false;
        }
        resetResult();
        return true;
    }
    Timer {
        interval: 80
        repeat: true
        running: root.contextResetPending
        onTriggered: {
            if (!root.busy && !root.previewPreparing && !(root.settingsProvider && root.settingsProvider.busy))
                root.contextChanged();
        }
    }

    function releasePreviewIfIdle() {
        if (journalReleased && (applyState === "ready" || applyState === "failure-before-write")) {
            coldPreviewRestored = false;
            if (editor && typeof editor.releaseSettingsApplyPreview === "function")
                editor.releaseSettingsApplyPreview();
        }
    }
    onApplyStateChanged: releasePreviewIfIdle()
    onJournalReleasedChanged: releasePreviewIfIdle()
    onBusyChanged: {
        if (!busy) Qt.callLater(resumeColdApply);
    }
    Connections {
        target: root.editor
        ignoreUnknownSignals: true
        function onSettingsApplyPreviewPrepared(successful, message) {
            if (successful) Qt.callLater(root.startApply);
            else root.fail(message || "Could not restore the temporary Hyprland preview.");
        }
    }

    function stageRows(state) {
        return [
            {name: "Prepare", state: state, message: "Checking theme and dependencies"},
            {name: "Cursor assets", state: state, message: "Check or build generated assets"},
            {name: "Activate", state: state, message: "Write and activate the theme"},
            {name: "Applications", state: state, message: "Apply enabled targets"}
        ];
    }
    function request(action, extra) {
        if (busy || (action === "status" && coldApplyPending)
                || (action !== "status" && settingsProvider && settingsProvider.busy)) return false;
        operation = action;
        busy = true;
        failureMessage = "";
        if (action !== "status" && action !== "drift-keep" && action !== "drift-reapply") {
            applyState = action === "retry" ? "retrying" : action === "rollback" || action === "recover" ? "rolling-back" : "running";
            applyMessage = action === "review" ? "Checking theme and dependencies" : "Apply saved targets";
            applyStages = stageRows("queued");
            applyStages[0].state = "active";
            applyStages = applyStages.slice();
            applyProgress = 0;
        }
        process.command = ["python3", Quickshell.shellDir + "/scripts/apply_runtime.py", action].concat(extra || []);
        process.running = true;
        return true;
    }
    function startApply() {
        if (!dirty || busy || previewPreparing || (editor && editor.busy) || (recoveryAvailable && !journalReleased)) return;
        reloadAfterFinish = false;
        if (windowOwner && (windowOwner.settingsMutationPending || windowOwner.applyingSettingsDraft)) return;
        // A retained compositor preview must be restored even before Settings
        // has created its editor. Apply may only capture state afterwards.
        if (!editor && !coldPreviewRestored) {
            coldApplyPending = true;
            coldPreviewError = "";
            coldPreviewRestorePending = true;
            coldPreviewRestore.running = true;
            return;
        }
        if (editor && typeof editor.prepareForSettingsApply === "function" && !editor.prepareForSettingsApply()) return;
        if (!externalPending && windowOwner && windowOwner.prepareSettingsForApply && !windowOwner.prepareSettingsForApply()) return;
        if (!(externalPending ? Object.keys(settingsProvider.settings.targets).filter(key => settingsProvider.settings.targets[key].enabled).length : reviewTargetCount)) { fail("Select targets in Targets before applying."); return; }
        // Save the editor through its existing owner before reviewing the saved source.
        if (editor && editor.dirty) {
            if (editor.selectedId !== selectedThemeId) { fail("Apply or discard the current theme edits in Settings before quick Apply."); return; }
            if (editor.busy) return;
            if (!editor.candidateValid) { fail(editor.errorMessage || "Fix the theme errors before applying."); return; }
            editor.saveCandidate();
            saveTimer.start();
            return;
        }
        request("review", ["--theme", externalPending ? externalThemeReference : selectedThemeId]);
    }

    function resumeColdApply() {
        if (!coldApplyPending || coldPreviewRestorePending || busy
                || (editor && editor.settingsApplyPreviewPending === true)
                || (settingsProvider && (settingsProvider.busy || settingsProvider.recovering))
                || (windowOwner && (windowOwner.settingsMutationPending || windowOwner.applyingSettingsDraft))
                || (editor && editor.busy)) return;
        coldApplyPending = false;
        startApply();
    }

    function finishColdPreviewRestore(successful) {
        if (!coldPreviewRestorePending) return;
        coldPreviewRestored = successful;
        coldPreviewRestorePending = false;
        if (successful) Qt.callLater(resumeColdApply);
        else fail(coldPreviewError.trim() || "Could not restore the temporary Hyprland preview.");
    }

    Connections {
        target: root.settingsProvider || null
        enabled: !!root.settingsProvider
        function onBusyChanged() { Qt.callLater(root.resumeColdApply); }
        function onRecoveringChanged() { Qt.callLater(root.resumeColdApply); }
    }
    Connections {
        target: root.windowOwner
        ignoreUnknownSignals: true
        function onSettingsMutationPendingChanged() { Qt.callLater(root.resumeColdApply); }
        function onApplyingSettingsDraftChanged() { Qt.callLater(root.resumeColdApply); }
    }
    Connections {
        target: root.editor
        ignoreUnknownSignals: true
        function onBusyChanged() { Qt.callLater(root.resumeColdApply); }
    }

    Process {
        id: coldPreviewRestore
        objectName: "settings-apply-cold-preview"
        command: ["python3", Quickshell.shellDir + "/scripts/theme/hyprland_preview.py", "restore"]
        stderr: StdioCollector { onStreamFinished: root.coldPreviewError = this.text }
        onExited: (exitCode, exitStatus) => root.finishColdPreviewRestore(exitCode === 0 && exitStatus === 0)
        // FailedToStart changes running without emitting exited in Quickshell.
        onRunningChanged: {
            if (!running && root.coldPreviewRestorePending) Qt.callLater(() => {
                if (!coldPreviewRestore.running && root.coldPreviewRestorePending)
                    root.finishColdPreviewRestore(false);
            });
        }
    }
    function abortPreparation(message) {
        if (busy || !journalReleased) return;
        if (editor && typeof editor.releaseSettingsApplyPreview === "function")
            editor.releaseSettingsApplyPreview();
        fail(message || "Could not save Settings before Apply.");
    }
    function applyReviewed() { request("apply", ["--theme", externalPending ? externalThemeReference : selectedThemeId, "--approvals", JSON.stringify(approvals)]); }
    function retryFailedTargets() {
        if (!actions.retryFailedTargets.length)
            return;
        request("retry");
    }
    function retryApply() {
        if (!canRetryApply)
            return;
        startApply();
    }
    function rollBackApply() { if (recoveryAvailable) request("recover"); else if (actions.rollBack) request("rollback"); }
    function keepSuccessfulChanges() { if (actions.keepSuccessfulChanges) request("keep"); }
    function abandonSupersededApply() {
        if (actions.abandonSuperseded === true && !busy) request("abandon");
    }
    function discardEdits() {
        if (busy) return;
        if (windowOwner && windowOwner.discardSettingsEdits) windowOwner.discardSettingsEdits();
        else if (editor) editor.revertCandidate();
    }
    function finishApply() {
        if (busy || (recoveryAvailable && !journalReleased)) return;
        if (applyState === "failure-before-write") { applyState = "ready"; quickWindowOpen = false; return; }
        if (actions.keepSuccessfulChanges || actions.retryFailedTargets.length || actions.abandonSuperseded === true) return;
        if (journalReleased) { closeFinishedApply(); return; }
        request("finish");
    }
    function closeFinishedApply() {
        applyState = "ready"; quickWindowOpen = false; guideTarget = "";
        if (reloadAfterFinish) {
            reloadAfterFinish = false;
            // The verified finish or Keep result has released the Apply journal.
            restartProcess.command = ["python3", Quickshell.shellDir + "/scripts/restart_settings_shell.py", String(Quickshell.processId)];
            restartProcess.running = true;
        }
    }
    function quickApply(entry) {
        if (busy || externalPending || previewPreparing || !settingsProvider) return;
        quickWindowOpen = true; selectedThemeId = entry.id; selectedThemeName = entry.name || entry.id;
        if (settingsProvider.settings) startApply();
        else {
            const response = JSON.parse(settingsProvider.begin("get", "{}"));
            if (response.code === "pending") { quickRequestId = response.data.requestId; quickReadTimer.start(); }
            else fail(response.message || "Could not read saved targets");
        }
    }
    property string quickRequestId: ""
    Timer {
        id: quickReadTimer
        interval: 80
        repeat: true
        onTriggered: {
            const response = JSON.parse(root.settingsProvider.poll(root.quickRequestId));
            if (response.code === "pending") return;
            stop();
            if (response.ok) root.startApply();
            else {
                if (root.externalPending) root.externalResult = response;
                root.fail(response.message || "Could not read saved targets");
            }
        }
    }
    function completeQuickshellReload() { reloadAfterFinish = true; }
    function openApplyGuide(target) { if (target === "stylus") guideTarget = target; }
    function copyApplyError() { Quickshell.execDetached(["wl-copy", failureMessage]); }
    function copyGuidePath() { Quickshell.execDetached(["wl-copy", guidePath]); }
    function cancelDriftReview() { driftReviewOpen = false; }
    function resolveExternalDrift() { request("drift-keep", ["--target", drift.target]); }
    function reapplyDriftedTarget() { request("drift-reapply", ["--target", drift.target]); }

    function acceptEvent(event) {
        if (event.stage === "journal-durable") { journalReleased = false; recoveryAvailable = true; applyProgress = 30; applyStages = stageRows("queued"); applyStages[0].state = "done"; applyStages[1].state = "done"; applyStages[2].state = "active"; }
        if (event.stage === "core-verified") { applyProgress = 65; applyStages = stageRows("done"); applyStages[3].state = "active"; }
        if (event.stage === "target-result") {
            applyTargets = applyTargets.filter(row => row.target !== event.target).concat([{target: event.target, state: displayState(event.state), message: event.message || ""}]);
        }
        applyStages = applyStages.slice();
    }
    function displayState(value) { return value === "success" ? "applied" : value === "failure" ? "failed" : value === "pending" ? "queued" : value; }
    function acceptResult(response) {
        if (!response || response.version !== 1) { fail("Could not read the Apply result", null, true); return; }
        const data = response.data;
        if (operation === "finish" || operation === "abandon") {
            if (operation === "abandon" && (!response.ok || !data || data.code !== "abandoned" || data.journalReleased !== true)) {
                fail(response.error || "Could not dismiss the superseded Apply", data, true); return;
            }
            if (!response.ok) { fail(response.error || "Apply needs a decision before closing", data, true); return; }
            journalReleased = true;
            if (externalPending) externalResult = externalApplyResult || externalEnvelope(true, "ok", "", data);
            closeFinishedApply();
            resetResult();
            return;
        }
        if (operation === "recover" && response.ok) { request("status"); return; }
        if (operation === "review") {
            if (!response.ok) { fail(response.error || "Could not review Apply", data, true); return; }
            if (externalPending && ((data.scripts && data.scripts.length) || data.drift)) {
                externalResult = externalEnvelope(false, "conflict", "Open Settings to review scripts or external changes before applying", data);
                fail(externalResult.message);
                return;
            }
            if (data.scripts && data.scripts.length) {
                applyState = "ready";
                if (windowOwner) windowOwner.reviewApplyScripts(data.scripts);
                else fail("Open Settings to approve user-owned scripts before applying.");
            } else if (data.drift) { applyState = "ready"; drift = data.drift; driftReviewOpen = true; }
            else Qt.callLater(applyReviewed);
            return;
        }
        if (operation === "drift-keep" || operation === "drift-reapply") {
            if (!response.ok) { fail(response.error || "Could not resolve drift", data, true); return; }
            driftReviewOpen = false;
            if (windowOwner) windowOwner.refreshAfterApply();
            return;
        }
        if (data && data.phase === "none") {
            fail(response.error || "Could not apply theme", data, true); return;
        }
        if (!data) {
            if (operation === "status" && response.ok) {
                journalReleased = true; recoveryAvailable = false;
                resetResult(); return;
            }
            if (operation !== "status" || !response.ok) fail(response.error || "Could not apply theme", null, true);
            return;
        }
        journalReleased = data.journalReleased === true || data.phase === "restored" || data.code === "kept";
        transactionPhase = data.phase || "unknown";
        recoveryAvailable = data.recoveryAvailable === true;
        if (operation === "status" && data.phase === "complete" && data.observationConflict) {
            Qt.callLater(root.contextChanged);
            return;
        }
        if (operation === "status" && data.themeId) {
            selectedThemeId = data.themeId;
            const entry = windowOwner ? windowOwner.libraryProvider.themeFor(data.themeId) : null;
            selectedThemeName = entry ? entry.name : data.themeId;
        }
        actions = data.actions || {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false};
        applyTargets = Object.keys(data.targets || {}).map(key => ({target: key, state: displayState(data.targets[key].state), message: data.targets[key].message || ""}));
        failureMessage = data.error || response.error || applyTargets.filter(row => row.state === "failed").map(row => row.target + ": " + row.message).join("\n");
        applyState = recoveryAvailable ? "failure-activate-retained" : data.phase === "restored" ? data.code === "core-failure" ? "failure-activate-restored" : "rolled-back"
            : data.phase === "partial" ? operation === "retry" ? "retry-failure" : "failure-target-retained" : data.code === "rollback-failure" ? "rollback-failure"
            : applyTargets.some(row => row.state === "restart" && row.target === "quickshell") ? "success-reload"
            : applyTargets.some(row => row.state === "manual") && applyTargets.some(row => row.state === "restart") ? "success-mixed"
            : applyTargets.some(row => row.state === "restart") ? "success-restart" : applyTargets.some(row => row.state === "manual") ? "success-manual" : operation === "retry" ? "retry-success" : "success";
        applyProgress = 100;
        applyMessage = data.phase === "restored" ? "Previous state restored" : data.phase === "partial" ? "Review failed targets" : "Apply saved targets";
        applyStages = stageRows("done");
        if (data.code === "core-failure") { applyStages[2].state = "failed"; applyStages[3].state = "queued"; applyStages = applyStages.slice(); }
        if (windowOwner && operation !== "status") windowOwner.refreshAfterApply();
        if (externalPending) {
            externalApplyResult = externalEnvelope(response.ok && data.phase === "complete", data.phase === "complete" ? "ok" : "failed", failureMessage, data);
            if (data.phase === "complete") {
                // Refresh may have started a Settings read. Keep the receipt pending
                // until the existing context timer can release the durable journal.
                contextResetPending = !request("finish");
                return;
            }
            externalResult = externalApplyResult;
        }
        finished();
    }
    function fail(message, status, uncertain) {
        coldApplyPending = false;
        if (externalPending) externalResult = externalEnvelope(false, "failed", message, status);
        if (status && status.phase) transactionPhase = status.phase;
        const provedReleased = status && (status.journalReleased === true || status.phase === "restored" || status.code === "kept");
        if (!provedReleased && (uncertain === true || !journalReleased)) {
            journalReleased = false;
            recoveryAvailable = status ? status.recoveryAvailable === true : true;
            failureMessage = message;
            applyMessage = "Review the retained Apply before continuing";
            actions = status && status.actions ? status.actions : {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false};
            applyState = operation === "rollback" || operation === "recover" ? "rollback-failure" : "failure-activate-retained";
            finished(); return;
        }
        journalReleased = true;
        recoveryAvailable = false;
        failureMessage = message;
        applyState = "failure-before-write";
        applyMessage = message;
        applyStages = stageRows("queued"); applyStages[0].state = "failed"; applyStages = applyStages.slice();
        actions = {retryFailedTargets: [], keepSuccessfulChanges: false, rollBack: false, cancel: false};
        finished();
    }
    property string output: ""
    Process {
        id: process
        stdout: SplitParser {
            onRead: line => {
                try { const response = JSON.parse(line); if (response.event) root.acceptEvent(response.event); else root.output = line; }
                catch (_) { root.output = ""; }
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.busy = false;
            try { root.acceptResult(JSON.parse(root.output)); }
            catch (_) { root.fail("Could not read the Apply result", null, true); }
            root.output = "";
        }
    }
    Process {
        id: restartProcess
        property string errorText: ""
        stderr: SplitParser { onRead: line => restartProcess.errorText += line + "\n" }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.failureMessage = errorText.trim() || "Quickshell could not restart. Restart it manually.";
                root.applyState = "restart-failure";
            }
            errorText = "";
        }
    }
    Timer {
        id: saveTimer
        interval: 80
        repeat: true
        onTriggered: {
            if (!root.editor || root.editor.busy) return;
            stop();
            if (root.editor.dirty) root.fail(root.editor.errorMessage || "Could not save theme edits");
            else root.startApply();
        }
    }
}
