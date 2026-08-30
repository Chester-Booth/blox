import qs.shared
import QtQuick
import Quickshell

QtObject {
    id: root

    required property var host
    property var draft: null
    property int editIndex: -1
    property int selectedIndex: -1
    property bool editModePending: false

    function items() {
        return host.candidate && host.candidate.widgets && host.candidate.widgets.items ? host.candidate.widgets.items : [];
    }

    function localFileUrl(path) {
        const value = String(path || "");
        if (value.startsWith("file:"))
            return value;

        if (value.startsWith("~/"))
            return "file://" + Quickshell.env("HOME") + value.slice(1);

        if (value.startsWith("/"))
            return "file://" + value;

        if (host.baselineJson) {
            try {
                const source = JSON.parse(host.baselineJson);
                if (source.wallpaper && source.wallpaper.path === value) {
                    for (const theme of host.themes) {
                        if (theme.id === host.selectedId && theme.preview && theme.preview.wallpaper)
                            return localFileUrl(theme.preview.wallpaper);

                    }
                }
            } catch (error) {
                console.warn("[blox.theme-picker] rejected source theme baseline: " + error);
            }
        }
        return Theme.wallpaperUrl(value);
    }

    function localFilePath(path) {
        const url = String(localFileUrl(path));
        return url.startsWith("file://") ? url.slice(7) : url;
    }

    function previewCommand(widget) {
        const terminalTypes = ["music", "clock", "aquarium", "pipes", "tree", "matrix", "train"];
        const command = String(widget.content_command || "").replace(/\$SCRIPT_ROOT/g, host.scriptRoot);
        if (terminalTypes.indexOf(widget.type) < 0)
            return ["sh", "-c", command];

        const columns = Math.max(10, Math.floor((widget.width || 320) / 8));
        const rows = Math.max(4, Math.floor((widget.height || 160) / 18));
        return [host.scriptRoot + "/widgets/terminal-frame.py", widget.type, "--command", command, "--columns", String(columns), "--rows", String(rows)];
    }

    function setItems(items) {
        if (!host.widgetItemsChangeAllowed(items))
            return ;

        const next = host.cloneCandidate();
        if (!next.widgets)
            next.widgets = {
            "profile": "minimal"
        };

        next.widgets.items = items;
        host.markCandidate(next, "widgets.items", true);
    }

    function updateGeometry(index, anchor, offsetX, offsetY, width, height) {
        const current = items().slice();
        if (index < 0 || index >= current.length)
            return ;

        const item = JSON.parse(JSON.stringify(current[index]));
        item.anchor = anchor;
        item.offset_x = Math.max(-10000, Math.min(10000, Math.round(offsetX)));
        item.offset_y = Math.max(-10000, Math.min(10000, Math.round(offsetY)));
        item.width = width <= 0 ? 0 : Math.max(80, Math.round(width));
        item.height = height <= 0 ? 0 : Math.max(48, Math.round(height));
        current[index] = item;
        setItems(current);
    }

    function commitPreview(index, previewX, previewY, previewWidth, previewHeight, canvasWidth, canvasHeight) {
        const virtualWidth = 1920;
        const virtualHeight = 1080;
        const x = previewX * virtualWidth / canvasWidth;
        const y = previewY * virtualHeight / canvasHeight;
        const width = previewWidth * virtualWidth / canvasWidth;
        const height = previewHeight * virtualHeight / canvasHeight;
        const centreX = x + width / 2;
        const centreY = y + height / 2;
        let anchor = "centre";
        let offsetX = x - (virtualWidth - width) / 2;
        let offsetY = y - (virtualHeight - height) / 2;
        if (Math.abs(centreX - virtualWidth / 2) > virtualWidth * 0.16 || Math.abs(centreY - virtualHeight / 2) > virtualHeight * 0.16) {
            const right = centreX >= virtualWidth / 2;
            const bottom = centreY >= virtualHeight / 2;
            anchor = (bottom ? "bottom-" : "top-") + (right ? "right" : "left");
            offsetX = right ? virtualWidth - x - width : x;
            offsetY = bottom ? virtualHeight - y - height : y;
        }
        updateGeometry(index, anchor, offsetX, offsetY, width, height);
    }

    function newDraft(type) {
        const preset = type || "custom";
        const commands = {
            "music": "cava",
            "calendar": "gcalcli agenda",
            "clock": "tty-clock",
            "aquarium": "asciiquarium",
            "pipes": "pipes.sh",
            "tree": "cbonsai -l",
            "matrix": "unimatrix",
            "fortune": "fortune | cowsay",
            "train": "sl"
        };
        return {
            "id": "widget-" + (items().length + 1),
            "name": "New widget",
            "type": preset,
            "enabled": true,
            "content_command": commands[preset] || "",
            "left_click_command": "",
            "right_click_command": "",
            "interval_ms": 60000,
            "visibility": "empty-workspace",
            "anchor": "top-left",
            "offset_x": 20,
            "offset_y": 20,
            "width": 0,
            "height": 0,
            "shape": "auto",
            "options": {
                "auto_size": true,
                "scale": 1
            }
        };
    }

    function preset(item) {
        if (!item)
            return "custom";

        return ["aquarium", "pipes", "tree", "matrix", "fortune", "train"].indexOf(item.type) >= 0 ? "decorative" : item.type;
    }

    function updateDraft(values) {
        if (!draft)
            return ;

        const next = JSON.parse(JSON.stringify(draft));
        Object.keys(values).forEach((key) => {
            return next[key] = values[key];
        });
        draft = next;
    }

    function updateOption(key, value) {
        if (!draft)
            return ;

        const next = JSON.parse(JSON.stringify(draft));
        if (!next.options)
            next.options = {
        };

        next.options[key] = value;
        if (next.type === "clock") {
            const flags = ["tty-clock"];
            if (next.options.twelve_hour)
                flags.push("-t");

            if (next.options.seconds)
                flags.push("-s");

            if (next.options.bold)
                flags.push("-b");

            if (next.options.blink)
                flags.push("-B");

            if (next.options.box)
                flags.push("-x");

            if (next.options.hide_date)
                flags.push("-D");

            next.content_command = flags.join(" ");
        } else if (next.type === "calendar")
            next.content_command = "gcalcli --lineart " + (next.options.lineart || "unicode") + (next.options.colour === false ? " --nocolor" : "") + " " + (next.options.view === "month" ? "calm" : next.options.view === "week" ? "calw" : "agenda");
        else if (next.type === "music" && key === "config_file")
            next.content_command = value ? "cava -p " + shellQuote(value) : "cava";
        draft = next;
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    function openEditor(index) {
        editIndex = index;
        draft = index >= 0 ? JSON.parse(JSON.stringify(items()[index])) : newDraft("custom");
        host.showModal("widget");
    }

    function openEditMode() {
        if (!host.candidate || editModePending)
            return ;

        editModePending = true;
        host.rendered = false;
        Theme.widgetEditModeRequested();
    }

    function saveDraft() {
        if (!draft || !draft.name.trim() || !draft.id.trim())
            return ;

        const current = items().slice();
        if (editIndex >= 0)
            current[editIndex] = draft;
        else
            current.unshift(draft);
        setItems(current);
        host.dismissModal();
    }

}
