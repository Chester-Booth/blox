import QtQuick
import Quickshell
import Quickshell.Io
import qs.shared

// Discovers installed icon themes, browser theme targets, and font families
// lazily when the Settings theme editor opens.
Scope {
    id: root

    required property var host
    property var browserTargets: []
    property bool browserTargetsLoaded: false
    property string browserTargetOutput: ""
    property var iconThemes: []
    property bool iconThemesLoaded: false
    property string iconThemeOutput: ""
    property var fontFamilies: []
    property string fontOutput: ""
    property bool fontListLoaded: false

    function browserTargetInfo(key) {
        for (const entry of browserTargets) {
            if (entry.target === key)
                return entry;
        }
        return null;
    }

    function refreshBrowserTargets() {
        if (browserTargetsProcess.running)
            return;
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

    function refreshIconThemes() {
        if (iconThemesProcess.running)
            return;
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

    function ensureFontFamilies() {
        if (fontListLoaded || fontListProcess.running)
            return;
        fontOutput = "";
        fontListProcess.running = true;
    }

    Process {
        id: browserTargetsProcess

        command: [root.host.apiPath, "targets", "--json"]
        onExited: root.loadBrowserTargets()

        stdout: StdioCollector {
            onStreamFinished: root.browserTargetOutput = this.text
        }
    }

    Process {
        id: iconThemesProcess

        command: ["python3", root.host.scriptRoot + "/theme/icon_themes.py"]
        onExited: root.loadIconThemes()

        stdout: StdioCollector {
            onStreamFinished: root.iconThemeOutput = this.text
        }
    }

    Process {
        id: fontListProcess

        command: ["fc-list", "--format=%{family}\\n"]
        running: false
        onExited: {
            const seen = ({});
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
            families.sort((left, right) => left.localeCompare(right));
            root.fontFamilies = families;
            root.fontListLoaded = true;
        }

        stdout: StdioCollector {
            onStreamFinished: root.fontOutput = this.text
        }
    }
}
