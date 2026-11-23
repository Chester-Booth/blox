import QtQuick
import QtTest
import Quickshell
import qs.modules
import qs.services
import qs.shared

// Isolated visual harness. Result fixtures never invoke Apply or alter the desktop shell.
Scope {
    id: harness
    readonly property string mode: Quickshell.env("BLOX_TEST_FLOW") || "success"
    readonly property string capture: Quickshell.env("BLOX_TEST_CAPTURE") || ""
    MockState { id: reference }
    SettingsController { id: owner; enableColdRecovery: false }
    QtObject { id: picker; readonly property var controller: window.themeEditorController }
    SettingsWindow {
        id: window
        settingsFeedback: Quickshell.env("BLOX_TEST_FEEDBACK") || ""
        settingsController: owner
        implicitWidth: Number(Quickshell.env("BLOX_TEST_WIDTH") || 1320)
        implicitHeight: Number(Quickshell.env("BLOX_TEST_HEIGHT") || 860)
        Component.onCompleted: openWindow()
    }
    QtObject {
        id: fixtureOwner
        function refreshAfterApply() {}
        function restoreFocusAfterDialog() {}
        property bool settingsMutationPending: false
        property var settingsController: owner
        property var themeEditorController: picker.controller
        property var libraryProvider: window.libraryProvider
        property string settingsFeedback: ""
    }
    SettingsBundleController { id: bundle; windowOwner: fixtureOwner }
    SettingsBundleFlowWindow { id: bundleWindow; flowState: bundle; settingsWindow: window }
    TestCase { id: keyboard; parent: bundleWindow.contentItem; when: false }
    Timer {
        interval: 900
        running: true
        onTriggered: {
            if (Quickshell.env("BLOX_TEST_SEEDED") === "1") {
                const xhr = new XMLHttpRequest();
                xhr.open("GET", "file://" + Quickshell.env("BLOX_TEST_DATASET"), false);
                xhr.send();
                const data = JSON.parse(xhr.responseText);
                Object.keys(data.mock).forEach(key => reference[key] = data.mock[key]);
                picker.controller.requestSelection("midnight", false);
            }
            window.navigateTo(Quickshell.env("BLOX_TEST_ROUTE") || "review", Quickshell.env("BLOX_TEST_PAGE") || "landing", "");
            SettingsApplyController.windowOwner = null;
            SettingsApplyController.selectedThemeName = "Midnight";
            SettingsApplyController.selectedThemeId = "midnight";
            if (Quickshell.env("BLOX_TEST_REFERENCE") === "1") {
                window.libraryProvider.themes = reference.themeCards.map(card => ({id: card.id, name: card.name, builtin: false,
                    preview: {colours: {background: card.preview.background, surface: card.preview.surface, surface_alt: card.preview.surfaceAlt,
                        foreground: card.preview.foreground, muted: card.preview.muted, accent: card.preview.accent, success: card.preview.success, warning: card.preview.warning},
                        wallpaper: card.wallpaper, fonts: {ui: card.previewFont}, bar: {position: card.barPosition, items: []}}}));
                window.libraryProvider.selectedThemeId = reference.selectedThemeId;
                SettingsApplyController.selectedThemeId = reference.selectedThemeId;
                SettingsApplyController.selectedThemeName = reference.selectedThemeName;
            }
            if (harness.mode === "native-open" || harness.mode === "native-save") {
                if (harness.mode === "native-open") window.bundleProvider.importBundle();
                else { window.bundleProvider.exportBundle(); window.bundleProvider.chooseBundle("minimal"); window.bundleProvider.toggleExportComponent("wallpaper", false); window.bundleProvider.showBundleFilePicker("file-save"); }
                captureTimer.interval = 180000; captureTimer.start(); return;
            }
            if (harness.mode.startsWith("import") || harness.mode === "export") {
                bundle.importedCard = {id: "midnight", name: "Midnight", palette: ["#82aaff", "#c3e88d", "#ffcb6b", "#e7ebf2"], wallpaper: Quickshell.env("BLOX_TEST_WALLPAPER"), barPosition: "top"};
                bundle.bundleFlowKind = harness.mode === "export" ? "export" : "import";
                bundle.bundleStep = harness.mode === "export" ? "contents" : harness.mode === "import-sensitive" ? "sensitive" : "sections";
                bundle.dialogKind = harness.mode === "export" ? "export-review" : "import-review";
                bundle.exportThemeId = window.libraryProvider.selectedThemeId;
                bundle.selectedExportTargets = bundle.targetDefaults.slice();
                bundle.importSectionRows = bundle.exportComponentRows;
                bundle.selectedImportSections = ["appearance", "wallpaper", "bar", "widgets", "targets"];
                const script = {id: "script", path: "assets/scripts/probe.sh", name: "scripts/probe.sh", size: 100, sha256: "a".repeat(64), preview: "#!/bin/sh\nset -eu\necho one\necho two\necho three\necho four", reason: "Executable script · 6 lines", viewMode: "expand"};
                bundle.sensitiveImportFiles = [script];
                bundleWindow.visible = true;
            } else if (harness.mode === "ready" || harness.mode === "drift") {
                SettingsApplyController.applyState = "ready";
                if (harness.mode === "drift") {
                    SettingsApplyController.drift = {target: "gtk", label: "GTK appearance", paths: ["~/.config/gtk-3.0/settings.ini", "~/.config/gtk-4.0/settings.ini"], observedAt: "Observed now", managed: "Midnight", expected: "Dark", current: "Light"};
                    SettingsApplyController.driftReviewOpen = true;
                }
            } else {
                const failed = harness.mode === "partial" || harness.mode === "retry-failure";
                const restored = harness.mode === "rolled-back";
                const targets = {hyprlock: {state: restored ? "unchanged" : "restart"}, helium: {state: restored ? "unchanged" : "restart"}, chromium: {state: restored ? "unchanged" : "restart"}, quickshell: {state: restored ? "unchanged" : "success"}, kitty: {state: restored ? "unchanged" : "unchanged"}, gtk: {state: restored ? "unchanged" : failed ? "failure" : "restart", message: failed ? "GTK could not apply automatically" : ""}, stylus: {state: restored ? "unchanged" : "manual"}};
                SettingsApplyController.operation = "apply";
                SettingsApplyController.acceptResult({version: 1, ok: true, data: {phase: restored ? "restored" : failed ? "partial" : "complete", code: restored ? "rolled-back" : failed ? "partial" : "ok", targets: targets,
                    actions: {retryFailedTargets: failed ? ["gtk"] : [], keepSuccessfulChanges: false, rollBack: failed, cancel: false}}});
                if (harness.mode === "running" || harness.mode === "retrying" || harness.mode === "rolling-back") {
                    SettingsApplyController.applyState = harness.mode;
                    SettingsApplyController.busy = true;
                    SettingsApplyController.acceptEvent({stage: "core-verified"});
                }
                if (harness.mode === "quick") SettingsApplyController.quickWindowOpen = true;
            }
            if ((Quickshell.env("BLOX_TEST_APPLY_ERROR_RESULT") || "").length) {
                const response = new XMLHttpRequest();
                response.open("GET", "file://" + Quickshell.env("BLOX_TEST_APPLY_ERROR_RESULT"), false);
                response.send();
                SettingsApplyController.operation = "apply";
                SettingsApplyController.acceptResult(JSON.parse(response.responseText));
            }
            if (Quickshell.env("BLOX_TEST_REFERENCE") === "1") {
                SettingsApplyController.applyState = reference.applyState;
                SettingsApplyController.applyTargets = reference.applyTargets.map(row => Object.assign({}, row,
                    reference.applyState === "success-mixed" && row.target === "quickshell" ? {state: "restart"} : {}));
                SettingsApplyController.applyStages = reference.applyStages;
                SettingsApplyController.applyProgress = reference.applyProgress;
                SettingsApplyController.applyMessage = reference.applyMessage;
                SettingsApplyController.failureMessage = reference.failureMessage;
                if (harness.mode.startsWith("import") || harness.mode === "export") {
                    bundle.importedCard = Object.assign({}, reference.themeCards.find(card => card.id === "midnight"), {palette: reference.themeCards.find(card => card.id === "midnight").colours});
                    bundle.importSectionRows = reference.importSectionRows;
                    bundle.selectedImportSections = reference.selectedImportSections;
                    bundle.sensitiveImportFiles = reference.sensitiveImportFiles.map(file => Object.assign({}, file, {path: file.id, sha256: "a".repeat(64)}));
                }
            }
            SettingsApplyController.selectedThemeName = reference.selectedThemeName;
            captureTimer.start();
        }
    }
    LauncherMainController { id: launcher }
    LauncherThemeApplyWindow { id: quick; controller: launcher; targetScreen: Quickshell.screens[0] }
    function findItem(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) { const found = findItem(child, name); if (found) return found; }
        return null;
    }
    Timer {
        id: captureTimer
        interval: Number(Quickshell.env("BLOX_TEST_HOLD_MS") || (Quickshell.env("BLOX_TEST_SEEDED") === "1" ? 1400 : 400))
        onTriggered: {
            if (Quickshell.env("BLOX_TEST_SEEDED") === "1") {
                picker.controller.wallpapers = reference.themeCards.map(card => ({id:card.id, name:card.name,
                    kind:card.meta.indexOf("built in") >= 0 || card.meta.indexOf("active") >= 0 ? "Built in" : "Imported",
                    path:card.wallpaper, reference:card.wallpaper, removable:false, missing:false}));
                picker.controller.wallpaperRevision += 1;
                if (!picker.controller.candidate || picker.controller.candidate.id !== "midnight" || picker.controller.errorMessage) {
                    console.error("DATASET FAIL: editable source not loaded", picker.controller.errorMessage);
                    Qt.quit(); return;
                }
                console.log("DATASET PASS: saved Settings and editable Midnight source loaded");
            }
            if ((Quickshell.env("BLOX_TEST_APPLY_ERROR_RESULT") || "").length) {
                const state = SettingsApplyController.applyState;
                const complete = harness.findItem(window.captureItem, "apply-complete");
                if (!complete || complete.enabled) { console.error("RETAINED RECOVERY FAIL: Done remains enabled"); Qt.quit(); return; }
                SettingsApplyController.finishApply();
                if (SettingsApplyController.journalReleased || !SettingsApplyController.recoveryAvailable
                        || state !== "failure-activate-retained" || SettingsApplyController.applyState !== state
                        || SettingsApplyController.busy) {
                    console.error("RETAINED RECOVERY FAIL"); Qt.quit(); return;
                }
                console.log("RETAINED RECOVERY PASS: genuine failed-restore response preserves journal and blocks Done");
            }
            if (Quickshell.env("BLOX_TEST_RESULT_HEADING") === "1") {
                const heading = harness.findItem(window.captureItem, "apply-progress-heading");
                const expected = harness.mode === "rolled-back" ? "Previous state restored" : SettingsApplyController.selectedThemeName + " applied";
                if (!heading || heading.text !== expected) {
                    console.error("RESULT HEADING FAIL", heading ? heading.text : "missing", expected);
                    Qt.quit(); return;
                }
                console.log("RESULT HEADING PASS", heading.text);
            }
            if (Quickshell.env("BLOX_TEST_REVIEW_SEARCH") === "1") {
                const page = harness.findItem(window.captureItem, "apply-review-page");
                const expected = page && page.inProgress ? "apply-progress" : page && page.stableResult ? "apply-complete" : "apply-start";
                if (!page || !page.jumpToTarget("apply-review", "Apply & review", "Setting")
                        || !page.flashItem || page.flashItem.objectName !== expected || !page.flashItem.visible) {
                    console.error("REVIEW SEARCH FAIL: action target missing or incorrect", expected);
                    Qt.quit(); return;
                }
                console.log("REVIEW SEARCH PASS: highlights", expected);
                keyboard.wait(30);
            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "single-search-arrow") {
                keyboard.parent = window.contentItem;
                window.navigateTo("theme", "landing", "");
                keyboard.wait(30);
                const search = harness.findItem(window.captureItem, "settings-search");
                search.focusEditor(true);
                for (const letter of "adwaita") keyboard.keyClick(letter.toUpperCase().charCodeAt(0));
                keyboard.wait(30);
                const arrow = harness.findItem(window.captureItem, "all-search-results");
                keyboard.mouseClick(arrow, arrow.width / 2, arrow.height / 2, Qt.LeftButton);
                keyboard.wait(100);
                const selector = harness.findItem(window.captureItem, "icon-theme-selector");
                let page = selector;
                while (page && page.flashItem === undefined) page = page.parent;
                if (!window.pendingSearchTarget || window.pendingSearchTarget.label !== "Icon theme"
                        || !selector || !page || page.flashItem !== selector) {
                    console.error("SINGLE SEARCH ARROW FAIL: result did not highlight exact icon-theme selector"); Qt.quit(); return;
                }
                console.log("SINGLE SEARCH ARROW PASS: arrow opens the only result and highlights icon-theme-selector");
            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "new-blank") {
                keyboard.parent = window.contentItem;
                window.navigateTo("theme", "landing", "");
                Theme.densityScale = Number(Quickshell.env("BLOX_TEST_PLUS_DENSITY") || 1);
                window.shelfOpen = true;
                keyboard.wait(60);
                const selected = window.libraryProvider.selectedThemeId;
                const plus = harness.findItem(window.captureItem, "new-theme-toggle");
                keyboard.mouseClick(plus, 2, plus.height / 2, Qt.LeftButton);
                keyboard.wait(30);
                const blank = harness.findItem(window.captureItem, "new-theme-from-blank");
                keyboard.mouseClick(blank, 2, blank.height / 2, Qt.LeftButton);
                keyboard.wait(250);
                if (picker.controller.modalKind !== "new" || picker.controller.newFlowPage !== "blank"
                        || window.libraryProvider.selectedThemeId !== selected || window.newMenuOpen) {
                    console.error("NEW BLANK FAIL: plus-to-blank flow changed selection or did not open"); Qt.quit(); return;
                }
                console.log("NEW BLANK PASS: actual Settings creation dialog opens without changing selection");
            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "empty-themes") {
                window.navigateTo("theme", "landing", "");
                window.shelfOpen = true;
                window.libraryProvider.searchText = "no matching fixture theme";
                keyboard.wait(60);
                function emptyText(item) {
                    if (item.text === "No themes match the search.") return item;
                    for (const child of item.children || []) { const found = emptyText(child); if (found) return found; }
                    return null;
                }
                const message = emptyText(window.captureItem);
                if (!message || !message.visible || message.parent.height <= 0
                        || Math.abs(message.y + message.height / 2 - message.parent.height / 2) > 1
                        || Math.abs(message.x + message.width / 2 - message.parent.width / 2) > 1) {
                    console.error("EMPTY THEMES FAIL: empty result text is not centred"); Qt.quit(); return;
                }
                console.log("EMPTY THEMES PASS: no-match message is centred in the selector viewport");
            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "reset-tooltip") {
                keyboard.parent = window.contentItem;
                window.saveTargetOverride("gtk", "accent", "#ff7755");
                window.navigateTo("targets", "landing", "overrides");
                keyboard.wait(100);
                const swatch = harness.findItem(window.captureItem, "target-override-gtk-accent");
                const reset = swatch && swatch.parent.children.find(child => child.iconName === "arrow-counter-clockwise");
                const tooltip = reset && reset.data.find(child => child.toString().indexOf("BloxToolTip") === 0);
                if (!reset || !tooltip) { console.error("RESET TOOLTIP FAIL: reset or tooltip missing"); Qt.quit(); return; }
                keyboard.mouseMove(reset, reset.width / 2, reset.height / 2);
                keyboard.wait(400);
                if (!reset.hovered || !tooltip.visible || tooltip.text !== "Reset accent to theme colour") {
                    console.error("RESET TOOLTIP FAIL: hover did not show correct Blox tooltip"); Qt.quit(); return;
                }
                keyboard.mouseMove(window.captureItem, window.captureItem.width - 2, 2);
                keyboard.wait(20);
                if (tooltip.visible) { console.error("RESET TOOLTIP FAIL: tooltip remained after leaving"); Qt.quit(); return; }
                keyboard.mouseMove(reset, reset.width / 2, reset.height / 2);
                keyboard.wait(400);
                console.log("RESET TOOLTIP PASS: pointer motion shows Blox reset tooltip and leaving hides it");
            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "breadcrumbs") {
                keyboard.parent = window.contentItem;
                window.navigateTo("theme", "advanced", "");
                keyboard.wait(50);
                for (let index = 0; index < 4; index++) {
                    const crumb = harness.findItem(window.captureItem, "breadcrumb-" + index);
                    const label = harness.findItem(window.captureItem, "breadcrumb-label-" + index);
                    if (!crumb || !label) { console.error("BREADCRUMB FAIL: missing crumb", index); Qt.quit(); return; }
                    keyboard.mouseMove(crumb, crumb.width / 2, crumb.height / 2);
                    keyboard.wait(20);
                    if (label.font.underline !== (index < 3)) {
                        console.error("BREADCRUMB FAIL: hover underline incorrect", index); Qt.quit(); return;
                    }
                    keyboard.mouseMove(window.captureItem, window.captureItem.width - 2, window.captureItem.height - 2);
                    keyboard.wait(20);
                    if (label.font.underline) { console.error("BREADCRUMB FAIL: underline remained after leaving", index); Qt.quit(); return; }
                }
                const first = harness.findItem(window.captureItem, "breadcrumb-0");
                keyboard.mouseMove(first, first.width / 2, first.height / 2);
                keyboard.wait(20);
                console.log("BREADCRUMB PASS: all blue links underline on hover and clear on leave, final crumb remains plain");
            }
            if (["plus", "overlay"].indexOf(Quickshell.env("BLOX_TEST_KEYBOARD")) >= 0) {
                keyboard.parent = window.contentItem;
                window.navigateTo("theme", "landing", "");
                Theme.densityScale = Number(Quickshell.env("BLOX_TEST_PLUS_DENSITY") || 1);
                window.shelfOpen = true;
                keyboard.wait(60);
                const plus = harness.findItem(window.captureItem, "new-theme-toggle");
                const category = harness.findItem(window.captureItem, "category-theme");
                const selectedTheme = window.libraryProvider.selectedThemeId;
                if (!plus || !category || category.border.width !== 1) {
                    console.error("PLUS FAIL: selected category or shelf control missing"); Qt.quit(); return;
                }
                // The left edge overlaps the sidebar when the short selector is open.
                // Exercise a real pointer sequence rather than invoking clicked().
                keyboard.mouseClick(plus, 2, plus.height / 2, Qt.LeftButton);
                keyboard.wait(30);
                if (!window.newMenuOpen || category.border.width !== 1
                        || window.libraryProvider.selectedThemeId !== selectedTheme) {
                    console.error("PLUS FAIL: click passed through or changed selected theme"); Qt.quit(); return;
                }
                console.log("PLUS PASS: left-edge click opens creation menu and preserves category/theme", Theme.densityScale);
                if (Quickshell.env("BLOX_TEST_KEYBOARD") === "overlay") {
                    const blank = harness.findItem(window.captureItem, "new-theme-from-blank");
                    keyboard.mouseClick(blank, 2, blank.height / 2, Qt.LeftButton);
                    keyboard.wait(250);
                    if (category.border.width !== 1 || window.libraryProvider.selectedThemeId !== selectedTheme
                            || picker.controller.modalKind !== "new") {
                        console.error("OVERLAY FAIL: blank creation passed through or did not open"); Qt.quit(); return;
                    }
                    picker.controller.modalKind = "";
                    window.shelfOpen = true;
                    const otherTheme = window.libraryProvider.themes.find(theme => theme.id !== selectedTheme);
                    if (!otherTheme) { console.error("OVERLAY FAIL: second source missing"); Qt.quit(); return; }
                    window.openThemeCardMenu(otherTheme, plus, false);
                    keyboard.wait(30);
                    const exportButton = harness.findItem(window.captureItem, "theme-menu-export");
                    keyboard.mouseClick(exportButton, 2, exportButton.height / 2, Qt.LeftButton);
                    keyboard.wait(30);
                    if (category.border.width !== 1 || window.libraryProvider.selectedThemeId !== selectedTheme
                            || window.bundleProvider.dialogKind !== "export-review") {
                        console.error("OVERLAY FAIL: context export passed through or did not open"); Qt.quit(); return;
                    }
                    console.log("OVERLAY PASS: blank creation and context export preserve category/theme");
                    window.bundleProvider.closeBundleDialog();
                    window.shelfOpen = true;
                    window.newMenuOpen = true;
                    if (Quickshell.env("BLOX_TEST_DISABLE_OVERLAY_SHIELD") === "1") {
                        harness.findItem(window.captureItem, "new-menu-pointer-shield").enabled = false;
                        harness.findItem(window.captureItem, "theme-menu-pointer-shield").enabled = false;
                    }
                    const newMenu = harness.findItem(window.captureItem, "new-theme-menu");
                    keyboard.mouseClick(newMenu, 2, 2, Qt.LeftButton);
                    keyboard.wait(20);
                    if (!window.newMenuOpen || category.border.width !== 1 || window.libraryProvider.selectedThemeId !== selectedTheme) {
                        console.error("OVERLAY FAIL: new-menu padding click passed through"); Qt.quit(); return;
                    }
                    const builtin = window.libraryProvider.themes.find(theme => theme.id === "blox-panel")
                        || {id: "blox-panel", name: "Blox", builtin: true};
                    window.openThemeCardMenu(builtin, plus, false);
                    keyboard.wait(30);
                    const context = harness.findItem(window.captureItem, "theme-card-context-menu");
                    const rename = harness.findItem(window.captureItem, "theme-menu-rename");
                    keyboard.mouseClick(context, 2, 2, Qt.LeftButton);
                    keyboard.mouseClick(rename, 2, rename.height / 2, Qt.LeftButton);
                    keyboard.wait(20);
                    if (rename.enabled || !window.themeCardMenuOpen || category.border.width !== 1
                            || window.libraryProvider.selectedThemeId !== selectedTheme || picker.controller.modalKind.length > 0) {
                        console.error("OVERLAY FAIL: disabled action or context padding passed through", rename.enabled, window.themeCardMenuOpen, category.border.width, window.libraryProvider.selectedThemeId, selectedTheme, picker.controller.modalKind); Qt.quit(); return;
                    }
                    console.log("OVERLAY GUARD PASS: disabled actions and empty menu padding preserve category/theme");

                }

            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "main") {
                keyboard.parent = window.contentItem;
                const category = harness.findItem(window.captureItem, "category-bar");
                const card = harness.findItem(window.captureItem, "active-theme-card");
                if (!category || !card) { console.error("KEYBOARD FAIL: main controls missing"); Qt.quit(); return; }
                category.forceActiveFocus();
                keyboard.keyClick(Qt.Key_Tab);
                if (category.activeFocus) { console.error("KEYBOARD FAIL: Tab did not move focus"); Qt.quit(); return; }
                card.focusAction();
                keyboard.keyClick(Qt.Key_Space);
                keyboard.wait(30);
                if (!window.shelfOpen) { console.error("KEYBOARD FAIL: Space did not open theme selector"); Qt.quit(); return; }
                keyboard.keyClick(Qt.Key_Escape);
                keyboard.wait(30);
                if (window.shelfOpen) { console.error("KEYBOARD FAIL: Escape did not close theme selector"); Qt.quit(); return; }
                console.log("KEYBOARD PASS: Tab moves focus, Space opens theme selector, Escape closes it");
            }
            if (Quickshell.env("BLOX_TEST_KEYBOARD") === "1") {
                const button = harness.findItem(bundleWindow.captureItem, "included-file-expand-script");
                if (!button) { console.error("KEYBOARD FAIL: expand control missing"); Qt.quit(); return; }
                button.forceActiveFocus();
                keyboard.keyClick(Qt.Key_Space);
                let card = button.parent;
                while (card && card.expanded === undefined) card = card.parent;
                if (!card || !card.expanded) { console.error("KEYBOARD FAIL: Space did not expand script"); Qt.quit(); return; }
                keyboard.keyClick(Qt.Key_Space);
                if (card.expanded) { console.error("KEYBOARD FAIL: Space did not collapse script"); Qt.quit(); return; }
                keyboard.keyClick(Qt.Key_Space);
                console.log("KEYBOARD PASS: Space expands, collapses and expands the full script");
            }
            const surface = harness.mode.startsWith("import") || harness.mode === "export" ? bundleWindow.captureItem : harness.mode === "quick" ? quick.captureItem : window.captureItem;
            if (harness.capture.length) surface.grabToImage(result => { result.saveToFile(harness.capture); Qt.quit(); });
            else Qt.quit();
        }
    }
}
