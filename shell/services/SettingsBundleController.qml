import QtQuick
import qs.services
import Quickshell
import Quickshell.Io

// Bundle requests are transient. Script approvals always carry the reviewed digest.
Scope {
    id: root
    required property var windowOwner
    property string dialogKind: ""
    property string bundleFlowKind: ""
    property string bundleStep: ""
    property string bundleOperationState: ""
    property string bundleLevel: "standard"
    property string bundleFileName: ""
    property string bundleDestination: ""
    property string exportThemeId: ""
    property var importedCard: ({id: "", name: "Theme", palette: []})
    property var selectedExportComponents: componentsFor("standard")
    property var selectedExportTargets: []
    property var selectedImportSections: []
    property var importSectionRows: []
    property var sensitiveImportFiles: []
    property var approvedSensitiveFiles: []
    property bool replaceImportedTheme: false
    property bool copyImportedTheme: false
    property bool busy: false
    property bool applyScriptReview: false
    property string importState: "valid"
    property string validationMessage: ""
    property string importPath: ""
    property string pendingImportedThemeId: ""
    property string importDigest: ""
    property string sourceDigest: ""
    property int reviewedRevision: 0
    property string themeDigest: ""
    property string operation: ""
    property string output: ""
    readonly property var themeCards: windowOwner.libraryProvider.themes.map(entry => windowOwner.libraryProvider.cardFor(entry.id))
    readonly property string appliedThemeId: windowOwner.libraryProvider.appliedThemeId
    readonly property var targetDefaults: windowOwner.settingsController.settings ? Object.keys(windowOwner.settingsController.settings.targets) : []
    readonly property var targets: targetDefaults.map(key => ({key: key, label: windowOwner.themeEditorController ? windowOwner.themeEditorController.targetLabel(key) : key}))
    readonly property var exportTargetGroups: [
        {label: "Core", keys: ["quickshell", "widgets", "gtk", "cursor", "wallpaper", "hyprland"]},
        {label: "Applications", keys: targetDefaults.filter(key => ["quickshell", "widgets", "gtk", "cursor", "wallpaper", "hyprland", "helium", "chromium", "stylus"].indexOf(key) < 0)},
        {label: "Browsers", keys: ["helium", "chromium", "stylus"]}
    ]
    readonly property string saveFileUrl: "file://" + (Quickshell.env("HOME") || "/tmp") + "/Downloads/" + encodeURIComponent(bundleFileName)
    readonly property var exportComponentRows: [
        {id: "appearance", label: "Core appearance", detail: "Colours, fonts, window and cursor appearance"},
        {id: "wallpaper", label: "Wallpaper", detail: "Theme wallpaper"},
        {id: "bar", label: "Bar layout and contents", detail: "Bar position, style and items"},
        {id: "osd", label: "OSD", detail: "Volume, brightness and other indicators"},
        {id: "notifications", label: "Notifications", detail: "Position and appearance"},
        {id: "widgets", label: "Widgets", detail: "Widget profiles and layout"},
        {id: "targets", label: "Application targets", detail: "Saved target enablement and apply modes"},
        {id: "target-appearance", label: "Target appearance", detail: "Application-specific theme values"},
        {id: "binds", label: "Binds", detail: "Blox-owned Hyprland Lua settings"},
        {id: "autostart", label: "Autostart", detail: "Persistent autostart entries"},
        {id: "power", label: "Power policy", detail: "AC and battery policy"},
        {id: "monitors", label: "Monitors", detail: "Saved display layout"}
    ]

    function componentsFor(level) {
        const standard = ["appearance", "wallpaper", "bar", "osd", "notifications", "widgets", "targets", "target-appearance"];
        return level === "minimal" ? ["appearance", "wallpaper"] : level === "full" ? standard.concat(["binds", "autostart", "power", "monitors"]) : standard;
    }
    function same(left, right) { return JSON.stringify(left.slice().sort()) === JSON.stringify(right.slice().sort()); }
    function updateBundleLevel() {
        bundleLevel = ["minimal", "standard", "full"].find(level => same(selectedExportComponents, componentsFor(level)) && same(selectedExportTargets, level === "minimal" ? [] : targetDefaults)) || "custom";
    }
    function chooseBundle(level) { selectedExportComponents = componentsFor(level); selectedExportTargets = level === "minimal" ? [] : targetDefaults.slice(); bundleLevel = level; clearApprovals(); }
    function clearApprovals() { approvedSensitiveFiles = []; sensitiveImportFiles = []; themeDigest = ""; }
    function toggleExportComponent(id, checked) {
        // The backend requires core appearance in every bundle.
        if (id === "appearance" && !checked) return;
        selectedExportComponents = selectedExportComponents.filter(key => key !== id).concat(checked ? [id] : []);
        if (id === "targets") selectedExportTargets = checked ? targetDefaults.slice() : [];
        updateBundleLevel(); clearApprovals();
    }
    function toggleExportTarget(id, checked) {
        selectedExportTargets = selectedExportTargets.filter(key => key !== id).concat(checked ? [id] : []);
        updateBundleLevel(); clearApprovals();
    }
    function exportComponentSelected(id) { return selectedExportComponents.indexOf(id) >= 0; }
    function toggleImportSection(id, checked) { selectedImportSections = selectedImportSections.filter(key => key !== id).concat(checked ? [id] : []); approvedSensitiveFiles = []; }
    function approveSensitiveFile(id, checked) { approvedSensitiveFiles = approvedSensitiveFiles.filter(key => key !== id).concat(checked ? [id] : []); }
    function approvals() {
        const result = {};
        sensitiveImportFiles.filter(file => approvedSensitiveFiles.indexOf(file.id) >= 0).forEach(file => result[file.path] = file.sha256);
        return result;
    }
    function request(action, data) {
        if (busy || windowOwner.settingsMutationPending || SettingsApplyController.busy) return false;
        const response = JSON.parse(windowOwner.settingsController.begin("bundle-" + action, JSON.stringify(data)));
        if (response.code !== "pending") { windowOwner.settingsFeedback = response.message || "Settings is busy."; return false; }
        busy = true; operation = action; output = "";
        requestId = response.data.requestId;
        pollTimer.start();
        return true;
    }
    function baseRequest() { return {theme: exportThemeId || windowOwner.libraryProvider.selectedThemeId, components: selectedExportComponents.concat(["theme-metadata"]), targets: selectedExportTargets, preset: bundleLevel, approvals: approvals()}; }
    function importBundle() {
        if (busy || SettingsApplyController.busy) return;
        applyScriptReview = false; bundleFlowKind = "import"; bundleStep = "picker"; bundleOperationState = "";
        clearApprovals(); replaceImportedTheme = false; copyImportedTheme = false; dialogKind = "file-open";
    }
    function exportBundle(themeId) {
        if (busy || SettingsApplyController.busy) return;
        applyScriptReview = false; exportThemeId = themeId || windowOwner.libraryProvider.selectedThemeId;
        const card = windowOwner.libraryProvider.cardFor(exportThemeId);
        bundleFileName = card.name + ".blox-theme";
        bundleFlowKind = "export"; bundleStep = "contents"; bundleOperationState = "";
        chooseBundle("standard"); dialogKind = "export-review";
    }
    function showBundleFilePicker(kind) {
        if (kind === "file-open") { dialogKind = kind; return; }
        if (!themeDigest.length) request("review-export", baseRequest());
        else { bundleStep = "destination"; dialogKind = "file-save"; }
    }
    function inspectImport(path) {
        importPath = path; bundleFileName = path.split("/").pop(); bundleFlowKind = "import";
        bundleStep = "progress"; dialogKind = "import-review"; bundleOperationState = "progress";
        request("inspect", {path: path, theme: windowOwner.libraryProvider.selectedThemeId});
    }
    function importValidationState() { return importState; }
    function importCanContinue() { return !busy && importState !== "invalid" && selectedImportSections.length > 0 && (importState !== "conflict" || replaceImportedTheme || copyImportedTheme); }
    function continueImportSections() {
        if (!importCanContinue()) return;
        if (sensitiveImportFiles.length) bundleStep = "sensitive";
        else startBundleImport();
    }
    function startBundleImport() {
        if (applyScriptReview) { SettingsApplyController.approvals = approvals(); closeBundleDialog(); SettingsApplyController.applyReviewed(); return; }
        if (!importCanContinue()) return;
        const data = {theme: windowOwner.libraryProvider.selectedThemeId, path: importPath, components: selectedImportSections,
            approvals: approvals(), replace: replaceImportedTheme, copy: copyImportedTheme, sourceDigest: sourceDigest || null, digest: importDigest, revision: reviewedRevision};
        if (request("import", data)) { bundleStep = "progress"; bundleOperationState = "progress"; }
    }
    function saveExport(path) {
        const data = baseRequest(); data.path = path; data.revision = reviewedRevision; data.themeDigest = themeDigest;
        if (request("export", data)) { dialogKind = ""; bundleStep = ""; }
    }
    function closeBundleDialog() {
        if (busy) return;
        dialogKind = ""; bundleStep = ""; bundleOperationState = ""; applyScriptReview = false;
        windowOwner.restoreFocusAfterDialog();
    }
    function completeBundleImport() {
        pendingImportedThemeId = importedCard.id;
        closeBundleDialog();
        if (!openImportedThemeWhenReady() && windowOwner.libraryProvider.status !== "loading"
                && !windowOwner.libraryProvider.themes.some(entry => entry.id === pendingImportedThemeId))
            windowOwner.libraryProvider.refresh();
    }
    function openImportedThemeWhenReady() {
        if (windowOwner.windowOpen === false || !pendingImportedThemeId.length || windowOwner.libraryProvider.status === "loading") return false;
        if (!windowOwner.libraryProvider.themes.some(entry => entry.id === pendingImportedThemeId)) return false;
        const editor = windowOwner.themeEditorController;
        if (editor && editor.busy) return false;
        // Selection stays with the window owner, including its dirty-edit guard.
        if (windowOwner.selectTheme(pendingImportedThemeId, true) === false) return false;
        pendingImportedThemeId = "";
        windowOwner.navigateTo("theme", "landing", "");
        return true;
    }
    Connections {
        target: root.windowOwner
        function onDraftUserEditedChanged() { Qt.callLater(root.openImportedThemeWhenReady); }
        function onWindowOpenChanged() {
            if (!root.windowOwner.windowOpen) root.pendingImportedThemeId = "";
        }
    }
    Connections {
        target: root.windowOwner.libraryProvider
        function onThemesChanged() { Qt.callLater(root.openImportedThemeWhenReady); }
        function onStatusChanged() { Qt.callLater(root.openImportedThemeWhenReady); }
    }
    Connections {
        target: root.windowOwner.themeEditorController
        function onDirtyChanged() { Qt.callLater(root.openImportedThemeWhenReady); }
        function onBusyChanged() { Qt.callLater(root.openImportedThemeWhenReady); }
    }
    function reviewApplyScripts(records) {
        applyScriptReview = true; bundleFlowKind = "import"; bundleStep = "sensitive"; dialogKind = "import-review";
        importedCard = windowOwner.libraryProvider.cardFor(SettingsApplyController.selectedThemeId)
            || {id: SettingsApplyController.selectedThemeId || "", name: SettingsApplyController.selectedThemeName || SettingsApplyController.selectedThemeId || "Theme", palette: []};
        sensitiveImportFiles = records.map(file => Object.assign({}, file, {id: file.path, preview: file.contents, reason: file.path + " · " + file.size + " bytes · SHA-256 " + file.sha256, viewMode: file.contents.split("\n").length > 4 ? "expand" : "plain"}));
        selectedImportSections = ["appearance"]; approvedSensitiveFiles = []; importState = "valid";
    }
    function finish(response) {
        if (!response || response.version !== 1 || !response.ok) {
            validationMessage = response && response.message ? response.message : "Could not read the bundle result.";
            windowOwner.settingsFeedback = validationMessage;
            bundleOperationState = "failure";
            if (bundleFlowKind === "import") { importState = "invalid"; bundleStep = "result"; }
            else { bundleStep = "contents"; dialogKind = "export-review"; }
            return;
        }
        const data = response.data;
        if (operation === "inspect") {
            importedCard = data.card;
            importDigest = data.digest; reviewedRevision = data.settingsRevision; sourceDigest = data.sourceDigest || "";
            sensitiveImportFiles = data.scripts; importState = data.validation;
            validationMessage = importState === "conflict" ? "An editable " + data.name + " theme already exists. Choose whether to replace it." : "Manifest and files checked. Choose the sections to keep.";
            selectedImportSections = data.components.slice();
            importSectionRows = exportComponentRows.filter(row => data.components.indexOf(row.id) >= 0).map(row => Object.assign({}, row, {readOnly: false, included: false}));
            data.components.filter(key => key !== "theme-metadata" && !exportComponentRows.some(row => row.id === key)).forEach(key => importSectionRows.push({id: key, label: key, detail: "Preserved as dormant data"}));
            importSectionRows = importSectionRows.slice(); bundleOperationState = ""; bundleStep = "sections";
        } else if (operation === "review-export") {
            sensitiveImportFiles = data.scripts; reviewedRevision = data.settingsRevision; themeDigest = data.themeDigest;
            if (data.scripts.length) { bundleStep = "contents"; dialogKind = "export-review"; }
            else showBundleFilePicker("file-save");
        } else if (operation === "import") {
            importedCard = Object.assign({}, importedCard, {id: data.id, name: data.name || importedCard.name});
            bundleOperationState = "success"; bundleStep = "result"; windowOwner.refreshAfterApply(true);
        } else if (operation === "export") {
            windowOwner.settingsFeedback = "Bundle saved to " + data.path; closeBundleDialog();
        }
    }
    property string requestId: ""
    Timer {
        id: pollTimer
        interval: 80
        repeat: true
        onTriggered: {
            const response = JSON.parse(root.windowOwner.settingsController.poll(root.requestId));
            if (response.code === "pending") return;
            stop(); root.busy = false;
            root.finish({version: response.version, ok: response.ok, message: response.message,
                data: response.data ? response.data.bundle : null});
        }
    }
}
