import QtQuick
import Quickshell
import Quickshell.Io
import qs.shared

// Read theme metadata from the existing theme runtime. Selection stays local until Apply.
Scope {
    id: root

    property string status: "idle"
    property string code: "ok"
    property string errorMessage: ""
    property var themes: []
    property string selectedThemeId: ""
    property string searchText: ""
    property int requestSerial: 0
    property string processOutput: ""
    readonly property string themeCliPath: Quickshell.shellDir + "/scripts/theme/themectl.sh"
    readonly property string appliedThemeId: Theme.activeThemeId
    readonly property string selectedThemeName: {
        const entry = themeFor(selectedThemeId);
        return entry ? entry.name : "";
    }
    readonly property bool dirty: selectedThemeId.length > 0
        && appliedThemeId.length > 0 && selectedThemeId !== appliedThemeId

    function refresh() {
        if (themeListProcess.running)
            return false;
        requestSerial += 1;
        processOutput = "";
        errorMessage = "";
        code = "pending";
        status = "loading";
        themeListProcess.command = [themeCliPath, "list", "--json"];
        themeListProcess.running = true;
        return true;
    }

    function readCompleted(exitCode, exitStatus) {
        let response = null;
        try {
            response = JSON.parse(processOutput.trim());
        } catch (error) {
            response = null;
        }
        if (exitCode !== 0 || exitStatus !== 0 || !response || response.ok !== true
                || response.api_version !== 1 || response.command !== "list"
                || !Array.isArray(response.data)) {
            code = response && typeof response.status === "string" ? response.status : "unavailable";
            errorMessage = response && Array.isArray(response.errors) && response.errors.length > 0
                ? response.errors.join("\n") : "Could not load themes.";
            status = "error";
            themes = [];
            return;
        }

        themes = response.data.filter(entry => entry && typeof entry.id === "string"
            && entry.id.length > 0 && typeof entry.name === "string" && entry.name.length > 0);
        const active = themes.find(entry => entry.id === appliedThemeId);
        if (!dirty)
            selectedThemeId = active ? active.id : themes.length > 0 ? themes[0].id : "";
        code = "ok";
        status = "ready";
    }

    function themeFor(id) {
        return themes.find(entry => entry.id === id) || null;
    }

    function selectTheme(id) {
        const entry = themeFor(id);
        if (!entry)
            return {version: 1, ok: false, code: "invalid-data", message: "The selected theme is unavailable.", data: null};
        const before = selectedThemeId;
        selectedThemeId = entry.id;
        return {
            version: 1,
            ok: true,
            code: "ok",
            message: "",
            data: {selectedThemeId: selectedThemeId, appliedThemeId: appliedThemeId, changed: before !== selectedThemeId}
        };
    }

    function filteredThemes() {
        const needle = searchText.trim().toLowerCase();
        if (!needle)
            return themes;
        return themes.filter(entry => String(entry.id + " " + entry.name).toLowerCase().indexOf(needle) >= 0);
    }

    function cardFor(id) {
        const entry = themeFor(id);
        if (!entry)
            return null;
        const source = entry.preview || {};
        const colours = source.colours || {};
        const bar = source.bar || {};
        const items = Array.isArray(bar.items) ? bar.items : [];
        const count = region => items.filter(item => item && item.enabled && item.region === region).length;
        const accent = colours.accent || Theme.blue;
        const success = colours.success || Theme.green;
        const warning = colours.warning || Theme.yellow;
        const foreground = colours.foreground || Theme.foreground;
        const wallpaper = String(source.wallpaper || "");
        return {
            id: entry.id,
            name: entry.name,
            meta: entry.builtin === true ? "Built in" : "Imported",
            builtin: entry.builtin === true,
            wallpaper: wallpaper.length > 0 ? Theme.wallpaperUrl(wallpaper) : "",
            palette: [accent, success, warning, foreground],
            preview: {
                background: colours.background || Theme.background,
                surface: colours.surface || Theme.surface,
                surfaceAlt: colours.surface_alt || Theme.surfaceAlt,
                foreground: foreground,
                muted: colours.muted || Theme.muted,
                accent: accent,
                success: success,
                warning: warning
            },
            barPosition: ["left", "right", "top", "bottom"].indexOf(bar.position) >= 0 ? bar.position : "top",
            barCounts: [count("start"), count("centre"), count("end")],
            previewFont: source.fonts && source.fonts.ui ? source.fonts.ui : Theme.bodyFontFamily
        };
    }

    function searchResults() {
        const needle = searchText.trim().toLowerCase();
        if (!needle)
            return themes;
        return themes.filter(entry => String(entry.id + " " + entry.name).toLowerCase().indexOf(needle) >= 0);
    }

    Process {
        id: themeListProcess
        command: [root.themeCliPath, "list", "--json"]
        onExited: (exitCode, exitStatus) => root.readCompleted(exitCode, exitStatus)
        stdout: StdioCollector {
            onStreamFinished: root.processOutput = this.text
        }
    }
}
