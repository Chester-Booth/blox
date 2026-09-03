import QtQuick
import Quickshell

QtObject {
    id: root

    property string openPanel: ""
    property string scriptRoot: ""
    property date now: new Date()
    property bool clockDateMode: false
    property var updates: ({
    })
    property var battery: ({
    })
    property var powerProfile: ({
    })
    property var vendorPerformance: ({
    })
    property var gpu: ({
    })
    property var touchpad: ({
    })
    property real updatesLastUpdatedMs: 0
    property var bluetooth: ({
    })
    property var audio: ({
    })
    property var brightness: ({
    })
    property var network: ({
    })
    property var privacy: ({
    })
    property var caffeine: ({
    })

    function action(label, command, extra) {
        const value = {
            "label": label,
            "command": command
        };
        if (extra) {
            for (const key in extra) value[key] = extra[key]
        }
        return value;
    }

    function powerCommand(kind) {
        if (kind === "update-shutdown")
            return terminalCommand("update-shutdown", scriptRoot + "/update/run.sh; " + scriptRoot + "/power/safe.sh shutdown");

        return scriptRoot + "/power/safe.sh " + kind;
    }

    function terminalCommand(title, command) {
        const display = Quickshell.env("DISPLAY");
        const waylandDisplay = Quickshell.env("WAYLAND_DISPLAY");
        return "systemd-run --user --collect --quiet --setenv=DISPLAY=" + display + " --setenv=WAYLAND_DISPLAY=" + waylandDisplay + " -- kitty --class " + title + " --title " + title + " sh -c '" + command + "'";
    }

    function canChange(status) {
        return status && status.capability && status.capability.canChange === true;
    }

    function typedStatus(status, fields) {
        const result = {};
        for (const field of fields) {
            if (status && status[field] !== undefined)
                result[field] = status[field];
        }
        result.capability = status && status.capability ? status.capability : {
            "available": false,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "missing-status"
        };
        return result;
    }

    // This is the read-only action boundary used by the shell IPC handler and
    // bloxctl. Keep presentation strings out of the public result.
    function statusSnapshot() {
        return {
            "version": 1,
            "ok": true,
            "code": "ok",
            "message": "",
            "data": {
                "updates": typedStatus(updates, ["repoCount", "aurCount", "totalCount"]),
                "battery": typedStatus(battery, ["class", "capacity", "status", "timeLabel", "source", "onBattery", "batteryPresent"]),
                "powerProfile": typedStatus(powerProfile, ["profile", "onBattery", "profileServiceAvailable", "degradationReason"]),
                "vendorPerformance": typedStatus(vendorPerformance, ["vendor", "profile", "profileLabel", "profiles"]),
                "gpu": typedStatus(gpu, ["devices", "deviceCount", "discreteCount", "backend", "mode", "label", "gpuOn", "gpuUtil", "gpuTemp", "vramUsed", "vramTotal", "controlReason"]),
                "touchpad": typedStatus(touchpad, ["class", "device", "devices", "touchpadCount", "enabled"]),
                "network": typedStatus(network, ["class", "ssid", "signal", "freq", "device", "wifiEnabled"]),
                "bluetooth": typedStatus(bluetooth, ["class", "enabled"]),
                "audio": typedStatus(audio, ["volume", "muted", "micMuted", "micCanChange"]),
                "brightness": typedStatus(brightness, ["percent", "blueLightMode", "blueLightActive", "device", "backlightCount", "backlights", "ddcAvailable", "ddcDisplayCount", "ddcReason"]),
                "privacy": typedStatus(privacy, ["active", "microphoneCount", "videoCount"]),
                "caffeine": typedStatus(caffeine, ["active", "mode", "remaining"])
            }
        };
    }

    function updateSummary() {
        if (typeof updates.totalCount === "number")
            return updates.totalCount + " updates";

        return updates.summary || "Check updates";
    }

    function updateBody() {
        if (typeof updates.repoCount === "number" && typeof updates.aurCount === "number" && typeof updates.totalCount === "number")
            return updates.repoCount + " repo updates, " + updates.aurCount + " yay updates\n" + updates.totalCount + " total updates";

        return updates.details || "Update status unavailable";
    }

    function panelTitle() {
        const titles = {
            "privacy": "Privacy",
            "caffeine": "Awake",
            "updates": "Updates"
        };
        return titles[openPanel] || "";
    }

    function systemPanelTitle() {
        const titles = {
            "audio": "Audio",
            "network": "Network",
            "bluetooth": "Bluetooth",
            "brightness": "Display"
        };
        return titles[openPanel] || "";
    }

    function systemPanelBody() {
        if (openPanel === "audio")
            return "";

        if (openPanel === "network")
            return network.details || "Network unavailable";

        if (openPanel === "bluetooth")
            return bluetooth.details || "Bluetooth unavailable";

        if (openPanel === "brightness")
            return brightness.details || "Brightness unavailable";

        return "";
    }

    function systemPanelActions() {
        if (openPanel === "audio") {
            const actions = [action("Open app", "pavucontrol -t 3")];
            if (canChange(audio) && audio.micCanChange !== false)
                actions.unshift(action(audio.micMuted ? "Unmute mic" : "Mute mic", scriptRoot + "/control.sh mic-toggle", {
                    "id": "mic-toggle",
                    "keepOpen": true
                }));
            return actions;
        }

        if (openPanel === "network") {
            const actions = [action("Open app", scriptRoot + "/network/toggle-applet.sh")];
            if (canChange(network))
                actions.unshift(action(network.wifiEnabled === true ? "Disable" : "Enable", "", {
                    "id": "network-toggle",
                    "keepOpen": true
                }));
            return actions;
        }

        if (openPanel === "bluetooth") {
            const actions = [action("Open app", "blueman-manager")];
            if (canChange(bluetooth))
                actions.unshift(action(bluetooth.enabled === true ? "Disable" : "Enable", "", {
                    "id": "bluetooth-toggle",
                    "keepOpen": true
                }));
            return actions;
        }

        return [];
    }

    function updateIcon() {
        const value = updates.class || updates.alt || "zero";
        return value === "error" ? "" : value === "zero" ? "󰅠" : value === "lessfifty" ? "󰅢" : "󰧠";
    }

    function twoDigit(value) {
        return value < 10 ? "0" + value : String(value);
    }

    function railClockText(horizontal) {
        if (clockDateMode) {
            const days = horizontal ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] : ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
            if (horizontal)
                return days[now.getDay()] + " " + twoDigit(now.getDate()) + "/" + twoDigit(now.getMonth() + 1) + "/" + now.getFullYear();

            return days[now.getDay()] + "\n" + twoDigit(now.getDate()) + "\n" + twoDigit(now.getMonth() + 1) + "\n" + twoDigit(now.getFullYear() % 100);
        }
        const hour = now.getHours() % 12 || 12;
        if (horizontal) {
            const ampmState = now.getHours() < 12 ? "AM" : "PM";
            return twoDigit(hour) + ":" + twoDigit(now.getMinutes()) + ":" + twoDigit(now.getSeconds()) + " " + ampmState;
        }
        return twoDigit(hour) + "\n" + twoDigit(now.getMinutes()) + "\n" + twoDigit(now.getSeconds());
    }

    function elapsedText(ms) {
        if (!ms || ms <= 0)
            return "Not fetched yet";

        const elapsed = Math.max(0, Math.floor((now.getTime() - ms) / 1000));
        if (elapsed < 5)
            return "Fetched just now";

        if (elapsed < 60)
            return "Fetched " + elapsed + "s ago";

        const minutes = Math.floor(elapsed / 60);
        if (minutes < 60)
            return "Fetched " + minutes + "m ago";

        const hours = Math.floor(minutes / 60);
        return hours < 24 ? "Fetched " + hours + "h ago" : "Fetched " + Math.floor(hours / 24) + "d ago";
    }

    function panelSubtitle() {
        if (openPanel === "updates")
            return elapsedText(updatesLastUpdatedMs);

        if (openPanel === "caffeine")
            return caffeine.active ? (caffeine.hypridleRunning ? "Awake warning" : "Hypridle paused") : "Hypridle active";

        return "";
    }

    function panelHeaderActionIcon() {
        return openPanel === "updates" ? "󰑐" : "";
    }

    function panelHeaderActionCommand() {
        return openPanel === "updates" ? "__refresh_updates" : "";
    }

    function panelHeaderStatus() {
        if (openPanel !== "caffeine" || !caffeine.active)
            return "";

        return caffeine.mode === "indefinite" ? "∞" : caffeine.label || "";
    }

    function panelBody() {
        if (openPanel === "updates")
            return updateBody();

        if (openPanel === "caffeine")
            return "";

        if (openPanel === "privacy")
            return privacy.details || "Privacy status unavailable";

        return "";
    }

    function panelActions() {
        if (openPanel === "updates") {
            if (!updates.capability || updates.capability.available !== true || updates.capability.ready !== true)
                return [];

            const updateRun = terminalCommand("update", scriptRoot + "/update/run.sh; echo Done - press enter; read");
            const updateList = terminalCommand("update-list", scriptRoot + "/update/list.sh");
            return [action("Run updates", updateRun, {
                "icon": "󰇚"
            }), action("List updates", updateList, {
                "icon": ""
            })];
        }
        if (openPanel === "caffeine")
            return [action("Off", scriptRoot + "/status/caffeine.sh off", {
            "id": "off",
            "icon": "󰒲",
            "keepOpen": true
        }), action("30 mins", scriptRoot + "/status/caffeine.sh 30m", {
            "id": "30m",
            "icon": "󰔟",
            "keepOpen": true
        }), action("1 hr", scriptRoot + "/status/caffeine.sh 1h", {
            "id": "1h",
            "icon": "󰞌",
            "keepOpen": true
        }), action("Indefinite", scriptRoot + "/status/caffeine.sh indefinite", {
            "id": "indefinite",
            "icon": "󰒳",
            "keepOpen": true
        })];

        return [];
    }

}
