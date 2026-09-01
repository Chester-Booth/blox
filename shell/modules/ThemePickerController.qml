import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io
import "../shared/Shape.js" as Shape

Scope {
    id: root

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
    property string searchText: ""
    property string editorMode: "overview"
    property alias generatorBackend: generationController.backend
    property alias newVariant: generationController.newVariant
    property string pendingAfterSave: ""
    property string pendingPreviewContinuation: ""
    property string pendingSelection: ""
    property string modalKind: ""
    property string pendingModalConfirmation: ""
    property alias generateAfterLoad: generationController.generateAfterLoad
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
    property var applyProgressRows: []
    property bool applyProgressComplete: false
    property var applyProgressStages: []
    property real applyProgressValue: 0
    property string applyProgressMessage: "Preparing theme application"
    property bool applyProgressShowTargets: false
    property bool applyQuickshellReloadPending: false
    property string guideTarget: ""
    property string guideReturnModalKind: ""
    property alias widgetDraft: widgetController.draft
    property alias widgetEditIndex: widgetController.editIndex
    property alias selectedWidgetIndex: widgetController.selectedIndex
    property alias widgetEditModePending: widgetController.editModePending
    property bool exportIncludeWallpaper: true
    property bool exportIncludeWidgets: true
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
    readonly property var iconSampleKeys: ["folder", "document", "network", "audio"]
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

    function themePreviewColour(entry, key, fallback) {
        const colours = entry && entry.preview ? entry.preview.colours || {
        } : {
        };
        return validColour(colours[key], fallback);
    }

    function themePreviewBarPosition(entry) {
        const bar = entry && entry.preview ? entry.preview.bar || {
        } : {
        };
        const position = String(bar.position || "left");
        return ["left", "right", "top", "bottom"].indexOf(position) >= 0 ? position : "left";
    }

    function themePreviewBarCount(entry, region) {
        const bar = entry && entry.preview ? entry.preview.bar || {
        } : {
        };
        const items = Array.isArray(bar.items) ? bar.items : [];
        let count = 0;
        for (let index = 0; index < items.length; ++index) {
            if (items[index].enabled && items[index].region === region)
                count += 1;

        }
        return count;
    }

    function longestWord(text) {
        const words = String(text || "").split(" ");
        return words.reduce((longest, word) => {
            return word.length > longest.length ? word : longest;
        }, "");
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

    function filteredThemes() {
        const needle = searchText.trim().toLowerCase();
        const entries = themes.slice();
        if (candidate && !sourceDigest && !entries.some((entry) => {
            return entry.id === candidate.id;
        }))
            entries.unshift({
            "id": candidate.id,
            "name": candidate.name,
            "variant": candidate.variant,
            "unsaved": true
        });

        if (!needle)
            return entries;

        return entries.filter((entry) => {
            return String(entry.id + " " + entry.name).toLowerCase().indexOf(needle) >= 0;
        });
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
        focusBeforeOverlay = host.contentItem.QsWindow.window.activeFocusItem;
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

    function openWidgetFileDialog() {
        host.dialogs.openWidgetFile();
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
        if (guideReturnModalKind === "progress") {
            modalKind = "guide";
            Qt.callLater(focusModal);
        } else {
            showModal("guide");
        }
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

    function refreshThemes(refreshOnly) {
        runApi(refreshOnly ? "list-refresh" : "list", ["list"]);
    }

    function recoverPickerWorkspace(returnWorkspace) {
        // The picker is recreated on the widget-edit workspace when Save
        // finishes. Move that existing window to the current workspace using
        // Hyprland's structured Lua dispatcher; the legacy
        // `movetoworkspacesilent` syntax is rejected by current Hyprland.
        Quickshell.execDetached(["sh", "-c", "requested=$1; if [ -n \"$requested\" ]; then hyprctl dispatch \"hl.dsp.focus({ workspace = \\\"$requested\\\" })\" >/dev/null; sleep 0.15; workspace=$requested; else if [ \"$(hyprctl activeworkspace -j | jq -r .name)\" = blox-widget-edit ]; then hyprctl dispatch 'hl.dsp.focus({ workspace = \"previous\" })' >/dev/null; sleep 0.15; fi; workspace=$(hyprctl activeworkspace -j | jq -r .id); fi; [ -n \"$workspace\" ] || exit 0; hyprctl dispatch \"hl.dsp.window.move({ workspace = \\\"$workspace\\\", follow = false, window = \\\"title:^Blox Theme Picker$\\\" })\" >/dev/null", "blox-picker-recover", String(returnWorkspace || "")]);
    }

    function openPicker() {
        hideTimer.stop();
        editorWheelOwner = null;
        editorWheelSessionTimer.stop();
        // An interrupted widget-edit transition used to leave the picker open
        // internally but permanently hidden.  Opening the picker is an
        // explicit request to return to it, so always cancel that transient
        // mode first.
        widgetEditModePending = false;
        Theme.widgetEditModeCancelRequested();
        open = true;
        rendered = true;
        hyprlandPreview.recover();
        recoverPickerWorkspace("");
        revealTimer.restart();
        statusMessage = "Loading themes…";
        refreshBrowserTargets();
        refreshIconThemes();
        refreshThemes(false);
        return "open";
    }

    function requestClose() {
        if (busy && action !== "preview-edit")
            return "busy";

        if (dirty) {
            showModal("close");
            return "confirmation-required";
        }
        closePicker();
        return "closed";
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
        applyQuickshellReloadPending = false;
        guideTarget = "";
        guideReturnModalKind = "";
        pendingAfterSave = "";
        pendingPreviewContinuation = "";
        pendingSelection = "";
        pendingModalConfirmation = "";
        generateAfterLoad = false;
        focusBeforeOverlay = null;
        hideTimer.restart();
    }

    function requestSelection(id, confirmDirty) {
        if (!id || id === selectedId && candidate !== null)
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

    function hyprlandValue(key, fallback) {
        return candidate && candidate.hyprland && candidate.hyprland[key] !== undefined
            ? candidate.hyprland[key]
            : fallback;
    }

    function setHyprlandValue(key, value) {
        if (!candidate)
            return;

        const next = cloneCandidate();
        next.hyprland = next.hyprland || {};
        if (value === null || value === undefined)
            delete next.hyprland[key];
        else
            next.hyprland[key] = value;
        markCandidate(next, "hyprland." + key);
    }

    function setHyprlandInactiveOpacity(value) {
        if (!Number.isFinite(value))
            return;

        setHyprlandValue("inactive_opacity", Math.max(0.1, Math.min(1.0, Math.round(value * 100) / 100)));
    }

    function setHyprlandBorderSize(value) {
        if (!Number.isFinite(value))
            return;

        setHyprlandValue("border_size", Math.max(0, Math.min(8, Math.round(value))));
    }

    function markCandidatePaths(value, paths, allowBuiltinChange) {
        if (selectedThemeBuiltin && !allowBuiltinChange)
            return false;

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
        if (!candidate || index < 0 || index >= stylusStyleSetValues.length)
            return ;

        const next = cloneCandidate();
        next.stylus = next.stylus || {
        };
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

    function shapeValue(key, fallback) {
        return candidate && candidate.shape && candidate.shape[key] !== undefined
            ? candidate.shape[key]
            : fallback;
    }

    function effectiveWindowGap() {
        return candidate && candidate.shape ? Shape.effectiveWindowGap(candidate.shape) : 5;
    }

    function cursorValue(key, fallback) {
        return candidate && candidate.cursor && candidate.cursor[key] !== undefined
            ? candidate.cursor[key]
            : fallback;
    }

    function cursorGenerated() {
        return cursorValue("mode", "generated") === "generated";
    }

    function cursorFollowsThemeRoundness() {
        return cursorValue("shape_source", "theme") === "theme";
    }

    function cursorEffectiveBase() {
        return shapeValue("radius_scale", 1.25) === 0
            ? "Bibata-Original-Classic"
            : "Bibata-Modern-Classic";
    }

    function cursorShapeIndex() {
        const base = cursorFollowsThemeRoundness()
            ? cursorEffectiveBase()
            : cursorValue("base", "Bibata-Modern-Classic");
        return ["Bibata-Original-Classic", "Bibata-Modern-Classic"].indexOf(base);
    }

    function cursorDirectionIndex() {
        return ["right", "left"].indexOf(cursorValue("handedness", "right"));
    }

    function cursorSize() {
        const sizes = cursorValue("sizes", [26]);
        if (!Array.isArray(sizes) || sizes.length === 0 || !Number.isInteger(sizes[0]))
            return 26;
        return sizes[0];
    }

    function setCursorFollowsThemeRoundness(follows) {
        if (!candidate || !cursorGenerated() || cursorFollowsThemeRoundness() === !!follows)
            return ;

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
        if (!candidate || !cursorGenerated() || index < 0 || index > 1)
            return ;

        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        next.cursor.base = index === 0 ? "Bibata-Original-Classic" : "Bibata-Modern-Classic";
        next.cursor.shape_source = "override";
        markCandidatePaths(next, ["cursor.base", "cursor.shape_source"]);
    }

    function setCursorDirection(index) {
        if (!candidate || !cursorGenerated() || index < 0 || index > 1)
            return ;

        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        next.cursor.handedness = index === 0 ? "right" : "left";
        markCandidate(next, "cursor.handedness");
    }

    function setCursorSize(value) {
        if (!candidate || !candidate.cursor || !Number.isFinite(value))
            return ;

        const size = Math.max(16, Math.min(96, Math.round(value)));
        const next = cloneCandidate();
        next.cursor = next.cursor || {};
        const existing = Array.isArray(next.cursor.sizes) ? next.cursor.sizes : [];
        const remaining = existing.slice(1).filter(entry => entry !== size);
        next.cursor.sizes = [size].concat(remaining);
        markCandidate(next, "cursor.sizes");
    }

    function setShapeValue(key, value) {
        if (!candidate)
            return;

        const next = cloneCandidate();
        next.shape = next.shape || {"radius_scale": 1.25, "density_scale": 1.0};
        if (value === null || value === undefined)
            delete next.shape[key];
        else
            next.shape[key] = value;
        markCandidate(next, "shape." + key);
    }

    function setAutomaticWindowGap(automatic) {
        if (!candidate)
            return;

        if (automatic) {
            setShapeValue("window_gap", null);
            return;
        }
        setShapeValue("window_gap", effectiveWindowGap());
    }

    function barOverrideSpec(axis) {
        return axis === "radius" ? {
            "automatic": "radius_automatic",
            "value": "radius_scale",
            "shape": "radius_scale",
            "fallback": 1.25
        } : {
            "automatic": "density_automatic",
            "value": "density_scale",
            "shape": "density_scale",
            "fallback": 1.0
        };
    }

    function barOverrideAutomatic(axis) {
        const spec = barOverrideSpec(axis);
        const value = shellValue("bar", spec.automatic);
        return value === undefined ? true : value;
    }

    function barOverrideValue(axis) {
        const spec = barOverrideSpec(axis);
        const inherited = shapeValue(spec.shape, spec.fallback);
        if (barOverrideAutomatic(axis))
            return inherited;

        const value = shellValue("bar", spec.value);
        return value === undefined ? inherited : value;
    }

    function setBarOverrideAutomatic(axis, automatic) {
        if (!candidate)
            return ;

        const spec = barOverrideSpec(axis);
        const next = cloneCandidate();
        if (!next.shell)
            next.shell = shellDefaults();
        if (!next.shell.bar)
            next.shell.bar = { };

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
        if (!candidate)
            return ;

        const spec = barOverrideSpec(axis);
        const next = cloneCandidate();
        if (!next.shell)
            next.shell = shellDefaults();
        if (!next.shell.bar)
            next.shell.bar = { };

        next.shell.bar[spec.value] = value;
        next.shell.bar[spec.automatic] = false;
        markCandidatePaths(next, ["shell.bar." + spec.value, "shell.bar." + spec.automatic]);
        Theme.loadShell(next.shell);
    }

    function setWidgetProfile(value) {
        const next = cloneCandidate();
        next.widgets = next.widgets || {
        };
        next.widgets.profile = value;
        markCandidate(next, "widgets.profile");
    }

    function setTarget(key, value) {
        if (!candidate)
            return ;
        if (!targetAvailable(key))
            return ;

        const next = cloneCandidate();
        next.targets[key] = value;
        markCandidate(next, "targets." + key, true);
    }

    function setOverride(target, key, value) {
        const next = cloneCandidate();
        if (!next.overrides)
            next.overrides = {
        };

        if (!next.overrides[target])
            next.overrides[target] = {
        };

        if (value.trim().length === 0)
            delete next.overrides[target][key];
        else
            next.overrides[target][key] = value.trim();
        if (Object.keys(next.overrides[target]).length === 0)
            delete next.overrides[target];

        if (Object.keys(next.overrides).length === 0)
            delete next.overrides;

        if (target === "ansi")
            next.terminal.ansi_source = "override";

        markCandidate(next, "overrides." + target + "." + key);
    }

    function setWallpaperPath(path) {
        if (!candidate)
            return ;

        const next = cloneCandidate();
        next.wallpaper.path = String(path || "").trim();
        markCandidate(next, "wallpaper.path");
    }

    function setWallpaperDisplayPath(path) {
        const value = String(path || "").trim();
        if (!candidate || value === wallpaperDisplayPath(candidate.wallpaper.path))
            return ;

        setWallpaperPath(value);
    }

    function shellDefaults() {
        return {
            "bar": {
                "position": "left",
                "separate_groups": false,
                "border": false,
                "edge_inset": 0
            },
            "osd": {
                "position": "top-left",
                "offset_x": 0,
                "offset_y": 0
            },
            "notifications": {
                "position": "bottom-right",
                "offset_x": 0,
                "offset_y": 0
            }
        };
    }

    function shellValue(section, key) {
        const defaults = shellDefaults();
        const shell = candidate && candidate.shell ? candidate.shell : defaults;
        const sectionDefaults = defaults[section] || ({ });
        const values = shell[section] || sectionDefaults;
        return values[key] === undefined ? sectionDefaults[key] : values[key];
    }

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

    function widgetItems() {
        return widgetController.items();
    }

    function localFileUrl(path) {
        return widgetController.localFileUrl(path);
    }

    function wallpaperDisplayPath(path) {
        return widgetController.localFilePath(path);
    }

    function widgetPreviewCommand(widget) {
        return widgetController.previewCommand(widget);
    }

    function setWidgetItems(items) {
        widgetController.setItems(items);
    }

    function widgetItemsChangeAllowed(nextItems) {
        if (!selectedThemeBuiltin)
            return true;

        const currentItems = widgetItems();
        if (!Array.isArray(nextItems) || nextItems.length !== currentItems.length)
            return false;

        for (let index = 0; index < currentItems.length; ++index) {
            const current = JSON.parse(JSON.stringify(currentItems[index]));
            const next = JSON.parse(JSON.stringify(nextItems[index]));
            delete current.enabled;
            delete next.enabled;
            if (JSON.stringify(current) !== JSON.stringify(next))
                return false;
        }
        return true;
    }

    function updateWidgetGeometry(index, anchor, offsetX, offsetY, width, height) {
        widgetController.updateGeometry(index, anchor, offsetX, offsetY, width, height);
    }

    function commitWidgetPreview(index, previewX, previewY, previewWidth, previewHeight, canvasWidth, canvasHeight) {
        widgetController.commitPreview(index, previewX, previewY, previewWidth, previewHeight, canvasWidth, canvasHeight);
    }

    function newWidgetDraft(type) {
        return widgetController.newDraft(type);
    }

    function widgetPreset(item) {
        return widgetController.preset(item);
    }

    function updateWidgetDraft(values) {
        widgetController.updateDraft(values);
    }

    function updateWidgetOption(key, value) {
        widgetController.updateOption(key, value);
    }

    function shellQuote(value) {
        return widgetController.shellQuote(value);
    }

    function openWidgetEditor(index) {
        widgetController.openEditor(index);
    }

    function openWidgetEditMode() {
        widgetController.openEditMode();
    }

    function saveWidgetDraft() {
        widgetController.saveDraft();
    }

    function openWallpaperDialog(target) {
        wallpaperDialogTarget = target || "overview";
        host.dialogs.openWallpaper();
    }

    function openImportDialog() {
        if (!busy && !dirty)
            host.dialogs.openImport();

    }

    function openExportDialog() {
        if (busy || dirty || !candidate || !sourceDigest)
            return ;

        exportIncludeWallpaper = true;
        exportIncludeWidgets = true;
        showModal("export");
    }

    function generatedFiles() {
        return generationController.generatedFiles();
    }

    function generatedFileGroups() {
        return generationController.generatedFileGroups();
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

    function loadActiveForGeneration() {
        return generationController.loadActive();
    }

    function continueQueuedGeneration() {
        generationController.continueQueued();
    }

    function requestGenerateCurrent() {
        return generationController.requestCurrent();
    }

    function saveCandidate(after) {
        if (candidate === null || !candidateValid || busy)
            return ;

        pendingAfterSave = after || "";
        const args = ["save", JSON.stringify(candidate)];
        if (sourceTheme !== null)
            args.push("--source", JSON.stringify(sourceTheme));
        if (touchedPaths.length > 0)
            args.push("--touched", JSON.stringify(touchedPaths));
        if (sourceDigest)
            args.push("--replace", "--expect-sha256", sourceDigest);

        runApi("save", args);
    }

    function applyCandidate() {
        if (candidate === null || !candidateValid || busy)
            return ;

        pendingPreviewContinuation = "apply";
        if (hyprlandPreview.restoreFor("apply"))
            return ;

        pendingPreviewContinuation = "";
        beginApplyCandidate();
    }

    function beginApplyCandidate() {
        if (candidate === null || !candidateValid || busy)
            return ;

        errorMessage = "";
        applyProgressComplete = false;
        applyProgressStages = [{
            "id": "prepare",
            "name": "Prepare",
            "state": "active",
            "message": "Checking theme and dependencies"
        }, {
            "id": "cursor",
            "name": "Cursor assets",
            "state": "queued",
            "message": "Check or build generated assets"
        }, {
            "id": "activation",
            "name": "Activate",
            "state": "queued",
            "message": "Write and activate the theme"
        }, {
            "id": "applications",
            "name": "Applications",
            "state": "queued",
            "message": "Apply enabled targets"
        }];
        applyProgressValue = 0;
        applyProgressMessage = "Checking theme and dependencies";
        applyProgressShowTargets = false;
        applyQuickshellReloadPending = false;
        applyProgressRows = targetKeys.filter((key) => {
            return candidate.targets[key] && targetAvailable(key);
        }).map((key) => {
            return ({
                "target": key,
                "state": "queued",
                "message": "Queued"
            });
        });
        showModal("progress");
        if (selectedThemeBuiltin) {
            runApi("apply-inline", ["apply-inline", JSON.stringify(candidate), "--defer-quickshell-restart"]);
            return ;
        }
        if (dirty || !sourceDigest) {
            saveCandidate("apply");
            return ;
        }
        runApi("apply", ["apply", candidate.id, "--defer-quickshell-restart"]);
    }

    function completeApply() {
        if (!applyProgressComplete)
            return ;

        const reloadQuickshell = applyQuickshellReloadPending;
        applyQuickshellReloadPending = false;
        modalKind = "";
        Qt.callLater(restoreOverlayFocus);
        if (reloadQuickshell)
            Qt.callLater(() => Theme.reloadCursor());
    }

    function handleApplyProgress(event) {
        if (!event || event.type !== "theme-progress")
            return ;

        applyProgressValue = event.total > 0 ? Number(event.completed || 0) / Number(event.total) : applyProgressValue;
        applyProgressMessage = event.message || applyProgressMessage;
        if (event.kind === "stage") {
            applyProgressStages = applyProgressStages.map((stage) => {
                return stage.id === event.stage ? Object.assign({
                }, stage, {
                    "state": event.state,
                    "message": event.message
                }) : stage;
            });
            if (event.stage === "applications" && event.state !== "queued")
                applyProgressShowTargets = true;

        } else if (event.kind === "target") {
            applyProgressShowTargets = true;
            applyProgressRows = applyProgressRows.map((row) => {
                return row.target === event.target ? Object.assign({
                }, row, {
                    "state": event.state,
                    "message": event.message
                }) : row;
            });
        }
    }

    function retryApplyTarget(target) {
        if (busy || candidate === null)
            return ;

        applyProgressComplete = false;
        applyProgressShowTargets = true;
        applyProgressMessage = "Retrying " + target.replace("cursor_editor", "cursor");
        applyProgressRows = applyProgressRows.map((row) => {
            return row.target === target ? Object.assign({
            }, row, {
                "state": "active",
                "message": "Retrying…"
            }) : row;
        });
        runApi("apply-retry", ["apply", candidate.id, "--targets", target, "--defer-quickshell-restart"]);
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
        else if (kind === "export")
            host.dialogs.openExport();
        else if (kind === "generate-current")
            loadActiveForGeneration();
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

    ThemePickerColourController {
        id: colourController

        host: root
    }

    ThemePickerBarModel {
        id: barModel

        host: root
    }

    ThemePickerWidgetController {
        id: widgetController

        host: root
    }

    ThemePickerHyprlandPreview {
        id: hyprlandPreview

        host: root
    }

    ThemePickerApiController {
        id: apiController

        host: root
    }

    ThemePickerGenerationController {
        id: generationController

        host: root
    }

    Connections {
        target: hyprlandPreview

        function onOperationFinished(operation, successful, reason) {
            if (operation !== "restore" || root.pendingPreviewContinuation.length === 0)
                return;

            const continuation = root.pendingPreviewContinuation;
            root.pendingPreviewContinuation = "";
            if (!successful) {
                root.errorMessage = hyprlandPreview.lastError || "Could not restore the temporary Hyprland preview.";
                return;
            }
            if (continuation === "apply")
                Qt.callLater(root.beginApplyCandidate);
            else if (continuation === "navigate")
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
                    root.setWidgetItems(JSON.parse(widgetsJson));
                    root.statusMessage = "Widget positions updated from edit mode.";
                } catch (error) {
                    root.errorMessage = "Could not read the widget edit result: " + error;
                }
            }
            root.rendered = true;
            root.recoverPickerWorkspace(returnWorkspace);
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
            root.recoverPickerWorkspace("");

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

    IpcHandler {
        function open() : string {
            return root.openPicker();
        }

        function close() : string {
            return root.requestClose();
        }

        function cancel() : string {
            root.closePicker();
            return "cancelled";
        }

        function toggle() : string {
            if (root.open)
                return close();

            return open();
        }

        function generateCurrent() : string {
            return root.requestGenerateCurrent();
        }

        function mode(value: string) : string {
            if (value !== "overview" && value !== "advanced" && value !== "widgets")
                return "invalid-mode";

            root.editorMode = value;
            return root.editorMode;
        }

        function select(value: string) : string {
            root.requestSelection(value, true);
            return value === root.selectedId ? "selected" : root.modalKind === "navigate" ? "confirmation-required" : "loading";
        }

        function status() : string {
            return JSON.stringify({
                "open": root.open,
                "busy": root.busy,
                "dirty": root.dirty,
                "valid": root.candidateValid,
                "selected_id": root.selectedId,
                "mode": root.editorMode,
                "modal": root.modalKind
            });
        }

        target: "themePicker"
    }

}
