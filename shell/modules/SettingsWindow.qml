import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.shared

FloatingWindow {
    id: root

    required property SettingsController settingsController
    property var themeEditorController: themeEditor
    property alias dialogs: editorFileDialogs
    property var draftSettingsWrites: ({})
    property var draftUserWrites: ({})
    property bool draftUserEdited: false
    property bool applyingSettingsDraft: false
    property var pendingSearchTarget: null
    property bool widgetEditing: false
    property string stagedThemeTargetsId: ""
    property bool importedSourceReloadPending: false
    property var activeWidgetsAtOpen: []
    readonly property string widgetSourceRoot: Quickshell.env("BLOX_WIDGETS_ROOT") || Quickshell.shellDir + "/../widgets"
    property alias widgetCatalogue: widgetMetadata.widgetCatalogue
    property alias widgetSchema: widgetMetadata.widgetSchema
    property alias widgetRegistry: widgetMetadata.widgetRegistry
    property alias widgetCatalogueError: widgetMetadata.widgetCatalogueError
    property alias widgetSchemaError: widgetMetadata.widgetSchemaError
    property alias widgetRegistryError: widgetMetadata.widgetRegistryError
    property alias widgetRegistryErrors: widgetMetadata.widgetRegistryErrors
    readonly property string widgetMetadataError: widgetMetadata.widgetMetadataError
    readonly property bool hasUnappliedChanges: draftUserEdited || (themeEditorController && (themeEditorController.dirty || (themeEditorController.selectedId && themeEditorController.selectedId !== Theme.activeThemeId)))
    readonly property int draftEnabledTargetCount: {
        const targets = resolvedSettings().targets || {};
        return Object.keys(targets).filter(key => targets[key].enabled).length;
    }
    SettingsThemeEditorController {
        id: themeEditor
        host: root
        pickerRootItem: frame
        editorScrollItem: detailScroll
        sourcePreparationCallback: root.prepareEditorSource
        widgetProfileProvider: function() { return root.resolvedSettings().widgets; }
        widgetProfileWriter: function(profile) { return root.writeSettingsValue("widgets", profile); }
    }
    SettingsEditorFileDialogs { id: editorFileDialogs; controller: root.themeEditorController; parentWindow: root._backingWindow }
    property bool windowOpen: false
    property bool shelfOpen: false
    property bool newMenuOpen: false
    readonly property bool themeCardMenuOpen: themeMenuState.open
    readonly property string themeCardMenuCardId: themeMenuState.cardId
    property var themeCardMenuData: ({})
    readonly property var themeCardMenuAnchor: themeMenuState.anchor
    property real themeCardMenuX: 0
    property real themeCardMenuY: 0
    property string pendingThemeAction: ""
    property string pendingThemeActionId: ""
    property bool pendingSettingsRead: false
    property string pendingSettingsRequestId: ""
    property string pendingSettingsOperation: ""
    property var pendingSettingsWrites: ({})
    property var activeSettingsWrite: ({})
    property string settingsFeedback: ""
    property string pendingThemeSelectionId: ""
    property bool pendingSearchFocus: false
    property bool syncingSection: false
    readonly property string feedbackText: themeEditorController && themeEditorController.errorMessage.length > 0 ? themeEditorController.errorMessage
        : settingsFeedback.length > 0 ? settingsFeedback
        : root.hasUnappliedChanges ? "Unapplied changes · live preview"
        : themeEditorController && themeEditorController.candidate && !themeEditorController.themeControlsEnabled
            && (shellState.category === "theme" || shellState.category === "colours")
            ? "Built-in themes are read-only. Duplicate one to edit it."
        : Theme.previewActive ? "Live preview" : ""
    readonly property var compositionProviderController: compositionController

    readonly property var libraryProvider: themeLibrary
    readonly property var bundleProvider: bundleController
    readonly property Item captureItem: frame
    readonly property bool settingsMutationPending: settingsController.busy || pendingSettingsRequestId.length > 0 || Object.keys(pendingSettingsWrites).length > 0
    readonly property bool mutationProtected: SettingsApplyController.busy || SettingsApplyController.previewPreparing || bundleController.busy

    function loadWidgetMetadata(kind, text) { widgetMetadata.loadMetadata(kind, text); }

    SettingsWidgetMetadataLoader {
        id: widgetMetadata
        active: root.windowOpen
        widgetSourceRoot: root.widgetSourceRoot
    }

    Connections {
        target: Theme
        function onWidgetEditModeFinished(widgetsJson, returnWorkspace) {
            root.widgetEditing = false; root.windowOpen = true;
        }
    }

    SettingsBundleController { id: bundleController; windowOwner: root }
    SettingsBundleFlowWindow { flowState: bundleController; settingsWindow: root }
    SettingsBundleNativeFileDialogs { flowState: bundleController; parentWindow: root }

    function navigateTo(category, page, section) {
        shellState.searchResultsOpen = false;
        shellState.category = category; shellState.page = page; shellState.section = section;
    }
    function restoreFocusAfterDialog() {
        if (detailLoader.item && detailLoader.item.focusPrimaryAction) detailLoader.item.focusPrimaryAction();
        else if (shelfOpen) themeShelfOverlay.themeSearchField.forceActiveFocus();
        else sidebar.activeThemeCard.focusAction();
    }
    function reviewApplyScripts(records) { bundleController.reviewApplyScripts(records); }
    function refreshAfterApply(preserveSettingsDraft) {
        if (preserveSettingsDraft !== true || !draftUserEdited) { draftSettingsWrites = ({}); draftUserWrites = ({}); draftUserEdited = false; }
        themeLibrary.refresh(); compositionController.refresh(); pendingSettingsRead = true; startSettingsRead();
    }
    function discardSettingsEdits() {
        draftSettingsWrites = ({}); draftUserWrites = ({}); draftUserEdited = false; settingsFeedback = "";
        if (themeEditorController) themeEditorController.revertCandidate();
        stagedThemeTargetsId = "";
        stageThemeTargets();
        Qt.callLater(previewDraftSettings);
    }
    function downloadGuideFile(target) {
        if (!themeEditorController) return;
        root.downloadGeneratedFile(target, target + "/" + (target === "stylus" ? "blox-system.user.css" : "theme.css"));
    }
    function openStylusGuide() { if (themeEditorController) themeEditorController.openGuide("stylus", ""); }
    Component.onCompleted: {
        SettingsApplyController.settingsProvider = settingsController;
        SettingsApplyController.compositionProvider = compositionController;
        SettingsApplyController.editor = themeEditorController;
        SettingsApplyController.windowOwner = root;
    }
    Binding { restoreMode: Binding.RestoreNone; target: SettingsApplyController; property: "selectedThemeId"; value: themeLibrary.selectedThemeId; when: !SettingsApplyController.externalPending && !SettingsApplyController.quickWindowOpen && !SettingsApplyController.busy && SettingsApplyController.applyState === "ready" }
    Binding { restoreMode: Binding.RestoreNone; target: SettingsApplyController; property: "selectedThemeName"; value: themeLibrary.selectedThemeName; when: !SettingsApplyController.externalPending && !SettingsApplyController.quickWindowOpen && !SettingsApplyController.busy && SettingsApplyController.applyState === "ready" }

    readonly property var activeThemeData: themeLibrary.cardFor(themeLibrary.selectedThemeId)
    readonly property var currentThemeCard: {
        const card = activeThemeData;
        if (!card || !Theme.ready || themeLibrary.selectedThemeId !== Theme.themeId)
            return card;
        return Object.assign({}, card, {
            meta: themeEditorController && themeEditorController.dirty ? card.meta + " · unsaved" : card.meta,
            wallpaper: card.wallpaper || Theme.activeWallpaperSource,
            palette: [Theme.accent, Theme.green, Theme.yellow, Theme.foreground],
            preview: Object.assign({}, card.preview, {
                background: Theme.background,
                surface: Theme.surface,
                surfaceAlt: Theme.surfaceAlt,
                foreground: Theme.foreground,
                muted: Theme.muted,
                accent: Theme.accent,
                success: Theme.green,
                warning: Theme.yellow
            }),
            previewFont: Theme.bodyFontFamily,
            barPosition: Theme.barPosition || card.barPosition,
            barCounts: [Theme.barItemsForRegion("start").length, Theme.barItemsForRegion("centre").length, Theme.barItemsForRegion("end").length]
        });
    }
    readonly property real themeShelfHeight: Math.min(frame.height - 28,
        Theme.scaledSpacing(16) + 38 + Theme.scaledSpacing(6) + (3 * 82) + (2 * Theme.scaledSpacing(5)))
    readonly property real themeShelfWidth: Math.min(265, frame.width - 28)
    readonly property real themeGeometryRevision: sidebar.activeThemeCard.x + sidebar.activeThemeCard.y
        + sidebar.activeThemeCard.width + sidebar.activeThemeCard.height + sidebar.x + sidebar.y
        + sidebar.width + sidebar.height + frame.x + frame.y + frame.width + frame.height
        + root.width + root.height
    readonly property point themeButtonPosition: {
        const revision = themeGeometryRevision;
        const activeInFrame = sidebar.activeThemeCard.mapToItem(frame, 0, 0);
        return Qt.point(frame.x + activeInFrame.x, frame.y + activeInFrame.y);
    }
    readonly property real themeShelfGap: Theme.scaledSpacing(8)
    readonly property real themeShelfX: Math.max(10,
        Math.min(root.width - themeShelfWidth - 10, themeButtonPosition.x))
    readonly property real themeShelfY: {
        const buttonBottom = themeButtonPosition.y + sidebar.activeThemeCard.height;
        const above = themeButtonPosition.y - themeShelfGap - themeShelfHeight;
        if (above >= 10)
            return above;
        return Math.max(10, Math.min(root.height - themeShelfHeight - 10,
            buttonBottom + themeShelfGap));
    }

    title: "Blox settings"
    implicitWidth: 1320
    implicitHeight: 860
    minimumSize: Qt.size(980, 660)
    visible: windowOpen && !widgetEditing
    color: "transparent"

    SettingsShellState {
        id: shellState
    }

    SettingsThemeLibrary {
        id: themeLibrary
    }

    SettingsThemeMenuState {
        id: themeMenuState
    }

    SettingsCompositionController {
        id: compositionController
        active: root.windowOpen
    }

    function openWindow() {
        activeWidgetsAtOpen = JSON.parse(JSON.stringify(Theme.widgetItems || []));
        stagedThemeTargetsId = "";
        settingsOpeningGeneration++;
        widgetEditorReadReady = false;
        windowOpen = true;
        themeEditorController.open = true;
        if (themeLibrary.status !== "loading")
            themeLibrary.refresh();
        pendingSettingsRead = true;
        Qt.callLater(startSettingsRead);
        Qt.callLater(ensureCategoryData);
        Qt.callLater(() => SettingsApplyController.request("status"));
        return "open";
    }

    property bool pendingWidgetLayoutEdit: false

    function requestWidgetLayoutEdit() {
        if (widgetEditing || mutationProtected || applyingSettingsDraft) return false;
        pendingWidgetLayoutEdit = true;
        if (!windowOpen) openWindow();
        else if (!widgetEditorReadReady) {
            pendingSettingsRead = true;
            Qt.callLater(startSettingsRead);
        }
        openSettingsSection("widgets", "widgets");
        Qt.callLater(completePendingWidgetLayoutEdit);
        return true;
    }

    function completePendingWidgetLayoutEdit() {
        if (!pendingWidgetLayoutEdit || !windowOpen || !widgetEditorReadReady || !settingsController.settings
                || mutationProtected || applyingSettingsDraft
                || !themeEditorController || !themeEditorController.candidate
                || !themeEditorController.widgetCatalogue || !themeEditorController.widgetSchema
                || !themeEditorController.widgetControlsEnabled || pendingSettingsRead || settingsMutationPending)
            return;
        pendingWidgetLayoutEdit = false;
        beginWidgetEditMode();
    }

    function completePendingWidgetRequests() {
        completePendingWidgetEditor();
        completePendingWidgetLayoutEdit();
    }

    onPendingSettingsReadChanged: Qt.callLater(completePendingWidgetRequests)
    onSettingsMutationPendingChanged: Qt.callLater(completePendingWidgetRequests)
    onMutationProtectedChanged: Qt.callLater(completePendingWidgetRequests)
    onApplyingSettingsDraftChanged: Qt.callLater(completePendingWidgetRequests)
    onWindowOpenChanged: {
        if (!windowOpen) {
            pendingWidgetLayoutEdit = false;
            pendingWidgetEditorId = "";
            widgetEditorReadReady = false;
            settingsOpeningGeneration++;
        }
    }

    property string pendingWidgetEditorId: ""
    property bool widgetEditorReadReady: false
    property int settingsOpeningGeneration: 0
    property int pendingSettingsReadGeneration: 0

    function openWidgetEditor(widgetId) {
        const profile = resolvedSettings().widgets;
        const widgets = profile && profile.schemaVersion === 1 && Array.isArray(profile.widgets) ? profile.widgets
            : !settingsController.settings ? Theme.widgetItems : [];
        if (!Array.isArray(widgets) || !widgets.some(widget => widget.id === widgetId))
            return false;
        pendingWidgetEditorId = widgetId;
        if (!windowOpen) openWindow();
        else if (!widgetEditorReadReady) {
            pendingSettingsRead = true;
            Qt.callLater(startSettingsRead);
        }
        openSettingsSection("widgets", "widgets");
        Qt.callLater(completePendingWidgetEditor);
        return true;
    }

    function completePendingWidgetEditor() {
        if (!windowOpen || !pendingWidgetEditorId || !widgetEditorReadReady || !settingsController.settings
                || pendingSettingsRead || settingsMutationPending || mutationProtected || applyingSettingsDraft
                || !themeEditorController || !themeEditorController.candidate
                || !themeEditorController.widgetControlsEnabled
                || !themeEditorController.widgetCatalogue || !themeEditorController.widgetSchema)
            return;
        const index = themeEditorController.widgetItems().findIndex(widget => widget.id === pendingWidgetEditorId);
        pendingWidgetEditorId = "";
        if (index < 0) {
            settingsFeedback = "The widget no longer exists.";
            return;
        }
        themeEditorController.openWidgetEditor(index);
    }

    Connections {
        target: root.themeEditorController
        function onWidgetCatalogueChanged() { root.completePendingWidgetRequests(); }
        function onWidgetSchemaChanged() { root.completePendingWidgetRequests(); }
        function onCandidateChanged() { Qt.callLater(root.completePendingWidgetRequests); }
        function onWidgetControlsEnabledChanged() { Qt.callLater(root.completePendingWidgetRequests); }
    }

    function closeWindow() {
        if (mutationProtected || applyingSettingsDraft) return "busy";
        if (hasUnappliedChanges) { closeConfirmation.open(); return "confirmation-required"; }
        return discardAndClose();
    }

    function discardAndClose() {
        draftSettingsWrites = ({});
        draftUserWrites = ({});
        draftUserEdited = false;
        stagedThemeTargetsId = "";
        settingsFeedback = "";
        applyingSettingsDraft = false;
        if (themeEditorController) themeEditorController.closePicker();
        else Theme.cancelPreview();
        if (themeEditorController && themeEditorController.colourPickerOpen)
            themeEditorController.dismissColourPicker();
        windowOpen = false;
        newMenuOpen = false;
        shelfOpen = false;
        closeThemeCardMenu();
        return "closed";
    }

    function startSettingsRead() {
        if (!pendingSettingsRead || pendingSettingsRequestId.length > 0 || !settingsController)
            return;
        if (settingsController.recovering || settingsController.busy) {
            settingsReadTimer.restart();
            return;
        }
        let action = null;
        widgetEditorReadReady = false;
        try {
            action = JSON.parse(settingsController.begin("get", "{}"));
            if (!action || typeof action.code !== "string") throw new Error("Invalid Settings response");
        } catch (error) {
            pendingSettingsRead = false;
            pendingWidgetEditorId = "";
            pendingWidgetLayoutEdit = false;
            settingsFeedback = "Could not load Settings.";
            return;
        }
        if (action && action.code === "pending" && action.data && action.data.requestId) {
            pendingSettingsRequestId = action.data.requestId;
            pendingSettingsOperation = "get";
            pendingSettingsReadGeneration = settingsOpeningGeneration;
            settingsReadTimer.start();
        } else if (action && action.code !== "busy") {
            pendingSettingsRead = false;
            pendingWidgetEditorId = "";
            pendingWidgetLayoutEdit = false;
            settingsFeedback = action.message || "Could not load Settings.";
        } else {
            settingsReadTimer.restart();
        }
    }

    function pollSettingsRead() {
        if (pendingSettingsRequestId.length === 0) {
            if (pendingSettingsRead)
                startSettingsRead();
            else
                startNextSettingsWrite();
            return;
        }
        let action = null;
        try {
            action = JSON.parse(settingsController.poll(pendingSettingsRequestId));
            if (!action || typeof action.code !== "string") throw new Error("Invalid Settings response");
        } catch (error) {
            const retryOpening = pendingSettingsOperation === "get"
                && pendingSettingsReadGeneration !== settingsOpeningGeneration && windowOpen;
            if (pendingSettingsOperation === "get" && !retryOpening)
                settingsFeedback = "Could not load Settings.";
            if (pendingSettingsOperation === "set-draft") {
                applyingSettingsDraft = false;
                settingsFeedback = "Could not read the Settings save result.";
                SettingsApplyController.abortPreparation(settingsFeedback);
            }
            pendingSettingsRead = retryOpening;
            widgetEditorReadReady = false;
            if (!retryOpening) {
                pendingWidgetEditorId = "";
                pendingWidgetLayoutEdit = false;
            }
            pendingSettingsOperation = "";
            pendingSettingsRequestId = "";
            if (retryOpening) Qt.callLater(startSettingsRead);
            return;
        }
        if (!action || action.code === "pending") {
            settingsReadTimer.restart();
            return;
        }
        const operation = pendingSettingsOperation;
        pendingSettingsOperation = "";
        pendingSettingsRequestId = "";
        if (operation === "get") {
            if (pendingSettingsReadGeneration !== settingsOpeningGeneration) {
                pendingSettingsRead = windowOpen;
                if (windowOpen) Qt.callLater(startSettingsRead);
                return;
            }
            widgetEditorReadReady = action.ok === true;
            pendingSettingsRead = false;
            if (!action.ok) {
                pendingWidgetEditorId = "";
                pendingWidgetLayoutEdit = false;
                settingsFeedback = action.message || "Could not load Settings.";
                pendingSettingsWrites = ({});
            } else {
                stageThemeTargets();
                if (Object.keys(pendingSettingsWrites).length > 0)
                    Qt.callLater(startNextSettingsWrite);
            }
            return;
        }
        activeSettingsWrite = ({});
        if (!action.ok && operation === "set-draft") {
            applyingSettingsDraft = false;
            SettingsApplyController.abortPreparation(action.code === "conflict"
                ? "Settings changed elsewhere. Reload before applying."
                : action.message || "Could not save Settings before Apply.");
        }
        if (action.code === "conflict") {
            pendingSettingsWrites = ({});
            settingsFeedback = "Settings changed elsewhere. Reload before making another change.";
            pendingSettingsRead = true;
        } else if (!action.ok) {
            pendingSettingsWrites = ({});
            settingsFeedback = action.message || "Could not save this setting.";
        } else {
            settingsFeedback = "";
            if (operation === "set-draft") {
                draftSettingsWrites = ({}); draftUserWrites = ({}); draftUserEdited = false; applyingSettingsDraft = false;
                Qt.callLater(() => SettingsApplyController.startApply());
            }
            if (Object.keys(pendingSettingsWrites).length > 0)
                Qt.callLater(startNextSettingsWrite);
        }
        if (pendingSettingsRead)
            settingsReadTimer.restart();
    }

    function writeSettingsValue(path, value) {
        if (mutationProtected || applyingSettingsDraft || !path) return false;
        draftSettingsWrites = Object.assign({}, draftSettingsWrites, {[path]: value});
        draftUserWrites = Object.assign({}, draftUserWrites, {[path]: value});
        draftUserEdited = true;
        SettingsApplyController.contextChanged();
        settingsFeedback = "";
        previewDraftSettings();
        if (path.startsWith("osd.")) Theme.osdPositionPreviewRequested();
        else if (path.startsWith("notifications.")) Theme.notificationPositionPreviewRequested();
        return true;
    }

    function resolvedSettings() {
        const result = JSON.parse(JSON.stringify(settingsController.settings || {}));
        Object.keys(draftSettingsWrites).forEach(path => {
            const parts = path.split("."); let node = result;
            parts.slice(0, -1).forEach(key => { if (!node[key]) node[key] = {}; node = node[key]; });
            node[parts[parts.length - 1]] = draftSettingsWrites[path];
        });
        return result;
    }

    function prepareSettingsForApply() {
        if (applyingSettingsDraft || settingsMutationPending) return false;
        // Theme selection stages its source once. A completed save leaves Settings in charge.
        const paths = Object.keys(draftSettingsWrites);
        if (!paths.length) {
            return true;
        }
        const value = resolvedSettings(); const sections = {};
        paths.forEach(path => sections[path.split(".")[0]] = value[path.split(".")[0]]);
        let action = null;
        try {
            action = JSON.parse(settingsController.begin("set-sections", JSON.stringify({sections: sections, expectedRevision: settingsController.revision})));
        } catch (error) {
            settingsFeedback = "Could not read the Settings save request.";
            SettingsApplyController.abortPreparation(settingsFeedback);
            return false;
        }
        if (!action || action.code !== "pending") {
            settingsFeedback = action && action.message || "Could not save the changes before Apply.";
            SettingsApplyController.abortPreparation(settingsFeedback);
            return false;
        }
        applyingSettingsDraft = true;
        pendingSettingsRequestId = action.data.requestId;
        pendingSettingsOperation = "set-draft";
        settingsReadTimer.start();
        return false;
    }

    function stageThemeTargets() {
        if (!windowOpen || !themeEditorController || !themeEditorController.candidate
                || !widgetEditorReadReady || pendingSettingsRead || themeEditorController.busy
                || importedSourceReloadPending || stagedThemeTargetsId === themeEditorController.selectedId) return;
        const candidate = themeEditorController.candidate;
        const targets = candidate.targets || {};
        const next = Object.assign({}, draftSettingsWrites);
        Object.keys(targets).forEach(key => {
            const target = targets[key];
            next["targets." + key + ".enabled"] = typeof target === "boolean" ? target : target.enabled === true;
        });
        const shell = candidate.shell || {};
        const aliases = {separate_groups:"separateGroups", edge_inset:"edgeInset", radius_scale:"radiusScale", density_scale:"densityScale", radius_automatic:"radiusAutomatic", density_automatic:"densityAutomatic", offset_x:"offsetX", offset_y:"offsetY"};
        Object.keys(shell.bar || {}).forEach(key => {
            const path = key === "items" ? "bar.items" : "bar." + (["position", "separate_groups"].indexOf(key) >= 0 ? "layout." : "style.") + (aliases[key] || key);
            next[path] = shell.bar[key];
        });
        ["osd", "notifications"].forEach(section => Object.keys(shell[section] || {}).forEach(key => next[section + "." + (aliases[key] || key)] = shell[section][key]));
        const saved = settingsController.settings;
        const source = themeEditorController.sourceTheme;
        const savedOwnsWidgets = candidate.id === Theme.activeThemeId
            || source && !Object.prototype.hasOwnProperty.call(source, "widgets");
        if (savedOwnsWidgets && saved && Object.prototype.hasOwnProperty.call(saved, "widgets"))
            next.widgets = JSON.parse(JSON.stringify(saved.widgets));
        else if (Object.prototype.hasOwnProperty.call(candidate, "widgets"))
            next.widgets = JSON.parse(JSON.stringify(candidate.widgets));
        ["gtk", "hyprlock"].forEach(key => next["targets." + key + ".overrides"] = candidate.overrides && candidate.overrides[key] || {});
        // A delayed theme load must preserve the settings the user has already changed.
        draftSettingsWrites = Object.assign(next, draftUserWrites);
        stagedThemeTargetsId = themeEditorController.selectedId;
    }

    function prepareEditorSource(value, source) {
        const candidate = JSON.parse(JSON.stringify(value));
        const raw = source && typeof source === "object" ? source : value;
        const settings = settingsController.settings;
        const savedOwnsWidgets = candidate.id === Theme.activeThemeId
            || !Object.prototype.hasOwnProperty.call(raw, "widgets");
        if (savedOwnsWidgets && settings && Object.prototype.hasOwnProperty.call(settings, "widgets"))
            candidate.widgets = JSON.parse(JSON.stringify(settings.widgets));
        return candidate;
    }

    function previewDraftSettings() {
        if (!windowOpen || !themeEditorController || !themeEditorController.candidate) return;
        const settings = resolvedSettings();
        const shell = JSON.parse(JSON.stringify(themeEditorController.candidate.shell || {}));
        const bar = Object.assign({}, shell.bar || {});
        const names = {separateGroups:"separate_groups", edgeInset:"edge_inset", radiusScale:"radius_scale", densityScale:"density_scale", radiusAutomatic:"radius_automatic", densityAutomatic:"density_automatic", offsetX:"offset_x", offsetY:"offset_y"};
        let changed = false;
        Object.keys(draftSettingsWrites).forEach(path => {
            const parts = path.split("."); const value = draftSettingsWrites[path];
            if (parts[0] === "bar") {
                if (parts[1] === "items") bar.items = value;
                else bar[names[parts[2]] || parts[2]] = value;
                changed = true;
            } else if (parts[0] === "osd" || parts[0] === "notifications") {
                if (!shell[parts[0]]) shell[parts[0]] = {};
                shell[parts[0]][names[parts[1]] || parts[1]] = value;
                changed = true;
            }
        });
        if (changed) { shell.bar = bar; Theme.previewActive = true; Theme.loadShell(shell); }
        if (Object.prototype.hasOwnProperty.call(draftSettingsWrites, "widgets")) {
            Theme.previewActive = true;
            Theme.loadWidgetSource(settings.widgets);
        }
    }

    function focusModal() { settingsThemeModal.focusInitial(); }

    function beginWidgetEditMode() {
        if (!themeEditorController || !themeEditorController.widgetControlsEnabled || mutationProtected || applyingSettingsDraft)
            return false;
        widgetEditing = true;
        if (!themeEditorController.openWidgetEditMode()) {
            widgetEditing = false;
            return false;
        }
        return true;
    }

    function settingsValue(path, fallback) {
        if (Object.prototype.hasOwnProperty.call(draftSettingsWrites, path)) return draftSettingsWrites[path];
        if (Object.prototype.hasOwnProperty.call(pendingSettingsWrites, path))
            return pendingSettingsWrites[path];
        if (Object.prototype.hasOwnProperty.call(activeSettingsWrite, path))
            return activeSettingsWrite[path];
        let value = settingsController && settingsController.settings;
        for (const segment of String(path).split(".")) {
            if (!value || value[segment] === undefined)
                return fallback;
            value = value[segment];
        }
        return value === undefined || value === null ? fallback : value;
    }

    function startNextSettingsWrite() {
        if (!settingsController || pendingSettingsRequestId.length > 0 || settingsController.busy)
            return;
        if (!settingsController.settings) {
            pendingSettingsRead = true;
            startSettingsRead();
            return;
        }
        const paths = Object.keys(pendingSettingsWrites);
        if (paths.length === 0)
            return;
        const path = paths[0];
        const value = pendingSettingsWrites[path];
        const request = {
            path: path,
            valueJson: JSON.stringify(value),
            expectedRevision: settingsController.revision
        };
        let action = null;
        try {
            action = JSON.parse(settingsController.begin("set", JSON.stringify(request)));
        } catch (error) {
            settingsFeedback = "Could not save this setting.";
            return;
        }
        if (action && action.code === "pending" && action.data && action.data.requestId) {
            const next = Object.assign({}, pendingSettingsWrites);
            delete next[path];
            pendingSettingsWrites = next;
            activeSettingsWrite = ({[path]: value});
            pendingSettingsRequestId = action.data.requestId;
            pendingSettingsOperation = "set";
            settingsReadTimer.start();
            return;
        }
        if (action && action.code === "busy")
            settingsReadTimer.restart();
        else {
            activeSettingsWrite = ({});
            settingsFeedback = action && action.message ? action.message : "Could not save this setting.";
            pendingSettingsWrites = ({});
        }
    }

    function openSettingsColourPicker(key, target, focusItem, value, applyCallback) {
        if (!themeEditorController || !themeEditorController.candidate)
            return;
        themeEditorController.colourPickerHost = root;
        themeEditorController.overlayFocusTarget = focusItem;
        themeEditorController.externalColourApply = (colourKey, colourTarget, hex) => {
            if (colourTarget === "ansi")
                themeEditorController.setOverride("ansi", colourKey, hex);
            else if (!colourTarget && typeof applyCallback === "function")
                applyCallback(hex);
        };
        themeEditorController.externalColourCommit = (colourKey, colourTarget, hex) => {
            if (colourTarget && colourTarget !== "ansi")
                saveTargetOverride(colourTarget, colourKey, hex);
        };
        themeEditorController.externalColourClear = (colourKey, colourTarget) => {
            if (colourTarget === "ansi") {
                themeEditorController.setOverride("ansi", colourKey, "");
                return;
            }
            if (colourTarget) {
                themeEditorController.externalColourApply = null;
                themeEditorController.externalColourCommit = null;
                themeEditorController.externalColourClear = null;
                saveTargetOverride(colourTarget, colourKey, "");
            }
        };
        themeEditorController.openColourPicker(key, target);
        themeEditorController.loadPickerColour(value);
    }

    function saveTargetOverride(target, key, value) {
        const overrides = Object.assign({}, settingsValue("targets." + target + ".overrides", {}));
        if (value)
            overrides[key] = value;
        else
            delete overrides[key];
        writeSettingsValue("targets." + target + ".overrides", overrides);
    }

    function clearTargetOverride(target, key) {
        saveTargetOverride(target, key, "");
    }

    function focusColourPicker() {
        settingsColourPicker.focusEditor();
    }

    function downloadGeneratedFile(target, file) {
        if (!themeEditorController || !themeEditorController.host || !themeEditorController.host.dialogs)
            return;
        themeEditorController.host.dialogs.externalParentWindow = root._backingWindow;
        themeEditorController.downloadGeneratedFile(target, file);
    }

    function downloadGeneratedArchive(target) {
        if (!themeEditorController || !themeEditorController.host || !themeEditorController.host.dialogs)
            return;
        themeEditorController.host.dialogs.externalParentWindow = root._backingWindow;
        themeEditorController.downloadGeneratedArchive(target);
    }

    function ensureCategoryData() {
        if (shellState.category === "theme" || shellState.category === "colours"
                || shellState.category === "bar" || shellState.category === "bar-items" || shellState.category === "widgets"
                || shellState.category === "windows" || shellState.category === "targets"
                || (shellState.category === "bar" && shellState.page === "advanced"))
            ensureThemeEditor();
        if (!themeEditorController)
            return;
        if (shellState.category === "theme" && !themeEditorController.wallpapersLoaded)
            themeEditorController.refreshWallpapers();
        if (shellState.category === "colours" && !themeEditorController.iconThemesLoaded)
            themeEditorController.refreshIconThemes();
        if (shellState.category === "targets") {
            if (!themeEditorController.browserTargetsLoaded)
                themeEditorController.refreshBrowserTargets();
            compositionController.refresh();
        }
    }

    function syncThemeSelection() {
        if (!themeEditorController || !themeEditorController.candidate
                || themeEditorController.selectedId.length === 0)
            return;
        if (pendingThemeSelectionId.length > 0 && !themeEditorController.dirty) {
            const wanted = pendingThemeSelectionId;
            if (wanted !== themeEditorController.selectedId) {
                Qt.callLater(() => themeEditorController.requestSelection(wanted, false));
                return;
            }
            pendingThemeSelectionId = "";
        }
        themeLibrary.selectedThemeId = themeEditorController.selectedId;
    }

    function selectTheme(themeId, reloadSource) {
        if (mutationProtected) return false;
        if ((reloadSource === true && draftUserEdited) || (themeEditorController && themeEditorController.dirty
                && (reloadSource === true || themeEditorController.selectedId !== themeId))) {
            settingsFeedback = "Apply or discard the current theme edits before switching themes.";
            return false;
        }
        const result = themeLibrary.selectTheme(themeId);
        if (!result.ok || !themeEditorController)
            return false;
        SettingsApplyController.contextChanged();
        if (!themeEditorController.candidate) {
            pendingThemeSelectionId = themeId;
            ensureThemeEditor();
            return true;
        }
        pendingThemeSelectionId = "";
        // Imported sections already passed through Settings; opening their source
        // must not stage unrelated theme defaults over the reviewed selection.
        if (reloadSource === true) {
            stagedThemeTargetsId = themeId;
            importedSourceReloadPending = true;
        }
        if (themeEditorController.selectedId !== themeId || reloadSource === true)
            themeEditorController.requestSelection(themeId, false, reloadSource === true);
        return true;
    }

    function ensureThemeEditor() {
        if (!themeEditorController || themeEditorController.busy)
            return;
        themeEditorController.colourPickerHost = root;
        if (themeEditorController.candidate) {
            if (pendingThemeSelectionId.length > 0 && !themeEditorController.dirty
                    && pendingThemeSelectionId !== themeEditorController.selectedId)
                themeEditorController.requestSelection(pendingThemeSelectionId, false);
            return;
        }
        themeEditorController.refreshBrowserTargets();
        themeEditorController.refreshWallpapers();
        themeEditorController.refreshIconThemes();
        themeEditorController.loadForSettings();
    }

    function openSettingsSection(category, section) {
        shellState.openSection(category, section);
    }

    function openThemeCardMenu(card, anchor, keyboardOpened) {
        if (!card || !anchor)
            return;
        if (themeCardMenuOpen && themeCardMenuCardId === card.id) {
            closeThemeCardMenu();
            return;
        }
        newMenuOpen = false;
        const point = anchor.mapToItem(frame, 0, 0);
        const menuWidth = themeShelfOverlay.themeCardMenuOverlay.width;
        const menuHeight = themeShelfOverlay.themeCardMenuOverlay.height;
        const position = themeMenuState.positionFor(point, Qt.size(anchor.width, anchor.height),
            Qt.size(menuWidth, menuHeight), Qt.size(frame.width, frame.height));
        themeCardMenuX = position.x;
        themeCardMenuY = position.y;
        themeCardMenuData = themeLibrary.cardFor(card.id) || card;
        themeMenuState.openMenu(card.id, anchor, keyboardOpened, themeShelfOverlay.themeMenuExportButton);
    }

    function closeThemeCardMenu(cardId) {
        if (cardId && themeCardMenuCardId !== cardId)
            return;
        themeMenuState.closeMenu(shelfOpen);
    }

    function updateShelfCursor(raw) { shelfCursorTracker.updateShelfCursor(raw); }
    function setShelfCursor(point) { shelfCursorTracker.setShelfCursor(point); }
    function syncThemeCardHover() { shelfCursorTracker.syncThemeCardHover(); }

    function requestThemeAction(action, themeId) {
        if (mutationProtected) return;
        if (action === "import") { bundleController.importBundle(); return; }
        if (action === "export") { bundleController.exportBundle(themeId); return; }
        if (!themeEditorController || themeEditorController.busy || themeEditorController.dirty)
            return;
        pendingThemeAction = action;
        pendingThemeActionId = themeId || "";
        ensureThemeEditor();
        themeActionTimer.restart();
    }

    function runThemeAction() {
        if (!themeEditorController || themeEditorController.busy)
            return;
        if (themeEditorController.dirty) {
            pendingThemeAction = "";
            return;
        }
        if (!themeEditorController.candidate)
            return;
        if (pendingThemeActionId.length > 0 && themeEditorController.selectedId !== pendingThemeActionId) {
            themeEditorController.requestSelection(pendingThemeActionId, false);
            return;
        }
        if (pendingThemeAction === "new-blank")
            themeEditorController.openNewTheme(false);
        else if (pendingThemeAction === "new-wallpaper")
            themeEditorController.openNewTheme(true);
        else if (pendingThemeAction === "duplicate")
            themeEditorController.openDuplicate(pendingThemeActionId, themeCardMenuData.name);
        else if (pendingThemeAction === "rename")
            themeEditorController.openRename(pendingThemeActionId, themeCardMenuData.name);
        else if (pendingThemeAction === "delete")
            themeEditorController.requestDelete(pendingThemeActionId, themeCardMenuData.name,
                themeCardMenuData.builtin === true);
        pendingThemeAction = "";
    }

    onShelfOpenChanged: {
        Qt.callLater(() => {
            if (shelfOpen)
                themeShelfOverlay.themeSearchField.forceActiveFocus();
            else
                sidebar.activeThemeCard.focusAction();
        });
    }
    property alias shelfCursor: shelfCursorTracker.shelfCursor

    SettingsThemeShelfCursor {
        id: shelfCursorTracker
        frameItem: frame
        themeShelfOverlay: themeShelfOverlay
        shelfOpen: root.shelfOpen
        themeCardMenuOpen: root.themeCardMenuOpen
    }

    onNewMenuOpenChanged: Qt.callLater(() => {
        if (newMenuOpen)
            themeShelfOverlay.newFromBlankButton.forceActiveFocus();
        else if (shelfOpen && !themeCardMenuOpen)
            themeShelfOverlay.newThemeToggleButton.forceActiveFocus();
    })

    onClosed: { if (!widgetEditing) { windowOpen = true; Qt.callLater(closeWindow); } }

    function createFromWallpaper() {
        if (!windowOpen) openWindow();
        requestThemeAction("new-wallpaper", "");
        return "opening";
    }

    function status() {
        return JSON.stringify({open: windowOpen, category: shellState.category,
            page: shellState.page, section: shellState.section, theme: themeLibrary.selectedThemeId});
    }

    Timer {
        id: settingsReadTimer
        interval: 80
        repeat: false
        onTriggered: root.pollSettingsRead()
    }

    Timer {
        id: themeActionTimer
        interval: 120
        repeat: true
        running: root.pendingThemeAction.length > 0
        onTriggered: root.runThemeAction()
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        anchors.margins: 1
        color: Theme.background
        border.color: Theme.border
        border.width: 1
        radius: Theme.scaledRadius(8)
        clip: true
        focus: true

        Keys.onEscapePressed: event => {
            if (root.themeCardMenuOpen)
                root.closeThemeCardMenu();
            else if (root.newMenuOpen)
                root.newMenuOpen = false;
            else if (root.shelfOpen)
                root.shelfOpen = false;
            else if (shellState.searchResultsOpen) {
                shellState.searchResultsOpen = false;
                root.loadPage();
                sidebar.searchField.forceActiveFocus();
            } else {
                event.accepted = false;
                return;
            }
            event.accepted = true;
        }

        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: eventPoint => {
                const fieldPosition = sidebar.searchField.mapToItem(frame, 0, 0);
                const point = eventPoint.position;
                const insideSearch = point.x >= fieldPosition.x
                    && point.x <= fieldPosition.x + sidebar.searchField.width
                    && point.y >= fieldPosition.y
                    && point.y <= fieldPosition.y + sidebar.searchField.height;
                if (!insideSearch)
                    frame.forceActiveFocus();
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(12)
            spacing: Theme.scaledSpacing(14)

            SettingsSidebar {
                id: sidebar
                windowOwner: root
                shellState: shellState
                frameItem: frame
                Layout.preferredWidth: 254
                Layout.minimumWidth: 242
                Layout.maximumWidth: 264
                Layout.fillHeight: true
            }

            Rectangle {
                id: detailPanel
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.background

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Theme.scaledSpacing(10)

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        spacing: Theme.scaledSpacing(6)
                        Repeater {
                            model: shellState.breadcrumbs()
                            RowLayout {
                                required property var modelData
                                required property int index
                                spacing: Theme.scaledSpacing(6)
                                Item {
                                    objectName: "breadcrumb-" + index
                                    Layout.preferredWidth: crumbText.implicitWidth
                                    Layout.preferredHeight: 30
                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: shellState.openBreadcrumb(index)
                                    Keys.onSpacePressed: shellState.openBreadcrumb(index)
                                    Text {
                                        id: crumbText
                                        objectName: "breadcrumb-label-" + index
                                        anchors.fill: parent
                                        text: modelData.label
                                        color: index === shellState.breadcrumbs().length - 1 ? Theme.foreground : Theme.blue
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 19
                                        font.bold: index === shellState.breadcrumbs().length - 1
                                        font.underline: index < shellState.breadcrumbs().length - 1 && (parent.activeFocus || crumbPointer.containsMouse)
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    MouseArea {
                                        id: crumbPointer
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: index < shellState.breadcrumbs().length - 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: shellState.openBreadcrumb(index)
                                    }
                                }
                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.preferredWidth: 14
                                    Layout.preferredHeight: 32
                                    visible: index < shellState.breadcrumbs().length - 1
                                    text: "›"
                                    color: Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 19
                                    verticalAlignment: Text.AlignVCenter
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    Flickable {
                        id: detailScroll
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width - (detailScroll.contentHeight > detailScroll.height ? 10 : 0)
                        contentHeight: detailLoader.item ? detailLoader.item.implicitHeight : 0
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        BloxWheelHandler { flickable: detailScroll }
                        onContentYChanged: {
                            if (!detailLoader.item || !detailLoader.item.sectionAt)
                                return;
                            const activeSection = detailLoader.item.sectionAt(contentY);
                            if (activeSection && shellState.section !== activeSection) {
                                root.syncingSection = true;
                                shellState.section = activeSection;
                                root.syncingSection = false;
                            }
                        }

                        Loader {
                            id: detailLoader
                            enabled: !root.mutationProtected || shellState.category === "review"
                            width: detailScroll.contentWidth
                            sourceComponent: shellState.searchResultsOpen ? searchResultsPage : root.routePageComponent()
                            onLoaded: {
                                if (shellState.searchResultsOpen && root.pendingSearchFocus && item && item.focusFirstResult)
                                    Qt.callLater(() => item.focusFirstResult());
                                else if (!shellState.searchResultsOpen && shellState.section.length > 0 && item && item.jumpToSection)
                                    Qt.callLater(() => root.highlightSearchTarget(item));
                                root.pendingSearchFocus = false;
                            }
                        }

                        ScrollBar.vertical: ScrollBar {
                            id: detailScrollbar
                            width: 8
                            policy: detailScroll.contentHeight > detailScroll.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                            background: Rectangle { radius: Theme.scaledRadius(3); color: Theme.withAlpha(Theme.foreground, 0.04) }
                            contentItem: Rectangle { implicitWidth: 4; radius: Theme.scaledRadius(3); color: detailScrollbar.hovered || detailScrollbar.pressed ? Theme.foreground : Theme.muted }
                        }
                    }


                }
            }
        }

        SettingsThemeShelfOverlay {
            id: themeShelfOverlay
            anchors.fill: parent
            z: 19
            windowOwner: root
            themeLibrary: themeLibrary
            frameItem: frame
        }

        SettingsEditorModal {
            id: settingsThemeModal
            anchors.fill: parent
            controller: root.themeEditorController
            visible: root.windowOpen && root.themeEditorController && root.themeEditorController.modalKind.length > 0
        }
        Popup {
            id: closeConfirmation
            parent: frame
            anchors.centerIn: parent
            width: Math.min(460, frame.width - 40)
            modal: true
            padding: Theme.scaledSpacing(20)
            background: Rectangle { color: Theme.surface; radius: Theme.scaledRadius(10); border.color: Theme.border }
            contentItem: ColumnLayout {
                spacing: Theme.scaledSpacing(16)
                Text { text: "Discard unapplied changes?"; color: Theme.foreground; font.family: Theme.bodyFontFamily; font.pixelSize: 19; font.bold: true }
                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    BloxButton { text: "Keep editing"; onClicked: closeConfirmation.close() }
                    BloxButton { text: "Discard and close"; destructive: true; onClicked: { closeConfirmation.close(); root.discardAndClose(); } }
                }
            }
        }

        SettingsColourPicker {
            id: settingsColourPicker
            anchors.fill: parent
            controller: root.themeEditorController
            visible: root.windowOpen && root.themeEditorController
                && root.themeEditorController.colourPickerOpen
        }
    }

    Component {
        id: searchResultsPage
        SettingsSearchResults {
            state: shellState
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: routePageHeader
        Text {
            width: detailScroll.contentWidth
            text: shellState.pageTitle
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 26
            font.bold: true
        }
    }

    Component {
        id: themePage
        SettingsThemePage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: themeAdvancedPage
        SettingsThemeAdvancedPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: coloursPage
        SettingsColoursPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: windowsPage
        SettingsWindowsPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: barPage
        SettingsBarPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: barAdvancedPage
        SettingsBarAdvancedPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: barItemsPage
        SettingsBarItemsPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: widgetsPage
        SettingsWidgetsPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    Component {
        id: targetsPage
        SettingsTargetsPage {
            windowOwner: root
            scrollHost: detailScroll
            width: detailScroll.contentWidth
        }
    }

    SettingsDriftReviewLayer { flowState: SettingsApplyController; settingsWindow: root; parent: root.contentItem }

    Component {
        id: applyReviewPage
        SettingsApplyReviewPage { windowOwner: root; flowState: SettingsApplyController; scrollHost: detailScroll; width: detailScroll.contentWidth }
    }

    function routePageComponent() {
        if (shellState.category === "review") return applyReviewPage;
        if (shellState.category === "theme")
            return shellState.page === "advanced" ? themeAdvancedPage : themePage;
        if (shellState.category === "colours")
            return coloursPage;
        if (shellState.category === "windows")
            return windowsPage;
        if (shellState.category === "bar")
            return shellState.page === "advanced" ? barAdvancedPage : barPage;
        if (shellState.category === "bar-items")
            return barItemsPage;
        if (shellState.category === "widgets")
            return widgetsPage;
        if (shellState.category === "targets")
            return targetsPage;
        return routePageHeader;
    }

    function loadPage() {
        closeThemeCardMenu();
        ensureCategoryData();
        detailScroll.contentY = 0;
        detailLoader.sourceComponent = null;
        Qt.callLater(() => {
            if (root.windowOpen)
                detailLoader.sourceComponent = shellState.searchResultsOpen ? searchResultsPage : root.routePageComponent();
        });
    }

    function acceptSearch() {
        const suggestions = shellState.suggestionResults();
        if (sidebar.suggestionPopup.visible && suggestions.length > 0) {
            sidebar.suggestionPopup.close();
            root.openSearchResult(suggestions[Math.min(shellState.suggestionIndex, suggestions.length - 1)]);
        } else {
            root.openAllSearchResults();
        }
    }

    function openAllSearchResults() {
        sidebar.suggestionPopup.close();
        const matches = shellState.searchResults();
        if (matches.length === 1) {
            root.openSearchResult(matches[0]);
            return true;
        }
        root.pendingSearchTarget = null;
        root.pendingSearchFocus = matches.length > 0;
        if (shellState.openAllSearchResults()) {
            root.loadPage();
            return true;
        }
        return false;
    }

    function highlightSearchTarget(pageItem) {
        if (pendingSearchTarget && shellState.selectedSearchLabel.length > 0 && pageItem.jumpToTarget) {
            const target = pendingSearchTarget;
            pageItem.jumpToTarget(target.section, target.label, target.kind || "Setting");
        } else if (pageItem.jumpToSection) pageItem.jumpToSection(shellState.section);
    }

    function openSearchResult(result) {
        const wasShowingResults = shellState.searchResultsOpen;
        pendingSearchTarget = result;
        shellState.openSearchResult(result);
        root.pendingSearchFocus = false;
        if (wasShowingResults || !shellState.searchResultsOpen)
            root.loadPage();
    }

    Connections {
        target: shellState
        function onCategoryChanged() { root.loadPage(); }
        function onPageChanged() { root.loadPage(); }
        function onSearchResultsOpenChanged() { root.loadPage(); }
        function onSectionChanged() {
            const pageItem = detailLoader.item;
            const sectionId = shellState.section;
            if (root.syncingSection || sectionId.length === 0 || !pageItem || !pageItem.jumpToSection)
                return;
            Qt.callLater(() => {
                if (detailLoader.item === pageItem && pageItem.jumpToSection)
                    root.highlightSearchTarget(pageItem);
            });
        }
    }

    Connections {
        target: root.themeEditorController
        function onSelectedIdChanged() { root.stageThemeTargets(); }
        function onCandidateRevisionChanged() {
            if (root.themeEditorController.dirty && !root.applyingSettingsDraft)
                SettingsApplyController.contextChanged();
            Qt.callLater(root.previewDraftSettings);
        }
        function onPreviewDataChanged() { Qt.callLater(root.previewDraftSettings); }
        function onBusyChanged() {
            if (!root.themeEditorController.busy) {
                root.syncThemeSelection();
                // The API assigns its loaded candidate after releasing busy.
                Qt.callLater(() => {
                    if (!root.themeEditorController.busy) root.importedSourceReloadPending = false;
                });
            }
            root.stageThemeTargets();
            if (root.windowOpen) Qt.callLater(root.previewDraftSettings);
        }
        function onColourPickerOpenChanged() {
            if (!root.themeEditorController.colourPickerOpen)
                Qt.callLater(() => root.themeEditorController.restoreOverlayFocus());
        }
    }
}
