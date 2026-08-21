import "../shared"
import QtQuick
import Quickshell
import Quickshell.Io

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
    property string selectedId: ""
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
    property string guideTarget: ""
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
    readonly property bool dirty: candidate !== null && JSON.stringify(candidate) !== baselineJson
    readonly property string apiPath: Quickshell.shellDir + "/scripts/theme/themectl.sh"
    readonly property string scriptRoot: Quickshell.shellDir + "/scripts"
    readonly property var semanticKeys: ["background", "surface", "surface_alt", "foreground", "muted", "accent", "danger", "success", "warning", "info", "mauve", "teal", "selection_background", "selection_foreground", "border"]
    readonly property var ansiKeys: ["color0", "color1", "color2", "color3", "color4", "color5", "color6", "color7", "color8", "color9", "color10", "color11", "color12", "color13", "color14", "color15"]
    readonly property var overrideKeys: ["background", "foreground", "accent", "border"]
    readonly property var targetKeys: ["quickshell", "widgets", "gtk", "cursor", "wallpaper", "kitty", "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "stylus", "obsidian", "powerlevel10k", "sddm", "grub"]
    readonly property var unavailableTargetKeys: ["sddm", "grub"]
    readonly property var coreTargetKeys: ["quickshell", "widgets", "wallpaper", "hyprland", "hyprlock", "cursor"]
    readonly property var applicationTargetKeys: ["kitty", "gtk", "btop", "micro", "glow", "code", "cursor_editor", "stylus", "obsidian", "powerlevel10k"]
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
        return unavailableTargetKeys.indexOf(key) < 0;
    }

    function targetLabel(key) {
        if (key === "sddm" || key === "grub")
            return key + " · unavailable";

        return key;
    }

    function targetApplyMode(key) {
        if (key === "stylus" || key === "obsidian")
            return "manual";

        if (["gtk", "cursor", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "powerlevel10k"].indexOf(key) >= 0)
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
        // An interrupted widget-edit transition used to leave the picker open
        // internally but permanently hidden.  Opening the picker is an
        // explicit request to return to it, so always cancel that transient
        // mode first.
        widgetEditModePending = false;
        Theme.widgetEditModeCancelRequested();
        open = true;
        rendered = true;
        recoverPickerWorkspace("");
        revealTimer.restart();
        statusMessage = "Loading themes…";
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
        validationPending = false;
        validationDelay.stop();
        Theme.cancelPreview();
        open = false;
        modalKind = "";
        candidate = null;
        candidateRevision += 1;
        selectedId = "";
        sourceDigest = "";
        baselineJson = "";
        candidateValid = false;
        validationErrors = [];
        pendingAfterSave = "";
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
            Theme.cancelPreview();
            statusMessage = "Active theme";
            return ;
        }
        Theme.previewSource(source);
        statusMessage = dirty ? "Temporary Quickshell preview — unsaved" : "Temporary Quickshell preview";
    }

    function markCandidate(value) {
        candidate = value;
        candidateRevision += 1;
        candidateValid = false;
        validationPending = true;
        validationDelay.restart();
    }

    function setTopLevel(key, value) {
        const next = cloneCandidate();
        next[key] = value;
        markCandidate(next);
    }

    function setColour(key, value) {
        const next = cloneCandidate();
        next.colours[key] = value;
        markCandidate(next);
    }

    function setFont(key, value) {
        const next = cloneCandidate();
        next.fonts[key] = value;
        markCandidate(next);
    }

    function setWidgetProfile(value) {
        const next = cloneCandidate();
        next.widgets = next.widgets || {
        };
        next.widgets.profile = value;
        markCandidate(next);
    }

    function setTarget(key, value) {
        if (!targetAvailable(key))
            return ;

        const next = cloneCandidate();
        next.targets[key] = value;
        markCandidate(next);
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

        markCandidate(next);
    }

    function setWallpaperPath(path) {
        if (!candidate)
            return ;

        const next = cloneCandidate();
        next.wallpaper.path = String(path || "").trim();
        markCandidate(next);
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
                "position": "left"
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
        const shell = candidate && candidate.shell ? candidate.shell : shellDefaults();
        return shell[section][key];
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
        markCandidate(next);
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
        if (sourceDigest)
            args.push("--replace", "--expect-sha256", sourceDigest);

        runApi("save", args);
    }

    function applyCandidate() {
        if (candidate === null || !candidateValid || busy)
            return ;

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
        if (dirty || !sourceDigest) {
            saveCandidate("apply");
            return ;
        }
        runApi("apply", ["apply", candidate.id]);
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
        runApi("apply-retry", ["apply", candidate.id, "--targets", target]);
    }

    function revertCandidate() {
        if (!baselineJson)
            return ;

        candidate = JSON.parse(baselineJson);
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
            Theme.cancelPreview();
            baselineJson = candidate === null ? "" : JSON.stringify(candidate);
            const id = pendingSelection;
            pendingSelection = "";
            requestSelection(id, false);
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

    ThemePickerApiController {
        id: apiController

        host: root
    }

    ThemePickerGenerationController {
        id: generationController

        host: root
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
        id: paletteDelay

        interval: 350
        repeat: false
        onTriggered: root.requestPalettes()
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
