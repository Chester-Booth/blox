import qs.shared
import QtQuick

QtObject {
    id: root

    required property var host
    property string backend: "matugen"
    property string newVariant: "dark"
    property bool generateAfterLoad: false
    property string newThemeName: ""
    property string newThemeId: ""
    property string newWallpaper: ""
    property string newFlowPage: "name"
    property var paletteOptions: []
    property int paletteRequestSerial: 0
    property string paletteRequestPath: ""
    property bool paletteLoading: false
    property bool creationBusy: false
    property var creationRequest: null
    property string downloadTarget: ""
    property string downloadFile: ""
    property bool downloadArchive: false

    function generatedFiles() {
        if (!host.candidate || !host.candidate.targets)
            return [];

        const files = {
            "quickshell": ["quickshell/theme.json"],
            "widgets": ["widgets/profile.json"],
            "kitty": ["kitty/theme.conf"],
            "wallpaper": ["hypr/wallpaper.json"],
            "gtk": ["gtk/gtk-3.0/settings.ini", "gtk/gtk-3.0/gtk.css", "gtk/gtk-4.0/settings.ini", "gtk/gtk-4.0/gtk.css", "gtk/metadata.json"],
            "helium": ["helium/manifest.json"],
            "chromium": ["chromium/manifest.json"],
            "cursor": ["cursor/metadata.json"],
            "hyprland": ["hyprland/theme.lua"],
            "hyprlock": ["hyprlock/theme.conf"],
            "btop": ["btop/theme.theme"],
            "micro": ["micro/blox-theme.micro"],
            "glow": ["glow/style.json"],
            "code": ["code/settings.json", "code/package.json", "code/themes/blox-generated-color-theme.json"],
            "cursor_editor": ["cursor-editor/settings.json", "cursor-editor/package.json", "cursor-editor/themes/blox-generated-color-theme.json"],
            "t3code": ["t3code/theme.json"],
            "stylus": ["stylus/blox-system.user.css", "stylus/manifest.json"],
            "obsidian": ["obsidian/style-settings.json"],
            "powerlevel10k": ["powerlevel10k/theme.zsh"]
        };
        const order = ["stylus"].concat(host.targetKeys.filter((target) => {
            return target !== "stylus";
        }));
        const result = [];
        for (const target of order) {
            if (!host.candidate.targets[target] || !files[target])
                continue;

            for (const file of files[target]) result.push({
                "target": target,
                "file": file,
                "name": file.slice(file.lastIndexOf("/") + 1)
            })
        }
        return result;
    }

    function generatedFileGroups() {
        const flatFiles = generatedFiles();
        const result = [];
        for (const file of flatFiles) {
            let group = null;
            for (const candidateGroup of result) {
                if (candidateGroup.target === file.target) {
                    group = candidateGroup;
                    break;
                }
            }
            if (group === null) {
                group = {
                    "target": file.target,
                    "files": []
                };
                result.push(group);
            }
            group.files.push(file);
        }
        return result;
    }

    function downloadFileTo(target, file) {
        if (host.busy)
            return ;

        downloadTarget = target;
        downloadFile = file;
        downloadArchive = false;
        host.host.dialogs.openGeneratedExport();
    }

    function downloadTargetArchive(target) {
        if (host.busy)
            return ;

        downloadTarget = target;
        downloadFile = target + "-generated-files.zip";
        downloadArchive = true;
        host.host.dialogs.openGeneratedExport();
    }

    function generate(wallpaper, displayName, themeId, requestedBackend, requestedVariant) {
        if (!wallpaper || !wallpaper.trim()) {
            host.errorMessage = "Choose a wallpaper first.";
            return ;
        }
        const selectedBackend = requestedBackend || backend;
        const selectedVariant = requestedVariant || newVariant;
        const args = ["generate", wallpaper.trim(), "--backend", selectedBackend, "--mode", selectedVariant];
        if (displayName)
            args.push("--name", displayName.trim());

        if (themeId)
            args.push("--id", themeId.trim());

        if (host.runApi("generate", args))
            host.activeRequest.inputs = {
            "wallpaper": wallpaper.trim(),
            "name": displayName || "",
            "id": themeId || "",
            "backend": selectedBackend,
            "variant": selectedVariant
        };

    }

    function requestPalettes() {
        const path = newWallpaper.trim();
        paletteRequestSerial += 1;
        paletteRequestPath = path;
        paletteOptions = [];
        if (!path) {
            paletteLoading = false;
            return ;
        }
        paletteLoading = true;
        if (host.runApi("palette", ["palette", path]))
            host.activeRequest.inputs = {
            "wallpaper": path,
            "paletteSerial": paletteRequestSerial
        };
        else
            paletteLoading = false;
    }

    function loadActive() {
        generateAfterLoad = false;
        return host.runApi("show-generate-current", ["show", Theme.activeThemeId]);
    }

    function continueQueued() {
        if (!generateAfterLoad || host.busy || !host.open)
            return ;

        if (host.dirty) {
            generateAfterLoad = false;
            host.showModal("generate-current");
            return ;
        }
        loadActive();
    }

    function requestCurrent() {
        host.openPicker();
        if (host.dirty) {
            host.showModal("generate-current");
            return "confirmation-required";
        }
        if (!host.busy)
            openNew(true);

        return host.busy ? "queued" : "choose-wallpaper";
    }

    function openNew(wallpaperPage) {
        if (host.busy || host.dirty)
            return ;

        newThemeName = "";
        newThemeId = host.duplicateIdForName(newThemeName);
        newWallpaper = "";
        newVariant = Theme.variant === "light" ? "light" : "dark";
        newFlowPage = wallpaperPage ? "wallpaper" : "blank";
        paletteOptions = [];
        paletteLoading = false;
        creationBusy = false;
        creationRequest = null;
        host.showModal("new");
    }

    function blankTheme(template, inputs) {
        const blank = JSON.parse(JSON.stringify(template));
        blank.id = inputs.id;
        blank.name = inputs.name;
        const variant = inputs.variant === "light" ? "light" : "dark";
        const light = variant === "light";
        blank.variant = variant;
        delete blank.generator;
        blank.colours = {
            "background": light ? "#ffffff" : "#111318",
            "surface": light ? "#ffffff" : "#1b1d23",
            "surface_alt": light ? "#f2f2f2" : "#252830",
            "foreground": light ? "#000000" : "#f2f3f5",
            "muted": light ? "#595959" : "#a9adb7",
            "accent": light ? "#005fcc" : "#8ab4f8",
            "danger": light ? "#b00020" : "#ff7b92",
            "success": light ? "#137333" : "#7bd88f",
            "warning": light ? "#8a4b00" : "#f6c177",
            "info": light ? "#005fcc" : "#78b9f2",
            "mauve": light ? "#6f42c1" : "#c4a7e7",
            "teal": light ? "#00796b" : "#6bd6c5",
            "selection_background": light ? "#000000" : "#f2f3f5",
            "selection_foreground": light ? "#ffffff" : "#111318",
            "border": light ? "#b3b3b3" : "#444852"
        };
        blank.terminal = {
            "ansi_source": "override",
            "canvas": light ? "#ffffff" : "#111318",
            "chrome_background": light ? "#f2f2f2" : "#1b1d23"
        };
        if (!blank.overrides)
            blank.overrides = {
        };

        blank.overrides.ansi = {
            "color0": light ? "#000000" : "#111318",
            "color1": light ? "#800000" : "#ff7b92",
            "color2": light ? "#008000" : "#7bd88f",
            "color3": light ? "#808000" : "#f6c177",
            "color4": light ? "#000080" : "#78b9f2",
            "color5": light ? "#800080" : "#c4a7e7",
            "color6": light ? "#008080" : "#6bd6c5",
            "color7": light ? "#c0c0c0" : "#d7d9df",
            "color8": light ? "#808080" : "#6d7280",
            "color9": light ? "#ff0000" : "#ff9aab",
            "color10": light ? "#00ff00" : "#9be5a8",
            "color11": light ? "#ffff00" : "#f9d99a",
            "color12": light ? "#0000ff" : "#9ac7ff",
            "color13": light ? "#ff00ff" : "#d7baf5",
            "color14": light ? "#00ffff" : "#91e1d5",
            "color15": light ? "#ffffff" : "#f2f3f5"
        };
        blank.wallpaper = {
            "fit": "cover",
            "path": light ? "~/Pictures/wallpapers/blank-light.png" : "~/Pictures/wallpapers/blank-dark.png"
        };
        blank.targets.wallpaper = true;
        return blank;
    }

    function startNew(fromWallpaper) {
        if (!newThemeName.trim() || !newThemeId.trim())
            return ;

        if (fromWallpaper && !newWallpaper.trim()) {
            host.errorMessage = "Choose a wallpaper first.";
            return ;
        }
        creationRequest = {
            "wallpaper": newWallpaper.trim(),
            "name": newThemeName.trim(),
            "id": newThemeId.trim(),
            "backend": backend,
            "variant": newVariant
        };
        creationBusy = true;
        host.errorMessage = "";
        if (fromWallpaper)
            generate(creationRequest.wallpaper, creationRequest.name, creationRequest.id, creationRequest.backend, creationRequest.variant);
        else if (host.runApi("new-template", ["show", "catppuccin-mocha"]))
            host.activeRequest.inputs = creationRequest;
    }

}
