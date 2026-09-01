import qs.shared
import QtQuick
import Quickshell.Io

QtObject {
    id: root

    required property var host
    property bool busy: false
    property string action: ""
    property string processOutput: ""
    property string processError: ""
    property int requestSerial: 0
    property var activeRequest: null
    property Process apiProcess

    function run(nextAction, args) {
        if (busy) {
            host.errorMessage = "Another theme action is still running.";
            return false;
        }
        action = nextAction;
        requestSerial += 1;
        activeRequest = {
            "serial": requestSerial,
            "sessionRevision": host.sessionRevision,
            "action": nextAction,
            "candidateRevision": host.candidateRevision,
            "candidateJson": host.candidate === null ? "" : JSON.stringify(host.candidate)
        };
        processOutput = "";
        processError = "";
        host.errorMessage = "";
        busy = true;
        const progressArgs = nextAction.startsWith("apply") ? ["--progress-ndjson"] : [];
        apiProcess.command = [host.apiPath].concat(args).concat(["--json"]).concat(progressArgs);
        apiProcess.running = true;
        return true;
    }

    function handleResponse(request, response) {
        const completedAction = request.action;
        const failed = !response || response.ok !== true;
        if (completedAction === "palette") {
            host.paletteLoading = false;
            if (!request.inputs || request.inputs.paletteSerial !== host.paletteRequestSerial || request.inputs.wallpaper !== host.newWallpaper.trim()) {
                host.schedulePaletteRequest();
                return ;
            }
            host.paletteOptions = response && response.data ? response.data : [];
            host.apiWarnings = response && response.warnings ? response.warnings : [];
            if (failed) {
                host.errorMessage = response && response.errors ? response.errors.join("\n") : "Palette preview failed.";
            } else if (!host.paletteOptions.some((entry) => {
                return entry.available && entry.backend === host.generatorBackend && entry.mode === host.newVariant;
            })) {
                const available = host.paletteOptions.find((entry) => {
                    return entry.available;
                });
                if (available)
                    host.generatorBackend = available.backend;

                if (available)
                    host.newVariant = available.mode;

            }
            return ;
        }
        if (completedAction === "widgets-import") {
            if (!failed && response.data) {
                const next = host.cloneCandidate();
                next.widgets = response.data;
                host.markCandidate(next);
                host.statusMessage = "Widget configuration imported.";
            }
            return ;
        }
        if (completedAction === "preview-edit") {
            if (host.candidate === null || request.candidateRevision !== host.candidateRevision || request.candidateJson !== JSON.stringify(host.candidate)) {
                host.validationPending = host.candidate !== null;
                host.candidateValid = false;
                return ;
            }
            host.candidateValid = !failed;
            host.validationErrors = response && response.errors ? response.errors : ["Preview validation failed."];
            host.apiWarnings = response && response.warnings ? response.warnings : [];
            host.previewData = response && response.data ? response.data : ({
            });
            if (!failed)
                host.applyValidatedPreview(JSON.parse(request.candidateJson));

            return ;
        }
        if (failed) {
            host.errorMessage = response && response.errors ? response.errors.join("\n") : "Theme action failed.";
            if (completedAction === "wallpapers-remove") {
                host.wallpaperRemovalError = host.errorMessage;
                host.errorMessage = "";
                host.modalKind = "wallpaper-remove";
                Qt.callLater(host.focusModal);
                return ;
            }
            if (completedAction === "list" || completedAction === "list-refresh") {
                host.statusMessage = "Could not load themes.";
                if (completedAction === "list")
                    host.themes = [];
            } else if (completedAction === "show") {
                host.candidate = null;
                host.sourceTheme = null;
                host.touchedPaths = [];
                host.selectedId = "";
                host.sourceDigest = "";
                host.baselineJson = "";
                host.candidateValid = false;
                host.validationErrors = [];
                host.statusMessage = "Could not load the selected theme.";
            }
            if (completedAction === "generate" || completedAction === "new-template")
                host.creationBusy = false;

            if (completedAction === "apply" || completedAction === "apply-inline" || completedAction === "apply-retry") {
                host.applyProgressComplete = true;
                if (completedAction === "apply-retry")
                    host.applyProgressRows = host.applyProgressRows.map((entry) => {
                    return entry.state === "active" ? ({
                        "target": entry.target,
                        "state": "failed",
                        "message": "Could not apply automatically"
                    }) : entry;
                });

            }
            return ;
        }
        host.apiWarnings = response.warnings || [];
        if (completedAction === "list" || completedAction === "list-refresh") {
            host.themes = response.data || [];
            if (completedAction === "list") {
                const preferred = host.themes.some((entry) => {
                    return entry.id === Theme.activeThemeId;
                }) ? Theme.activeThemeId : (host.themes.length > 0 ? host.themes[0].id : "");
                if (preferred)
                    host.requestSelection(preferred, false);

            }
        } else if (completedAction === "show") {
            host.candidate = JSON.parse(JSON.stringify(response.data));
            host.sourceTheme = response.source && typeof response.source === "object" ? JSON.parse(JSON.stringify(response.source)) : null;
            host.touchedPaths = [];
            host.selectedId = host.candidate.id;
            host.sourceDigest = host.themeDigest(host.candidate.id);
            host.baselineJson = JSON.stringify(host.candidate);
            host.candidateRevision += 1;
            host.refreshWallpapers();
            if (host.generateAfterLoad) {
                host.generateAfterLoad = false;
                host.generateTheme(host.candidate.wallpaper.path);
            } else {
                host.validatePreview();
            }
        } else if (completedAction === "show-generate-current") {
            host.generateAfterLoad = false;
            host.generateTheme(response.data.wallpaper.path);
        } else if (completedAction === "generate") {
            host.candidate = JSON.parse(JSON.stringify(response.data.theme));
            host.sourceTheme = null;
            host.touchedPaths = [];
            host.selectedId = host.candidate.id;
            host.sourceDigest = "";
            host.baselineJson = "";
            host.previewData = response.data;
            host.candidateRevision += 1;
            host.creationBusy = false;
            host.modalKind = "";
            Qt.callLater(() => {
                host.restoreOverlayFocus();
            });
            host.validatePreview();
        } else if (completedAction === "new-template") {
            const blank = host.blankTheme(response.data, request.inputs);
            host.candidate = blank;
            host.sourceTheme = null;
            host.touchedPaths = [];
            host.selectedId = host.candidate.id;
            host.sourceDigest = "";
            host.baselineJson = "";
            host.candidateRevision += 1;
            host.creationBusy = false;
            host.modalKind = "";
            Qt.callLater(() => {
                host.restoreOverlayFocus();
            });
            host.validatePreview();
        } else if (completedAction === "save") {
            host.sourceDigest = response.data.source_sha256;
            if (response.data.source && typeof response.data.source === "object")
                host.sourceTheme = JSON.parse(JSON.stringify(response.data.source));
            host.touchedPaths = [];
            host.selectedId = host.candidate.id;
            host.baselineJson = JSON.stringify(host.candidate);
            host.candidateRevision += 1;
            host.statusMessage = "Theme source saved.";
            if (host.pendingAfterSave === "apply") {
                host.pendingAfterSave = "";
                // The picker owns the complete target selection. Apply the
                // resolved candidate authoritatively so a target that the user
                // unticked is removed from the active generation as well.
                host.runApi("apply-inline", ["apply-inline", JSON.stringify(host.candidate), "--defer-quickshell-restart"]);
            } else {
                host.refreshThemes(true);
            }
        } else if (completedAction === "apply" || completedAction === "apply-inline" || completedAction === "apply-retry") {
            Theme.reload();
            const pendingReloads = response.data && Array.isArray(response.data.pending_reloads) ? response.data.pending_reloads : [];
            host.applyQuickshellReloadPending = host.applyQuickshellReloadPending || pendingReloads.indexOf("quickshell") >= 0;
            const changedTargets = response.data && Array.isArray(response.data.changed_targets) ? response.data.changed_targets : null;
            host.baselineJson = JSON.stringify(host.candidate);
            host.candidateRevision += 1;
            host.statusMessage = "Theme applied. Review any target notes below.";
            host.applyProgressComplete = true;
            host.applyProgressValue = 1;
            host.applyProgressMessage = "Application finished · Review follow-up actions";
            const unappliedTargets = changedTargets ? changedTargets.filter((target) => {
                return host.candidate && host.candidate.targets && host.candidate.targets[target] !== true;
            }) : [];
            const completedRows = host.applyProgressRows.map((entry) => {
                if (completedAction === "apply-retry" && entry.state !== "active")
                    return entry;

                if (changedTargets && changedTargets.indexOf(entry.target) < 0)
                    return {
                    "target": entry.target,
                    "state": "unchanged",
                    "message": "Unchanged"
                };

                if (pendingReloads.indexOf("quickshell") >= 0 && (entry.target === "cursor" || entry.target === "quickshell"))
                    return {
                    "target": entry.target,
                    "state": "restart",
                    "message": "Complete to reload Blox surfaces"
                };

                const mode = host.targetApplyMode(entry.target);
                const editorName = entry.target === "code" ? "Code" : entry.target === "cursor_editor" ? "Cursor" : "";
                const editorFailure = editorName && (response.warnings || []).find((warning) => {
                    return String(warning).indexOf(editorName + " settings were not changed:") >= 0;
                });
                if (editorFailure)
                    return {
                    "target": entry.target,
                    "state": "failed",
                    "message": "Could not apply automatically"
                };

                return {
                    "target": entry.target,
                    "state": mode === "manual" ? "manual" : mode === "restart" ? "restart" : "applied",
                    "message": mode === "manual" ? "Apply Manually" : mode === "restart" ? host.targetModeLabel(entry.target) : "Applied"
                };
            });
            const unappliedRows = unappliedTargets.filter((target) => {
                return !completedRows.some((entry) => entry.target === target);
            }).map((target) => {
                return {
                    "target": target,
                    "state": "unapplied",
                    "message": "Unapplied"
                };
            });
            host.applyProgressRows = completedRows.concat(unappliedRows);
            host.refreshThemes(true);
        } else if (completedAction === "duplicate") {
            host.statusMessage = "Theme duplicated.";
            host.pendingSelection = response.data.id;
            host.runApi("list-after-duplicate", ["list"]);
        } else if (completedAction === "list-after-duplicate") {
            host.themes = response.data || [];
            const id = host.pendingSelection;
            host.pendingSelection = "";
            host.requestSelection(id, false);
        } else if (completedAction === "rename") {
            if (response.data.id === host.selectedId) {
                host.candidate.name = response.data.name;
                host.sourceDigest = response.data.source_sha256;
                host.baselineJson = JSON.stringify(host.candidate);
                host.candidateRevision += 1;
            }
            host.statusMessage = "Display name changed; stable ID preserved.";
            host.refreshThemes(true);
        } else if (completedAction === "delete") {
            if (response.data.id === host.selectedId) {
                Theme.cancelPreview();
                host.candidate = null;
                host.sourceTheme = null;
                host.touchedPaths = [];
                host.selectedId = "";
                host.sourceDigest = "";
                host.baselineJson = "";
            }
            host.statusMessage = "Theme deleted.";
            host.refreshThemes(host.candidate !== null);
        } else if (completedAction === "import") {
            host.statusMessage = "Theme imported. Apply remains a separate action.";
            host.pendingSelection = response.data.id;
            host.runApi("list-after-import", ["list"]);
        } else if (completedAction === "list-after-import") {
            host.themes = response.data || [];
            const id = host.pendingSelection;
            host.pendingSelection = "";
            host.requestSelection(id, false);
        } else if (completedAction === "wallpapers-import") {
            const item = response.data || ({ });
            if (item.reference || item.path)
                host.setWallpaperPath(item.reference || item.path);
            host.statusMessage = item.duplicate ? "Wallpaper already in the library; previewing it." : "Wallpaper imported and previewing.";
            host.refreshWallpapers();
        } else if (completedAction === "wallpapers-remove") {
            host.statusMessage = "Wallpaper removed from the library.";
            host.wallpaperRemovalId = "";
            host.wallpaperRemovalName = "";
            host.wallpaperRemovalReference = "";
            host.wallpaperRemovalUsers = [];
            host.wallpaperRemovalError = "";
            host.refreshWallpapers();
        } else if (completedAction === "export") {
            host.statusMessage = "Theme exported to " + response.data.path;
        }
    }

    apiProcess: Process {
        onExited: (exitCode, exitStatus) => {
            const request = root.activeRequest;
            root.activeRequest = null;
            root.busy = false;
            if (!request || request.sessionRevision !== host.sessionRevision) {
                if (host.open && host.candidate === null) {
                    if (host.themes.length === 0)
                        host.refreshThemes(false);
                    else
                        host.requestSelection(Theme.activeThemeId, false);
                }
                return ;
            }
            let response = null;
            try {
                response = JSON.parse(root.processOutput.trim());
            } catch (error) {
                host.errorMessage = "Theme API returned invalid JSON: " + String(error) + (root.processError ? "\n" + root.processError.trim() : "");
                if (host.validationPending && host.candidate !== null)
                    host.scheduleValidation();

                host.continueQueuedGeneration();
                return ;
            }
            root.handleResponse(request, response);
            if (host.validationPending && host.candidate !== null)
                host.scheduleValidation();

            host.continueQueuedGeneration();
        }

        stdout: StdioCollector {
            onStreamFinished: root.processOutput = this.text
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: (line) => {
                root.processError += line + "\n";
                if (!root.action.startsWith("apply"))
                    return ;

                try {
                    host.handleApplyProgress(JSON.parse(line));
                } catch (error) {
                }
            }
        }

    }

}
