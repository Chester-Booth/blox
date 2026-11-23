import QtQuick
import Quickshell
import Quickshell.Io
import qs.shared

// Manages wallpaper library listing, filtering, selection, and removal confirmation
// for the Settings theme editor.
Scope {
    id: root

    required property var host
    property var wallpapers: []
    property bool wallpapersLoaded: false
    property string wallpaperOutput: ""
    property int wallpaperRevision: 0
    property string wallpaperFilter: "All"
    property string removalId: ""
    property string removalName: ""
    property string removalReference: ""
    property var removalUsers: []
    property string removalError: ""

    function resetRemovalState() {
        removalId = "";
        removalName = "";
        removalReference = "";
        removalUsers = [];
        removalError = "";
    }

    function refresh() {
        if (wallpapersProcess.running)
            return;
        wallpapersLoaded = false;
        wallpaperOutput = "";
        wallpapersProcess.running = true;
    }

    function load() {
        let response = null;
        try {
            response = JSON.parse(wallpaperOutput.trim());
        } catch (error) {
        }
        wallpapers = response && response.ok === true && Array.isArray(response.data) ? response.data : [];
        wallpapersLoaded = true;
        wallpaperRevision += 1;
    }

    function pathsEqual(left, right) {
        const leftPath = host.wallpaperDisplayPath(left);
        const rightPath = host.wallpaperDisplayPath(right);
        return leftPath.length > 0 && leftPath === rightPath;
    }

    function items() {
        wallpaperRevision;
        const entries = Array.isArray(wallpapers) ? wallpapers.slice() : [];
        const raw = host.candidate && host.candidate.wallpaper ? String(host.candidate.wallpaper.path || "").trim() : "";
        if (!raw)
            return entries;
        const present = entries.some((entry) => {
            return pathsEqual(raw, entry.reference || "") || pathsEqual(raw, entry.path || "");
        });
        if (!present && wallpapersLoaded) {
            const displayPath = host.wallpaperDisplayPath(raw);
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

    function filtered() {
        wallpaperRevision;
        const entries = items();
        if (wallpaperFilter === "All")
            return entries;
        return entries.filter((entry) => entry.kind === wallpaperFilter);
    }

    function isSelected(entry) {
        if (!entry || !host.candidate || !host.candidate.wallpaper)
            return false;
        const raw = String(host.candidate.wallpaper.path || "");
        return pathsEqual(raw, entry.reference || "") || pathsEqual(raw, entry.path || "");
    }

    function choose(entry) {
        if (!entry || entry.missing || !host.themeControlsEnabled || host.busy)
            return;
        host.setWallpaperPath(entry.reference || entry.path || "");
        host.statusMessage = "Previewing " + entry.name + ".";
    }

    function importFrom(path) {
        if (!host.candidate || !host.themeControlsEnabled || host.busy || !path)
            return;
        host.runApi("wallpapers-import", ["wallpapers", "import", path, "--theme-id", host.candidate.id]);
    }

    function requestRemoval(entry) {
        if (!entry || !entry.removable || !host.themeControlsEnabled || host.busy)
            return;
        removalId = entry.id || "";
        removalName = entry.name || "wallpaper";
        removalReference = entry.reference || entry.path || "";
        removalUsers = host.themes.filter((theme) => {
            const preview = theme && theme.preview ? theme.preview.wallpaper : "";
            return preview && (pathsEqual(preview, entry.reference || "") || pathsEqual(preview, entry.path || ""));
        }).map((theme) => theme.name || theme.id).filter((name, index, values) => name && values.indexOf(name) === index);
        removalError = "";
        host.showModal("wallpaper-remove");
    }

    function removalMessage() {
        if (removalUsers.length > 0)
            return "Cannot remove this wallpaper. It is used by: " + removalUsers.join(", ") + ". Choose another wallpaper in those themes first.";
        if (removalError.length > 0)
            return removalError;
        return "Blox removes its copy and leaves the original file where you imported it from.";
    }

    function restoreForRemoval() {
        if (!removalReference || !host.candidate || !host.candidate.wallpaper)
            return;
        if (!pathsEqual(host.candidate.wallpaper.path, removalReference))
            return;
        const activePath = host.wallpaperDisplayPath(Theme.activeWallpaperSource);
        if (activePath)
            host.setWallpaperPath(activePath);
    }

    Process {
        id: wallpapersProcess

        command: [root.host.apiPath, "wallpapers", "migrate", "--json"]
        onExited: root.load()

        stdout: StdioCollector {
            onStreamFinished: root.wallpaperOutput = this.text
        }
    }
}
