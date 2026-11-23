import qs.shared
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "../shared/Shape.js" as Shape
import "SettingsThemeCandidateLogic.js" as CandidateLogic

Scope {
    id: root

    property var sourcePreparationCallback: null
    function prepareEditorSource(value, source) { return typeof sourcePreparationCallback === "function" ? sourcePreparationCallback(value, source) : value; }

    required property var host
    property Flickable editorScrollItem
    property Item pickerRootItem
    property Item barDragProxyItem
    property bool open: false
    property bool rendered: false
    property alias busy: apiController.busy
    property alias action: apiController.action
    property alias processOutput: apiController.processOutput
    property alias processError: apiController.processError
    property var themes: []
    property var candidate: null
    property int candidateRevision: 0
    property int sessionRevision: 0
    property alias requestSerial: apiController.requestSerial
    property alias activeRequest: apiController.activeRequest
    property bool validationPending: false
    property string baselineJson: ""
    property string sourceDigest: ""
    // Raw source for the selected theme. The candidate stays fully resolved
    // for the editor, while Save sends this sparse document back to themectl.
    property var sourceTheme: null
    property var touchedPaths: []
    property string selectedId: ""
    property var browserTargets: []
    property bool browserTargetsLoaded: false
    property string browserTargetOutput: ""
    property var wallpapers: []
    property bool wallpapersLoaded: false
    property string wallpaperOutput: ""
    property int wallpaperRevision: 0
    property string wallpaperFilter: "All"
    property string wallpaperRemovalId: ""
    property string wallpaperRemovalName: ""
    property string wallpaperRemovalReference: ""
    property var wallpaperRemovalUsers: []
    property string wallpaperRemovalError: ""
    property var iconThemes: []
    property bool iconThemesLoaded: false
    property string iconThemeOutput: ""
    property var previewData: ({
    })
    property var apiWarnings: []
    property var validationErrors: []
    property bool candidateValid: false
    property string statusMessage: ""
    property string errorMessage: ""
    property alias generatorBackend: generationController.backend
    property alias newVariant: generationController.newVariant
    property string pendingPreviewContinuation: ""
    property bool settingsApplyPreviewHeld: false
    property bool settingsApplyPreviewPending: false
    signal settingsApplyPreviewPrepared(bool successful, string message)

    // Drain the compositor preview before the durable Apply owner captures it.
    function prepareForSettingsApply() {
        if (settingsApplyPreviewPending) return false;
        if (settingsApplyPreviewHeld) return true;
        settingsApplyPreviewHeld = true;
        hyprlandPreview.suspended = true;
        settingsApplyPreviewPending = true;
        if (!hyprlandPreview.restoreFor("settings-apply")) {
            settingsApplyPreviewPending = false;
            return true;
        }
        return false;
    }

    function releaseSettingsApplyPreview() {
        settingsApplyPreviewHeld = false;
        hyprlandPreview.suspended = false;
    }

    property string pendingSelection: ""
    property string modalKind: ""
    property string pendingModalConfirmation: ""
    property string duplicateId: ""
    property string duplicateName: ""
    property string renameName: ""
    property string modalThemeId: ""
    property string modalThemeName: ""
    property alias newThemeName: generationController.newThemeName
    property alias newThemeId: generationController.newThemeId
    property alias newWallpaper: generationController.newWallpaper
    property alias newFlowPage: generationController.newFlowPage
    property alias paletteOptions: generationController.paletteOptions
    property alias paletteRequestSerial: generationController.paletteRequestSerial
    property alias paletteRequestPath: generationController.paletteRequestPath
    property alias paletteLoading: generationController.paletteLoading
    property alias creationBusy: generationController.creationBusy
    property alias creationRequest: generationController.creationRequest
    property string guideTarget: ""
    property string guideReturnModalKind: ""
    property var widgetProfileProvider: null
    property var widgetProfileWriter: null
    readonly property bool widgetControlsEnabled: !busy && !creationBusy && !(host && host.mutationProtected) && !(host && host.applyingSettingsDraft)
    property alias widgetDraft: widgetController.draft
    property alias widgetDraftError: widgetController.errorMessage
    readonly property var widgetCatalogue: host && host.widgetCatalogue ? host.widgetCatalogue : null
    readonly property var widgetSchema: host && host.widgetSchema ? host.widgetSchema : null
    readonly property var widgetRegistry: host && host.widgetRegistry ? host.widgetRegistry : ({})
    property alias widgetEditIndex: widgetController.editIndex
    property alias widgetEditModePending: widgetController.editModePending
    property string widgetReturnWorkspace: ""
    property alias generatedDownloadTarget: generationController.downloadTarget
    property alias generatedDownloadFile: generationController.downloadFile
    property alias generatedDownloadArchive: generationController.downloadArchive
    property string wallpaperDialogTarget: "overview"
    property var fontFamilies: []
    property string fontOutput: ""
    property alias colourPickerOpen: colourController.open
    property alias colourPickerKey: colourController.key
    property alias colourPickerTarget: colourController.target
    property var focusBeforeOverlay: null
    property var overlayFocusTarget: null
    property var colourPickerHost: null
    property var externalColourApply: null
    property var externalColourCommit: null
    property var externalColourClear: null
    property alias colourHue: colourController.hue
    property alias colourSaturation: colourController.saturation
    property alias colourValue: colourController.value
    property alias colourHex: colourController.hex
    property bool barDragActive: false
    property string barDragItemId: ""
    property string barDragLabel: ""
    property string barDropRegion: ""
    property int barDropIndex: -1
    property string barDropTarget: ""
    property real barDragOriginX: 0
    property real barDragOriginY: 0
    property var editorWheelOwner: null
    readonly property bool dirty: candidate !== null && (JSON.stringify(candidate) !== baselineJson || touchedPaths.length > 0)
    readonly property string apiPath: Quickshell.shellDir + "/scripts/theme/themectl.sh"
    readonly property string scriptRoot: Quickshell.shellDir + "/scripts"
    readonly property var semanticKeys: ["background", "surface", "surface_alt", "foreground", "muted", "accent", "danger", "success", "warning", "info", "mauve", "teal", "selection_background", "selection_foreground", "border"]
    readonly property var ansiKeys: ["color0", "color1", "color2", "color3", "color4", "color5", "color6", "color7", "color8", "color9", "color10", "color11", "color12", "color13", "color14", "color15"]
    readonly property var overrideKeys: ["background", "foreground", "accent", "border"]
    readonly property bool selectedThemeBuiltin: themes.some((entry) => {
        return entry && entry.id === selectedId && entry.builtin === true;
    })
    readonly property bool themeControlsEnabled: !selectedThemeBuiltin
    readonly property var targetKeys: ["quickshell", "widgets", "gtk", "helium", "chromium", "cursor", "wallpaper", "kitty", "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "t3code", "zed", "stylus", "obsidian", "powerlevel10k", "sddm", "grub"]
    readonly property var unavailableTargetKeys: ["sddm", "grub"]
    readonly property var coreTargetKeys: ["quickshell", "widgets", "wallpaper", "hyprland", "hyprlock", "cursor"]
    readonly property var applicationTargetKeys: ["kitty", "gtk", "btop", "micro", "glow", "code", "cursor_editor", "t3code", "zed", "stylus", "obsidian", "powerlevel10k"]
    readonly property var stylusStyleSetValues: ["recommended", "unmaintained", "all"]
    readonly property var stylusStyleSetNames: ["Recommended", "Include unmaintained", "All eligible"]
    readonly property var browserTargetKeys: browserTargets.filter((entry) => {
        return entry.supported && entry.installed && entry.available;
    }).map((entry) => {
        return entry.target;
    })
    readonly property var iconSampleKeys: ["file", "app-window", "gear-six", "palette", "terminal-window", "file"]
    readonly property var iconThemeOptions: {
        const entries = iconThemes.slice();
        const known = entries.map((entry) => entry.id);
        const values = [Theme.activeIconTheme || "Adwaita", candidate && candidate.icons ? candidate.icons.theme : ""];
        values.forEach((value) => {
            if (value && known.indexOf(value) < 0) {
                entries.push({"id": value, "name": value, "samples": {}});
                known.push(value);
            }
        });
        return entries;
    }
    readonly property var iconThemeNames: iconThemeOptions.map((entry) => {
        const active = Theme.activeIconTheme || "Adwaita";
        return entry.name + (entry.id === active ? " • active" : "");
    })
    readonly property var barRegions: ["start", "centre", "end", "tray"]

    function beginBarDrag(row, itemId) {
        const point = row.mapToItem(pickerRootItem, 0, 0);
        barDragItemId = itemId;
        barDragLabel = barItemLabel(itemId);
        barDragProxyItem.width = row.width;
        barDragProxyItem.height = row.height;
        barDragProxyItem.x = point.x;
        barDragProxyItem.y = point.y;
        barDragOriginX = point.x;
        barDragOriginY = point.y;
        barDropRegion = "";
        barDropIndex = -1;
        barDropTarget = "";
        barDragActive = true;
    }

    function moveBarDragProxy(deltaX, deltaY) {
        if (!barDragActive)
            return ;

        barDragProxyItem.x = barDragOriginX + deltaX;
        barDragProxyItem.y = barDragOriginY + deltaY;
    }

    function scrollBarDrag() {
        if (!barDragActive)
            return ;

        const viewport = editorScrollItem.mapToItem(pickerRootItem, 0, 0);
        const pointerY = barDragProxyItem.y + barDragProxyItem.height / 2;
        const edge = 54;
        const maximum = Math.max(editorScrollItem.originY, editorScrollItem.originY + editorScrollItem.contentHeight - editorScrollItem.height);
        if (pointerY > viewport.y + editorScrollItem.height - edge)
            editorScrollItem.contentY = Math.min(maximum, editorScrollItem.contentY + 14);
        else if (pointerY < viewport.y + edge)
            editorScrollItem.contentY = Math.max(editorScrollItem.originY, editorScrollItem.contentY - 14);
    }

    function claimEditorWheel(owner) {
        if (!owner)
            return false;

        if (editorWheelOwner === null)
            editorWheelOwner = owner;
        editorWheelSessionTimer.restart();
        return editorWheelOwner === owner;
    }

    function setBarDropTarget(region, index, target) {
        if (!barDragActive)
            return ;

        if (!barDropAllowed(barDragItemId, region, index)) {
            barDropRegion = "";
            barDropIndex = -1;
            barDropTarget = "";
            return ;
        }
        barDropRegion = region;
        barDropIndex = index;
        barDropTarget = target;
    }

    function barDropAllowed(id, region, index) {
        if (id === "application-tray") {
            if (region !== "hidden")
                return false;

            const count = barItems().filter((item) => {
                return item.region === "hidden";
            }).length;
            return applicationTrayAtStart() ? index === 0 : index === count;
        }
        if (id !== "tray")
            return true;

        if (region === "hidden")
            return false;

        const count = barItems().filter((item) => {
            return item.region === region;
        }).length;
        if (region === "start")
            return index === count;

        if (region === "end")
            return index === 0;

        return region === "centre" && (index === 0 || index === count);
    }

    function commitBarDrop() {
        if (barDragItemId.length > 0 && barDropRegion.length > 0 && barDropIndex >= 0)
            moveBarItemTo(barDragItemId, barDropRegion, barDropIndex);

    }

    function endBarDrag() {
        barDragActive = false;
        barDragItemId = "";
        barDragLabel = "";
        barDropRegion = "";
        barDropIndex = -1;
        barDropTarget = "";
    }

    function finishBarDrag() {
        commitBarDrop();
        endBarDrag();
    }

    function targetAvailable(key) {
        if (unavailableTargetKeys.indexOf(key) >= 0)
            return false;

        if (["helium", "chromium"].indexOf(key) >= 0) {
            if (!browserTargetsLoaded)
                return false;

            const browser = browserTargetInfo(key);
            return browser !== null && browser.available === true;
        }
        return true;
    }

    function targetLabel(key) {
        if (key === "sddm" || key === "grub")
            return key + " · unavailable";

        if (key === "t3code")
            return "T3Code";
        if (key === "zed")
            return "Zed";

        const browser = browserTargetInfo(key);
        if (browser !== null && browser.label)
            return browser.label;

        return key;
    }

    function targetApplyMode(key) {
        if (key === "stylus")
            return "manual";

        if (["gtk", "helium", "chromium", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "powerlevel10k"].indexOf(key) >= 0)
            return "restart";

        return "automatic";
    }

    function targetModeLabel(key) {
        const mode = targetApplyMode(key);
        return mode === "manual" ? "Apply Manually" : mode === "restart" ? (key === "code" || key === "cursor_editor" ? "Reload Window" : "Restart Needed") : "Automatic";
    }

    function cloneCandidate() {
        return candidate === null ? null : JSON.parse(JSON.stringify(candidate));
    }

    function swatchText(colour) {
        const value = String(colour || "#000000").replace("#", "");
        if (value.length !== 6)
            return Theme.foreground;

        const red = parseInt(value.slice(0, 2), 16);
        const green = parseInt(value.slice(2, 4), 16);
        const blue = parseInt(value.slice(4, 6), 16);
        return (red * 299 + green * 587 + blue * 114) / 1000 > 145 ? "#111111" : "#f5f5f5";
    }

    function validColour(value, fallback) {
        return /^#[0-9a-fA-F]{6}$/.test(String(value || "")) ? value : (fallback || "transparent");
    }





    function themeDigest(id) {
        for (let index = 0; index < themes.length; ++index) {
            if (themes[index].id === id)
                return themes[index].source_sha256 || "";

        }
        return "";
    }

    function duplicateIdForName(name) {
        let stem = String(name || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
        if (!stem)
            stem = "theme";

        stem = stem.slice(0, 64).replace(/-+$/g, "");
        let id = stem;
        let suffix = 2;
        const exists = (value) => {
            return themes.some((entry) => {
                return entry.id === value;
            });
        };
        while (exists(id)) {
            const ending = "-" + suffix;
            id = stem.slice(0, 64 - ending.length).replace(/-+$/g, "") + ending;
            suffix += 1;
        }
        return id;
    }


    function componentHex(value) {
        return colourController.componentHex(value);
    }

    function hsvHex(hue, saturation, value) {
        return colourController.hsvHex(hue, saturation, value);
    }

    function loadPickerColour(value) {
        colourController.load(value);
    }

    function openColourPicker(key, target) {
        colourController.show(key, target);
    }

    function rememberOverlayFocus() {
        if (overlayFocusTarget) {
            focusBeforeOverlay = overlayFocusTarget;
            overlayFocusTarget = null;
            return;
        }
        try {
            const contentItem = host && host.contentItem;
            const nativeWindow = contentItem ? contentItem.Window.window : null;
            focusBeforeOverlay = nativeWindow ? nativeWindow.activeFocusItem : null;
        } catch (error) {
            focusBeforeOverlay = null;
        }
    }

    function restoreOverlayFocus() {
        try {
            if (focusBeforeOverlay && focusBeforeOverlay.visible && focusBeforeOverlay.enabled)
                focusBeforeOverlay.forceActiveFocus();

        } catch (error) {
        }
        focusBeforeOverlay = null;
    }

    function focusModal() {
        host.focusModal();
    }

    function schedulePaletteRequest() {
        paletteDelay.restart();
    }

    function scheduleValidation() {
        validationDelay.restart();
    }

    function openWidgetImportDialog() {
        host.dialogs.openWidgetImport();
    }

    function openWidgetExportDialog() {
        host.dialogs.openWidgetExport();
    }

    function showModal(kind) {
        rememberOverlayFocus();
        modalKind = kind;
        Qt.callLater(focusModal);
    }

    function openGuide(target, returnModalKind) {
        guideTarget = target;
        guideReturnModalKind = returnModalKind || "";
        showModal("guide");
    }

    function closeGuide() {
        const returnModalKind = guideReturnModalKind;
        guideTarget = "";
        guideReturnModalKind = "";
        if (returnModalKind.length > 0) {
            modalKind = returnModalKind;
            Qt.callLater(focusModal);
        } else {
            modalKind = "";
            Qt.callLater(restoreOverlayFocus);
        }
    }

    function modalConfirmationEnabled() {
        if (modalKind === "duplicate")
            return duplicateId.trim().length > 0 && duplicateName.trim().length > 0;

        if (modalKind === "rename")
            return renameName.trim().length > 0;

        if (modalKind === "wallpaper-remove")
            return wallpaperRemovalId.length === 64 && wallpaperRemovalUsers.length === 0 && wallpaperRemovalError.length === 0;

        return true;
    }

    function applyPickerColour(value) {
        colourController.apply(value);
    }

    function updatePickerColour() {
        colourController.update();
    }

    function runApi(nextAction, args) {
        return apiController.run(nextAction, args);
    }

    function browserTargetInfo(key) {
        for (const entry of browserTargets) {
            if (entry.target === key)
                return entry;
        }
        return null;
    }

    function iconThemeInfo(id) {
        for (const entry of iconThemeOptions) {
            if (entry.id === id)
                return entry;
        }
        return null;
    }

    function iconThemeValue() {
        return candidate && candidate.icons && candidate.icons.theme ? candidate.icons.theme : (Theme.activeIconTheme || "Adwaita");
    }

    function iconThemeIndex() {
        return iconThemeOptions.findIndex((entry) => entry.id === iconThemeValue());
    }

    function iconThemeIdAt(index) {
        return index >= 0 && index < iconThemeOptions.length ? iconThemeOptions[index].id : "";
    }

    function iconThemeSampleSource(id, sample) {
        const entry = iconThemeInfo(id);
        return entry && entry.samples ? entry.samples[sample] || "" : "";
    }

    function setIconTheme(value) {
        if (!candidate || !value || !iconThemeInfo(value) || iconThemeValue() === value)
            return ;

        const next = cloneCandidate();
        next.icons = next.icons || {};
        next.icons.theme = value;
        markCandidate(next, "icons.theme");
    }

    function refreshIconThemes() {
        if (iconThemesProcess.running)
            return ;

        iconThemesLoaded = false;
        iconThemeOutput = "";
        iconThemesProcess.running = true;
    }

    function loadIconThemes() {
        let response = null;
        try {
            response = JSON.parse(iconThemeOutput.trim());
        } catch (error) {
        }
        const entries = response && Array.isArray(response.themes) ? response.themes.filter((entry) => {
            return entry && entry.id && entry.name && entry.samples;
        }) : [];
        const active = Theme.activeIconTheme || "Adwaita";
        if (!entries.some((entry) => entry.id === active))
            entries.unshift({"id": active, "name": active, "samples": {}});
        iconThemes = entries;
        iconThemesLoaded = true;
    }

    function refreshBrowserTargets() {
        if (browserTargetsProcess.running)
            return ;

        browserTargetsLoaded = false;
        browserTargets = [];
        browserTargetOutput = "";
        browserTargetsProcess.running = true;
    }

    function loadBrowserTargets() {
        let response = null;
        try {
            response = JSON.parse(browserTargetOutput.trim());
        } catch (error) {
        }
        browserTargets = response && response.ok === true && Array.isArray(response.data) ? response.data : [];
        browserTargetsLoaded = true;
    }

    function refreshWallpapers() {
        if (wallpapersProcess.running)
            return ;

        wallpapersLoaded = false;
        wallpaperOutput = "";
        wallpapersProcess.running = true;
    }

    function loadWallpapers() {
        let response = null;
        try {
            response = JSON.parse(wallpaperOutput.trim());
        } catch (error) {
        }
        wallpapers = response && response.ok === true && Array.isArray(response.data) ? response.data : [];
        wallpapersLoaded = true;
        wallpaperRevision += 1;
    }

    function wallpaperPathsEqual(left, right) {
        const leftPath = wallpaperDisplayPath(left);
        const rightPath = wallpaperDisplayPath(right);
        return leftPath.length > 0 && leftPath === rightPath;
    }

    function wallpaperItems() {
        wallpaperRevision;
        const entries = Array.isArray(wallpapers) ? wallpapers.slice() : [];
        const raw = candidate && candidate.wallpaper ? String(candidate.wallpaper.path || "").trim() : "";
        if (!raw)
            return entries;

        const present = entries.some((entry) => {
            return wallpaperPathsEqual(raw, entry.reference || "") || wallpaperPathsEqual(raw, entry.path || "");
        });
        if (!present && wallpapersLoaded) {
            const displayPath = wallpaperDisplayPath(raw);
            const pieces = raw.split(/[\\/]/);
            const filename = pieces.length > 0 ? pieces[pieces.length - 1] : raw;
            const packageWallpaper = raw.startsWith("wallpapers/showcase/") || raw.startsWith("wallpapers/builtin/");
            entries.push({
                "id": "current:" + raw,
                "name": filename.replace(/\.[^.]+$/, "") || "Current wallpaper",
                "kind": packageWallpaper ? "Built in" : "Imported",
                "path": displayPath,
                "reference": raw,
                "removable": false,
                "missing": true
            });
        }
        return entries;
    }

    function filteredWallpapers() {
        wallpaperRevision;
        const entries = wallpaperItems();
        if (wallpaperFilter === "All")
            return entries;
        return entries.filter((entry) => entry.kind === wallpaperFilter);
    }

    function wallpaperItemSelected(entry) {
        if (!entry || !candidate || !candidate.wallpaper)
            return false;
        const raw = String(candidate.wallpaper.path || "");
        return wallpaperPathsEqual(raw, entry.reference || "") || wallpaperPathsEqual(raw, entry.path || "");
    }

    function chooseWallpaper(entry) {
        if (!entry || entry.missing || !themeControlsEnabled || busy)
            return ;
        setWallpaperPath(entry.reference || entry.path || "");
        statusMessage = "Previewing " + entry.name + ".";
    }

    function importWallpaper(path) {
        if (!candidate || !themeControlsEnabled || busy || !path)
            return ;
        runApi("wallpapers-import", ["wallpapers", "import", path, "--theme-id", candidate.id]);
    }

    function requestWallpaperRemoval(entry) {
        if (!entry || !entry.removable || !themeControlsEnabled || busy)
            return ;
        wallpaperRemovalId = entry.id || "";
        wallpaperRemovalName = entry.name || "wallpaper";
        wallpaperRemovalReference = entry.reference || entry.path || "";
        wallpaperRemovalUsers = themes.filter((theme) => {
            const preview = theme && theme.preview ? theme.preview.wallpaper : "";
            return preview && (wallpaperPathsEqual(preview, entry.reference || "") || wallpaperPathsEqual(preview, entry.path || ""));
        }).map((theme) => theme.name || theme.id).filter((name, index, values) => name && values.indexOf(name) === index);
        wallpaperRemovalError = "";
        showModal("wallpaper-remove");
    }

    function wallpaperRemovalMessage() {
        if (wallpaperRemovalUsers.length > 0)
            return "Cannot remove this wallpaper. It is used by: " + wallpaperRemovalUsers.join(", ") + ". Choose another wallpaper in those themes first.";
        if (wallpaperRemovalError.length > 0)
            return wallpaperRemovalError;
        return "Blox removes its copy and leaves the original file where you imported it from.";
    }

    function restoreWallpaperForRemoval() {
        if (!wallpaperRemovalReference || !candidate || !candidate.wallpaper)
            return ;
        if (!wallpaperPathsEqual(candidate.wallpaper.path, wallpaperRemovalReference))
            return ;
        const activePath = wallpaperDisplayPath(Theme.activeWallpaperSource);
        if (activePath)
            setWallpaperPath(activePath);
    }

    function refreshThemes(refreshOnly) {
        runApi(refreshOnly ? "list-refresh" : "list", ["list"]);
    }


    function recoverPickerWorkspace(returnWorkspace, focusWorkspace) {
        // Remap the Settings window to its original workspace after desktop editing.
        // The second pass only moves the surface and cannot switch workspaces again.
        Quickshell.execDetached(["sh", "-c", "requested=$1; refocus=$2; if [ -n \"$requested\" ]; then workspace=$requested; if [ \"$refocus\" != false ]; then hyprctl dispatch \"hl.dsp.focus({ workspace = \\\"$workspace\\\" })\" >/dev/null; sleep 0.15; fi; else active=$(hyprctl activeworkspace -j); if [ \"$(printf %s \"$active\" | jq -r .name)\" = blox-widget-edit ] && [ \"$refocus\" != false ]; then hyprctl dispatch 'hl.dsp.focus({ workspace = \"previous\" })' >/dev/null; sleep 0.15; active=$(hyprctl activeworkspace -j); fi; workspace=$(printf %s \"$active\" | jq -r 'if .id > 0 then .id | tostring else \"name:\" + .name end'); fi; [ -n \"$workspace\" ] || exit 0; hyprctl dispatch \"hl.dsp.window.move({ workspace = \\\"$workspace\\\", follow = false, window = \\\"title:^Blox settings$\\\" })\" >/dev/null", "blox-settings-recover", String(returnWorkspace || ""), focusWorkspace === false ? "false" : "true"]);
    }


    // Load the Settings theme draft through the shared source owner.
    function loadForSettings() {
        hyprlandPreview.recover();
        if (candidate !== null || busy)
            return false;
        return runApi("list", ["list"]);
    }


    function closePicker() {
        sessionRevision += 1;
        hyprlandPreview.restoreFor("close");
        editorWheelOwner = null;
        editorWheelSessionTimer.stop();
        validationPending = false;
        validationDelay.stop();
        Theme.cancelPreview();
        open = false;
        modalKind = "";
        candidate = null;
        candidateRevision += 1;
        selectedId = "";
        sourceDigest = "";
        sourceTheme = null;
        touchedPaths = [];
        baselineJson = "";
        candidateValid = false;
        validationErrors = [];
        guideTarget = "";
        guideReturnModalKind = "";
        pendingPreviewContinuation = "";
        pendingSelection = "";
        pendingModalConfirmation = "";
        wallpaperRemovalId = "";
        wallpaperRemovalName = "";
        wallpaperRemovalReference = "";
        wallpaperRemovalUsers = [];
        wallpaperRemovalError = "";
        focusBeforeOverlay = null;
        hideTimer.restart();
    }

    function requestSelection(id, confirmDirty, forceReload) {
        if (!id || (id === selectedId && candidate !== null && forceReload !== true))
            return ;

        if (confirmDirty && dirty) {
            pendingSelection = id;
            showModal("navigate");
            return ;
        }
        runApi("show", ["show", id]);
    }

    function validatePreview() {
        if (candidate === null)
            return ;

        if (busy) {
            validationPending = true;
            candidateValid = false;
            return ;
        }
        validationPending = false;
        runApi("preview-edit", ["preview", JSON.stringify(candidate)]);
    }

    function applyValidatedPreview(source) {
        if (!dirty && selectedId === Theme.activeThemeId) {
            hyprlandPreview.restoreFor("active");
            Theme.cancelPreview();
            statusMessage = "Active theme";
            return ;
        }
        Theme.previewSource(source);
        hyprlandPreview.preview(source);
        statusMessage = dirty ? "Temporary Quickshell preview — unsaved" : "Temporary Quickshell preview";
    }

    function hyprlandValue(key, fallback) { return CandidateLogic.hyprlandValue(candidate, key, fallback); }

    function setHyprlandValue(key, value) {
        if (!candidate) return;
        const next = cloneCandidate();
        next.hyprland = next.hyprland || {};
        if (value === null || value === undefined) delete next.hyprland[key];
        else next.hyprland[key] = value;
        markCandidate(next, "hyprland." + key);
    }

    function setHyprlandInactiveOpacity(value) {
        if (Number.isFinite(value))
            setHyprlandValue("inactive_opacity", Math.max(0.1, Math.min(1.0, Math.round(value * 100) / 100)));
    }

    function setHyprlandBorderSize(value) {
        if (Number.isFinite(value))
            setHyprlandValue("border_size", Math.max(0, Math.min(8, Math.round(value))));
    }

    function markCandidatePaths(value, paths, allowBuiltinChange) {
        if (selectedThemeBuiltin && !allowBuiltinChange) return false;
        candidate = value;
        const nextTouchedPaths = touchedPaths.slice();
        for (const path of paths || []) {
            if (path && path.length > 0 && nextTouchedPaths.indexOf(path) < 0)
                nextTouchedPaths.push(path);
        }
        touchedPaths = nextTouchedPaths;
        candidateRevision += 1;
        candidateValid = false;
        validationPending = true;
        validationDelay.restart();
        return true;
    }

    function markCandidate(value, touchedPath, allowBuiltinChange) {
        return markCandidatePaths(value, touchedPath ? [touchedPath] : [], allowBuiltinChange);
    }

    function setTopLevel(key, value) {
        const next = cloneCandidate();
        next[key] = value;
        markCandidate(next, key);
    }

    function stylusStyleSetIndex() {
        const value = candidate && candidate.stylus ? candidate.stylus.style_set : "recommended";
        const index = stylusStyleSetValues.indexOf(value);
        return index >= 0 ? index : 0;
    }

    function setStylusStyleSet(index) {
        if (!candidate || index < 0 || index >= stylusStyleSetValues.length) return;
        const next = cloneCandidate();
        next.stylus = next.stylus || {};
        next.stylus.style_set = stylusStyleSetValues[index];
        markCandidate(next, "stylus.style_set");
    }

    function setColour(key, value) {
        const next = cloneCandidate();
        next.colours[key] = value;
        markCandidate(next, "colours." + key);
    }

    function setFont(key, value) {
        const next = cloneCandidate();
        next.fonts[key] = value;
        markCandidate(next, "fonts." + key);
    }

    function shapeValue(key, fallback) { return CandidateLogic.shapeValue(candidate, key, fallback); }
    function effectiveWindowGap() { return candidate && candidate.shape ? Shape.effectiveWindowGap(candidate.shape) : 5; }
    function cursorValue(key, fallback) { return CandidateLogic.cursorValue(candidate, key, fallback); }
    function cursorGenerated() { return CandidateLogic.cursorGenerated(candidate); }
    function cursorFollowsThemeRoundness() { return CandidateLogic.cursorFollowsThemeRoundness(candidate); }
    function cursorEffectiveBase() { return CandidateLogic.cursorEffectiveBase(candidate); }
    function cursorShapeIndex() { return CandidateLogic.cursorShapeIndex(candidate); }
    function cursorDirectionIndex() { return CandidateLogic.cursorDirectionIndex(candidate); }
    function cursorSize() { return CandidateLogic.cursorSize(candidate); }

    function setCursorFollowsThemeRoundness(follows) {
        if (!candidate || !cursorGenerated() || cursorFollowsThemeRoundness() === !!follows) return;
        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        const paths = ["cursor.shape_source"];
        if (follows) {
            next.cursor.shape_source = "theme";
        } else {
            next.cursor.shape_source = "override";
            next.cursor.base = cursorEffectiveBase();
            paths.push("cursor.base");
        }
        markCandidatePaths(next, paths);
    }

    function setCursorShape(index) {
        if (!candidate || !cursorGenerated() || index < 0 || index > 1) return;
        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        next.cursor.base = index === 0 ? "Bibata-Original-Classic" : "Bibata-Modern-Classic";
        next.cursor.shape_source = "override";
        markCandidatePaths(next, ["cursor.base", "cursor.shape_source"]);
    }

    function setCursorDirection(index) {
        if (!candidate || !cursorGenerated() || index < 0 || index > 1) return;
        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        next.cursor.handedness = index === 0 ? "right" : "left";
        markCandidate(next, "cursor.handedness");
    }

    function setCursorSize(value) {
        if (!candidate || !candidate.cursor || !Number.isFinite(value)) return;
        const size = Math.max(16, Math.min(96, Math.round(value)));
        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        const existing = Array.isArray(next.cursor.sizes) ? next.cursor.sizes : [];
        next.cursor.sizes = [size].concat(existing.slice(1).filter(entry => entry !== size));
        markCandidate(next, "cursor.sizes");
    }

    function setShapeValue(key, value) {
        if (!candidate) return;
        const next = cloneCandidate();
        next.shape = next.shape || {radius_scale: 1.25, density_scale: 1.0};
        if (value === null || value === undefined) delete next.shape[key];
        else next.shape[key] = value;
        markCandidate(next, "shape." + key);
    }

    function setAutomaticWindowGap(automatic) {
        if (candidate) setShapeValue("window_gap", automatic ? null : effectiveWindowGap());
    }

    function barOverrideSpec(axis) { return CandidateLogic.barOverrideSpec(axis); }
    function barOverrideAutomatic(axis) { return CandidateLogic.barOverrideAutomatic(candidate, axis); }
    function barOverrideValue(axis) { return CandidateLogic.barOverrideValue(candidate, axis); }

    function setBarOverrideAutomatic(axis, automatic) {
        if (!candidate) return;
        const spec = barOverrideSpec(axis);
        const next = cloneCandidate();
        next.shell = next.shell || shellDefaults();
        next.shell.bar = next.shell.bar || {};
        next.shell.bar[spec.automatic] = !!automatic;
        const paths = ["shell.bar." + spec.automatic];
        if (!automatic && next.shell.bar[spec.value] === undefined) {
            next.shell.bar[spec.value] = shapeValue(spec.shape, spec.fallback);
            paths.push("shell.bar." + spec.value);
        }
        markCandidatePaths(next, paths);
        Theme.loadShell(next.shell);
    }

    function setBarOverrideValue(axis, value) {
        if (!candidate) return;
        const spec = barOverrideSpec(axis);
        const next = cloneCandidate();
        next.shell = next.shell || shellDefaults();
        next.shell.bar = next.shell.bar || {};
        next.shell.bar[spec.value] = value;
        next.shell.bar[spec.automatic] = false;
        markCandidatePaths(next, ["shell.bar." + spec.value, "shell.bar." + spec.automatic]);
        Theme.loadShell(next.shell);
    }

    function setTarget(key, value) {
        if (!candidate || !targetAvailable(key)) return;
        const next = cloneCandidate();
        next.targets[key] = value;
        markCandidate(next, "targets." + key, true);
    }

    function setOverride(target, key, value) {
        const next = CandidateLogic.applyOverride(cloneCandidate(), target, key, value);
        markCandidate(next, "overrides." + target + "." + key);
    }

    function setWallpaperPath(path) {
        if (!candidate) return;
        const next = cloneCandidate();
        next.wallpaper.path = String(path || "").trim();
        markCandidate(next, "wallpaper.path");
    }

    function setWallpaperDisplayPath(path) {
        const value = String(path || "").trim();
        if (candidate && value !== wallpaperDisplayPath(candidate.wallpaper.path))
            setWallpaperPath(value);
    }

    function shellDefaults() { return CandidateLogic.shellDefaults(); }
    function shellValue(section, key) { return CandidateLogic.shellValue(candidate, section, key); }

    function setShellValue(section, key, value) {
        if (!candidate)
            return ;

        const next = cloneCandidate();
        if (!next.shell)
            next.shell = shellDefaults();

        next.shell[section][key] = value;
        if (section === "bar" && key === "position") {
            const overrides = next.shell.bar.items || [];
            next.shell.bar.items = normaliseBarItemOrders(Theme.resolvedBarItems(overrides, value), value);
        }
        const touchedPath = section === "bar" && key === "position" ? "shell.bar" : "shell." + section + "." + key;
        markCandidate(next, touchedPath);
        Theme.loadShell(next.shell);
        if (section === "osd")
            Theme.osdPositionPreviewRequested();
        else if (section === "notifications")
            Theme.notificationPositionPreviewRequested();
    }

    function barItems() {
        return barModel.items();
    }

    function trayOpensForward(items) {
        return barModel.trayOpensForward(items || barItems());
    }

    function applicationTrayAtStart(items) {
        return barModel.applicationTrayAtStart(items || barItems());
    }

    function normaliseBarItemOrders(items, position) {
        return barModel.normaliseOrders(items);
    }

    function setBarItemEnabled(id, enabled) {
        barModel.setEnabled(id, enabled);
    }

    function setBarItemDisplay(id, display) {
        barModel.setDisplay(id, display);
    }

    function setBarItemVisibility(id, visibility) {
        barModel.setVisibility(id, visibility);
    }

    function setBarItemOrientation(id, orientation) {
        barModel.setOrientation(id, orientation);
    }

    function setBarItemTitleLength(id, titleLength) {
        barModel.setTitleLength(id, titleLength);
    }

    function setBarItemRegion(id, region) {
        barModel.setRegion(id, region);
    }

    function moveBarItem(id, direction) {
        barModel.move(id, direction);
    }

    function moveBarItemTo(id, region, destinationIndex) {
        barModel.moveTo(id, region, destinationIndex);
    }

    function barItemLabel(id) {
        return barModel.label(id);
    }

    function barPreviewItems(region) {
        return barModel.previewItems(region);
    }

    function barPreviewIcon(id) {
        return barModel.previewIcon(id);
    }

    function widgetProfileDocument() {
        return widgetController.profile();
    }

    function widgetItems() {
        return widgetController.items();
    }

    function localFileUrl(path) {
        const value = String(path || "");
        if (value.startsWith("file:")) return value;
        if (value.startsWith("~/")) return "file://" + Quickshell.env("HOME") + value.slice(1);
        if (value.startsWith("/")) return "file://" + value;
        if (root.baselineJson) {
            try {
                const source = JSON.parse(root.baselineJson);
                if (source.wallpaper && source.wallpaper.path === value) {
                    for (const theme of root.themes) {
                        if (theme.id === root.selectedId && theme.preview && theme.preview.wallpaper)
                            return localFileUrl(theme.preview.wallpaper);
                    }
                }
            } catch (error) {
                console.warn("[blox.settings] rejected source theme baseline: " + error);
            }
        }
        return Theme.wallpaperUrl(value);
    }

    function wallpaperDisplayPath(path) {
        const url = String(localFileUrl(path));
        return url.startsWith("file://") ? url.slice(7) : url;
    }

    function setWidgetItems(items) {
        return widgetController.setItems(items);
    }

    function widgetItemsChangeAllowed(nextItems) {
        return widgetControlsEnabled && Array.isArray(nextItems);
    }

    function newWidgetDraft(type) {
        return widgetController.newDraft(type);
    }

    function updateWidgetDraft(values) {
        widgetController.updateDraft(values);
    }

    function updateWidgetOption(key, value) {
        widgetController.updateOption(key, value);
    }

    function openWidgetEditor(index) {
        widgetController.openEditor(index);
    }

    function openWidgetEditMode() {
        return widgetController.openEditMode();
    }

    function saveWidgetDraft() {
        return widgetController.saveDraft();
    }

    function openWallpaperDialog(target) {
        wallpaperDialogTarget = target || "overview";
        host.dialogs.openWallpaper();
    }





    function downloadGeneratedFile(target, file) {
        generationController.downloadFileTo(target, file);
    }

    function downloadGeneratedArchive(target) {
        generationController.downloadTargetArchive(target);
    }

    function generateTheme(wallpaper, displayName, themeId, backend) {
        generationController.generate(wallpaper, displayName, themeId, backend);
    }

    function requestPalettes() {
        generationController.requestPalettes();
    }




    function saveCandidate() {
        if (candidate === null || !candidateValid || busy)
            return ;

        const args = ["save", JSON.stringify(candidate)];
        if (sourceTheme !== null)
            args.push("--source", JSON.stringify(sourceTheme));
        if (touchedPaths.length > 0)
            args.push("--touched", JSON.stringify(touchedPaths));
        if (sourceDigest)
            args.push("--replace", "--expect-sha256", sourceDigest);

        runApi("save", args);
    }






    function revertCandidate() {
        if (!baselineJson)
            return ;

        candidate = JSON.parse(baselineJson);
        touchedPaths = [];
        candidateRevision += 1;
        candidateValid = true;
        validationErrors = [];
        applyValidatedPreview(candidate);
        if (selectedId !== Theme.activeThemeId)
            statusMessage = "Unsaved changes reverted.";

    }

    function openNewTheme(wallpaperPage) {
        generationController.openNew(wallpaperPage);
    }

    function blankTheme(template, inputs) {
        return generationController.blankTheme(template, inputs);
    }

    function startNewTheme(fromWallpaper) {
        generationController.startNew(fromWallpaper);
    }

    function openDuplicate(themeId, themeName) {
        const sourceId = themeId || (candidate ? candidate.id : "");
        if (!sourceId || sourceId === selectedId && dirty)
            return ;

        modalThemeId = sourceId;
        modalThemeName = themeName || (candidate ? candidate.name : sourceId);
        duplicateName = modalThemeName + " - Copy";
        duplicateId = duplicateIdForName(duplicateName);
        showModal("duplicate");
    }

    function openRename(themeId, themeName) {
        const sourceId = themeId || (candidate ? candidate.id : "");
        if (!sourceId || sourceId === selectedId && dirty)
            return ;

        modalThemeId = sourceId;
        modalThemeName = themeName || (candidate ? candidate.name : sourceId);
        renameName = modalThemeName;
        showModal("rename");
    }

    function requestDelete(themeId, themeName, builtin) {
        const sourceId = themeId || (candidate ? candidate.id : "");
        if (!sourceId || builtin || sourceId === selectedId && dirty)
            return ;

        modalThemeId = sourceId;
        modalThemeName = themeName || (candidate ? candidate.name : sourceId);
        showModal("delete");
    }

    function dismissModal() {
        if (modalKind === "guide") {
            closeGuide();
            return ;
        }
        pendingModalConfirmation = "";
        modalDismissTimer.restart();
    }

    function confirmModal() {
        pendingModalConfirmation = modalKind;
        modalDismissTimer.restart();
    }

    function completeModalDismissal() {
        const kind = pendingModalConfirmation;
        pendingModalConfirmation = "";
        modalKind = "";
        Qt.callLater(restoreOverlayFocus);
        if (!kind)
            return ;

        if (kind === "navigate") {
            pendingPreviewContinuation = "navigate";
            if (!hyprlandPreview.restoreFor("navigate"))
                completePendingNavigation();
        } else if (kind === "close")
            closePicker();
        else if (kind === "delete")
            runApi("delete", ["delete", modalThemeId, "--yes"]);
        else if (kind === "duplicate")
            runApi("duplicate", ["duplicate", modalThemeId, duplicateId.trim(), "--name", duplicateName.trim()]);
        else if (kind === "rename")
            runApi("rename", ["rename", modalThemeId, renameName.trim()]);
        else if (kind === "new-wallpaper")
            generateTheme(newWallpaper, newThemeName, newThemeId);
        else if (kind === "new-blank")
            runApi("new-template", ["show", "catppuccin-mocha"]);
        else if (kind === "wallpaper-remove") {
            restoreWallpaperForRemoval();
            runApi("wallpapers-remove", ["wallpapers", "remove", wallpaperRemovalId]);
        }

    }

    function completePendingNavigation() {
        const id = pendingSelection;
        pendingSelection = "";
        pendingPreviewContinuation = "";
        Theme.cancelPreview();
        baselineJson = candidate === null ? "" : JSON.stringify(candidate);
        requestSelection(id, false);
    }

    function dismissColourPicker() {
        if (typeof externalColourCommit === "function")
            externalColourCommit(colourPickerKey, colourPickerTarget, colourHex);
        externalColourApply = null;
        externalColourCommit = null;
        externalColourClear = null;
        colourDismissTimer.restart();
    }

    function handleResponse(request, response) {
        apiController.handleResponse(request, response);
    }

    onOpenChanged: {
        if (open)
            rendered = true;
        else
            hideTimer.restart();
    }

    onColourPickerOpenChanged: {
        if (!colourPickerOpen)
            Qt.callLater(restoreOverlayFocus);
    }

    SettingsColourController {
        id: colourController

        host: root
    }

    SettingsBarEditorModel {
        id: barModel

        host: root
    }

    SettingsWidgetController {
        id: widgetController

        host: root
    }

    SettingsHyprlandPreview {
        id: hyprlandPreview

        host: root
    }

    SettingsThemeApiController {
        id: apiController

        host: root
    }

    SettingsThemeCreationController {
        id: generationController

        host: root
    }

    Connections {
        target: hyprlandPreview

        function onOperationFinished(operation, successful, reason) {
            if (operation === "restore" && reason === "settings-apply" && root.settingsApplyPreviewPending) {
                root.settingsApplyPreviewPending = false;
                const message = successful ? "" : hyprlandPreview.lastError || "Could not restore the temporary Hyprland preview.";
                if (!successful) {
                    root.errorMessage = message;
                    root.releaseSettingsApplyPreview();
                }
                root.settingsApplyPreviewPrepared(successful, message);
                return;
            }
            if (operation !== "restore" || root.pendingPreviewContinuation.length === 0)
                return;

            const continuation = root.pendingPreviewContinuation;
            root.pendingPreviewContinuation = "";
            if (!successful) {
                root.errorMessage = hyprlandPreview.lastError || "Could not restore the temporary Hyprland preview.";
                return;
            }
            if (continuation === "navigate")
                Qt.callLater(root.completePendingNavigation);
        }
    }

    Connections {
        function onWidgetEditModeFinished(widgetsJson, returnWorkspace) {
            if (!root.widgetEditModePending)
                return ;

            root.widgetEditModePending = false;
            if (widgetsJson.length > 0) {
                try {
                    if (root.setWidgetItems(JSON.parse(widgetsJson)))
                        root.statusMessage = "Widget positions updated from edit mode.";
                    else
                        root.errorMessage = root.widgetDraftError || "Could not stage the widget positions.";
                } catch (error) {
                    root.errorMessage = "Could not read the widget edit result: " + error;
                }
            }
            root.rendered = true;
            root.widgetReturnWorkspace = returnWorkspace;
            root.recoverPickerWorkspace(returnWorkspace, false);
            revealTimer.restart();
        }

        target: Theme
    }

    Timer {
        id: revealTimer

        interval: 320
        repeat: false
        onTriggered: {
            if (!root.open || !root.rendered)
                return ;

            // Re-run recovery once the surface is mapped: the dispatch at
            // open time races the Wayland map and can miss the window.
            root.recoverPickerWorkspace(root.widgetReturnWorkspace, false);

            // Floating windows keep their Hyprland workspace across hides.
            // Move a picker stranded by widget edit mode back to the workspace
            Qt.callLater(() => {
                if (root.open && host._backingWindow)
                    host._backingWindow.requestActivate();

            });
        }
    }

    Timer {
        id: hideTimer

        interval: 180
        repeat: false
        onTriggered: {
            if (!root.open)
                root.rendered = false;

        }
    }

    Timer {
        id: modalDismissTimer

        interval: 80
        repeat: false
        onTriggered: root.completeModalDismissal()
    }

    Timer {
        id: colourDismissTimer

        interval: 80
        repeat: false
        onTriggered: root.colourPickerOpen = false
    }

    Timer {
        id: validationDelay

        interval: 300
        repeat: false
        onTriggered: root.validatePreview()
    }

    Timer {
        id: editorWheelSessionTimer

        interval: 450
        repeat: false
        onTriggered: root.editorWheelOwner = null
    }

    Timer {
        id: paletteDelay

        interval: 350
        repeat: false
        onTriggered: root.requestPalettes()
    }

    Process {
        id: browserTargetsProcess

        command: [root.apiPath, "targets", "--json"]
        onExited: root.loadBrowserTargets()

        stdout: StdioCollector {
            onStreamFinished: root.browserTargetOutput = this.text
        }
    }

    Process {
        id: wallpapersProcess

        command: [root.apiPath, "wallpapers", "migrate", "--json"]
        onExited: root.loadWallpapers()

        stdout: StdioCollector {
            onStreamFinished: root.wallpaperOutput = this.text
        }
    }

    Process {
        id: iconThemesProcess

        command: ["python3", root.scriptRoot + "/theme/icon_themes.py"]
        onExited: root.loadIconThemes()

        stdout: StdioCollector {
            onStreamFinished: root.iconThemeOutput = this.text
        }
    }

    Process {
        command: ["fc-list", "--format=%{family}\\n"]
        running: true
        onExited: {
            const seen = ({
            });
            const families = [];
            root.fontOutput.split("\n").forEach((line) => {
                line.split(",").forEach((value) => {
                    const family = value.trim();
                    if (family && !seen[family]) {
                        seen[family] = true;
                        families.push(family);
                    }
                });
            });
            families.sort((left, right) => {
                return left.localeCompare(right);
            });
            root.fontFamilies = families;
        }

        stdout: StdioCollector {
            onStreamFinished: root.fontOutput = this.text
        }

    }



}
