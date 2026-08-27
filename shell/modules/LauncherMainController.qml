import qs.shared
import "../shared/Fuzzy.js" as Fuzzy
import "../shared/LauncherLogic.js" as LauncherLogic
import QtQml.WorkerScript
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string query: ""
    property int selectedIndex: 0
    property int requestSerial: 0
    property int pendingQalcSerial: 0
    property string pendingQalcQuery: ""
    property var results: []
    property string calculation: ""
    property bool calculationSelected: false
    property bool dmenuMode: false
    property string dmenuPrompt: ""
    property var dmenuOptions: []
    property bool dmenuInsensitive: false
    property int dmenuLimit: 0
    property bool dmenuBottom: false
    property var pendingEntry: null
    property var themes: []
    property bool themesLoading: false
    property string themesError: ""
    property var themeSearchRecords: []
    property bool themeSearchWorkerInitialised: false
    property int themeSearchRequest: 0
    property bool applyingTheme: false
    property string applyingThemeId: ""
    property string applyingThemeName: ""
    property string applyError: ""
    property var applyProgressStages: []
    property var applyProgressRows: []
    property real applyProgressValue: 0
    property string applyProgressMessage: "Preparing theme application"
    property bool applyProgressShowTargets: false
    property bool applyProgressComplete: false
    property bool applyQuickshellReloadPending: false
    property string applyGuideTarget: ""
    property string retryingTarget: ""
    property bool applyWindowOpen: false
    property var resolvedIconPaths: ({
    })
    property bool iconResolveQueued: false
    readonly property var applicationCategories: [{
        "title": "Audio & Video",
        "key": "AudioVideo",
        "icon": "film-strip"
    }, {
        "title": "Development",
        "key": "Development",
        "icon": "code"
    }, {
        "title": "Education",
        "key": "Education",
        "icon": "graduation-cap"
    }, {
        "title": "Games",
        "key": "Game",
        "icon": "game-controller"
    }, {
        "title": "Graphics",
        "key": "Graphics",
        "icon": "palette"
    }, {
        "title": "Network",
        "key": "Network",
        "icon": "globe-hemisphere-west"
    }, {
        "title": "Office",
        "key": "Office",
        "icon": "briefcase"
    }, {
        "title": "Science",
        "key": "Science",
        "icon": "flask"
    }, {
        "title": "Settings",
        "key": "Settings",
        "icon": "gear-six"
    }, {
        "title": "System",
        "key": "System",
        "icon": "terminal-window"
    }, {
        "title": "Utilities",
        "key": "Utility",
        "icon": "wrench"
    }]

    signal closeRequested()
    signal dmenuSelected(string value)
    signal themeApplyStarted()

    function normaliseId(value) {
        return LauncherLogic.normaliseId(value);
    }

    function looksLikeCalculation(value) {
        return LauncherLogic.looksLikeCalculation(value);
    }

    function qalcQuery(value) {
        return LauncherLogic.qalcQuery(value);
    }

    function categoryResults(applications) {
        return applicationCategories.map((category) => {
            const count = applications.filter((entry) => {
                return (entry.categories || []).some((value) => {
                    return String(value).toLowerCase() === category.key.toLowerCase();
                });
            }).length;
            return {
                "kind": "category",
                "title": category.title,
                "subtitle": count + (count === 1 ? " application" : " applications"),
                "iconName": category.icon,
                "categoryKey": category.key,
                "score": 0
            };
        });
    }

    function themeAction() {
        return {
            "kind": "theme-action",
            "title": "Change theme",
            "subtitle": themes.length + (themes.length === 1 ? " theme" : " themes"),
            "iconName": "palette",
            "score": 0
        };
    }

    function themeResults(indices) {
        const selected = indices || themes.map((entry, index) => {
            return index;
        });
        return selected.map((index) => {
            const entry = themes[index];
            return {
                "kind": "theme",
                "title": entry.name,
                "subtitle": entry.id,
                "score": 0,
                "theme": entry
            };
        });
    }

    function requestThemeSearch() {
        const needle = query.startsWith("%") ? query.slice(1).trim().toLowerCase() : "";
        if (!needle.length || !themeSearchWorkerInitialised)
            return ;

        const request = ++themeSearchRequest;
        themeSearchWorker.sendMessage({
            "type": "search",
            "request": request,
            "query": needle
        });
    }

    function initialiseThemeSearchWorker() {
        if (!themeSearchWorker.ready || themeSearchWorkerInitialised || !themeSearchRecords.length)
            return ;

        themeSearchWorker.sendMessage({
            "type": "initialise",
            "records": themeSearchRecords
        });
        themeSearchWorkerInitialised = true;
        themeSearchRecords = [];
        if (query.startsWith("%") && query.slice(1).trim().length)
            requestThemeSearch();

    }

    function previewColour(entry, key, fallback) {
        const colours = entry && entry.preview ? entry.preview.colours || ({
        }) : ({
        });
        const value = String(colours[key] || "");
        return /^#[0-9a-fA-F]{6}$/.test(value) ? value : fallback;
    }

    function previewBarPosition(entry) {
        const position = String(entry && entry.preview && entry.preview.bar ? entry.preview.bar.position || "left" : "left");
        return ["left", "right", "top", "bottom"].indexOf(position) >= 0 ? position : "left";
    }

    function previewBarCount(entry, region) {
        const items = entry && entry.preview && entry.preview.bar && entry.preview.bar.items && entry.preview.bar.items.length !== undefined ? entry.preview.bar.items : [];
        let count = 0;
        for (let index = 0; index < items.length; index++) {
            const item = items[index];
            if (item && item.enabled !== false && item.region === region)
                count++;

        }
        return count;
    }

    function previewWidgetCount(entry) {
        const count = entry && entry.preview ? Number(entry.preview.widget_count) : 0;
        return isNaN(count) ? 0 : count;
    }

    function localFileUrl(path) {
        const value = String(path || "");
        if (!value.length || value.startsWith("file:"))
            return value;

        return "file://" + value;
    }

    function loadThemes() {
        if (themesLoading || themeListProcess.running)
            return ;

        themesLoading = true;
        themesError = "";
        themeListProcess.command = [Quickshell.shellDir + "/scripts/theme/themectl.sh", "list", "--json"];
        themeListProcess.running = true;
    }

    function applyTheme(entry) {
        if (applyingTheme || !entry || !entry.id)
            return ;

        applyingTheme = true;
        applyingThemeId = entry.id;
        applyingThemeName = entry.name || entry.id;
        applyError = "";
        retryingTarget = "";
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
        applyProgressRows = [];
        applyProgressValue = 0;
        applyProgressMessage = "Checking theme and dependencies";
        applyProgressShowTargets = false;
        applyProgressComplete = false;
        applyQuickshellReloadPending = false;
        applyGuideTarget = "";
        applyWindowOpen = true;
        themeApplyProcess.cancelling = false;
        themeApplyProcess.command = [Quickshell.shellDir + "/scripts/theme/themectl.sh", "apply", entry.id, "--defer-quickshell-restart", "--json", "--progress-ndjson"];
        themeApplyProcess.running = true;
        themeApplyStarted();
    }

    function dismissThemeApply() {
        applyWindowOpen = false;
        applyGuideTarget = "";
        if (themeApplyProcess.running) {
            themeApplyProcess.cancelling = true;
            themeApplyProcess.signal(15);
        }
        applyingTheme = false;
        applyProgressComplete = false;
        applyQuickshellReloadPending = false;
        retryingTarget = "";
    }

    function completeThemeApply() {
        if (!applyProgressComplete)
            return ;

        const reloadQuickshell = applyQuickshellReloadPending;
        applyQuickshellReloadPending = false;
        applyWindowOpen = false;
        applyGuideTarget = "";
        applyProgressComplete = false;
        retryingTarget = "";
        if (reloadQuickshell)
            Qt.callLater(() => Theme.reloadCursor());
    }

    function retryThemeTarget(target) {
        if (applyingTheme || !applyingThemeId.length)
            return ;

        retryingTarget = target;
        applyingTheme = true;
        applyWindowOpen = true;
        applyProgressComplete = false;
        applyProgressMessage = "Retrying " + target.replace("cursor_editor", "cursor");
        applyProgressRows = applyProgressRows.map((row) => {
            return row.target === target ? Object.assign({
            }, row, {
                "state": "active",
                "message": "Retrying…"
            }) : row;
        });
        themeApplyProcess.command = [Quickshell.shellDir + "/scripts/theme/themectl.sh", "apply", applyingThemeId, "--targets", target, "--defer-quickshell-restart", "--json", "--progress-ndjson"];
        themeApplyProcess.running = true;
    }

    function handleApplyProgress(event) {
        if (!event || event.type !== "theme-progress")
            return ;

        applyProgressValue = event.total > 0 ? Number(event.completed || 0) / Number(event.total) : applyProgressValue;
        applyProgressMessage = event.message || applyProgressMessage;
        if (Array.isArray(event.pending_reloads) && event.pending_reloads.indexOf("quickshell") >= 0)
            applyQuickshellReloadPending = true;
        if (event.targets && !retryingTarget.length)
            applyProgressRows = event.targets.map((target) => {
            return ({
                "target": target,
                "state": "queued",
                "message": "Queued"
            });
        });

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

    function usageBoost(entry) {
        const key = normaliseId(entry.id || entry.name);
        const usage = LauncherState.applicationUsage[key] || ({
        });
        const countBoost = Math.min(15, Math.log2(Number(usage.count || 0) + 1) * 4);
        const age = Date.now() - Number(usage.lastUsed || 0);
        const recencyBoost = age >= 0 && age < 7 * 8.64e+07 ? 10 * (1 - age / (7 * 8.64e+07)) : 0;
        return countBoost + recencyBoost;
    }

    function recordUse(entry) {
        const key = normaliseId(entry.id || entry.name);
        const usage = Object.assign({
        }, LauncherState.applicationUsage);
        const previous = usage[key] || ({
        });
        usage[key] = {
            "count": Number(previous.count || 0) + 1,
            "lastUsed": Date.now()
        };
        LauncherState.applicationUsage = usage;
    }

    function iconSource(entry) {
        const icon = String(entry.icon || "");
        if (!icon.length)
            return "";

        if (icon.startsWith("/"))
            return "file://" + icon;

        const themed = Quickshell.iconPath(icon, true);
        const resolved = String(resolvedIconPaths[icon] || "");
        return themed.length ? themed : resolved.length ? "file://" + resolved : "";
    }

    function resolveApplicationIcons() {
        if (iconResolver.running) {
            iconResolveQueued = true;
            return ;
        }
        const missing = [];
        const seen = ({
        });
        for (const entry of DesktopEntries.applications.values || []) {
            const icon = String(entry.icon || "");
            if (!icon.length || icon.startsWith("/") || seen[icon] || Quickshell.iconPath(icon, true).length)
                continue;

            seen[icon] = true;
            missing.push(icon);
        }
        if (!missing.length)
            return ;

        iconResolver.command = ["python3", Quickshell.shellDir + "/scripts/launcher/icon_lookup.py"].concat(missing);
        iconResolver.running = true;
    }

    function executeCurrentDesktopEntry(entry) {
        const desktopId = String(entry.id || "").replace(/\.desktop$/, "");
        if (desktopId.length) {
            // DesktopEntries can retain an old Exec value after its source
            // file changes. Resolve the desktop file again at activation time,
            // so launcher clicks always use its current Exec.
            desktopLauncher.command = [Quickshell.shellDir + "/scripts/launcher/desktop_exec.py", desktopId];
            desktopLauncher.running = true;
        } else {
            entry.execute();
        }
    }

    function refresh() {
        const text = query.trim();
        requestSerial++;
        pendingQalcSerial = 0;
        pendingQalcQuery = "";
        qalcDebounce.stop();
        if (qalc.running)
            qalc.signal(15);

        selectedIndex = 0;
        calculation = "";
        calculationSelected = false;
        if (!query.length && !dmenuMode) {
            results = [];
            return ;
        }
        if (dmenuMode) {
            const matched = dmenuOptions.map((option) => {
                return {
                    "kind": "dmenu",
                    "title": option,
                    "subtitle": "",
                    "icon": "",
                    "score": text.length ? Fuzzy.score(text, option, dmenuInsensitive) : 0
                };
            }).filter((result) => {
                return result.score >= 0;
            });
            matched.sort((left, right) => {
                return right.score - left.score;
            });
            results = matched.slice(0, 100);
            return ;
        }
        if (query.startsWith("%")) {
            if (!themes.length && !themesLoading && !themesError.length)
                loadThemes();

            const needle = query.slice(1).trim();
            if (!themes.length) {
                results = [];
            } else if (!needle.length) {
                themeSearchTimer.stop();
                themeSearchRequest++;
                results = themeResults();
            } else {
                themeSearchTimer.restart();
            }
            return ;
        }
        themeSearchTimer.stop();
        themeSearchRequest++;
        const applications = DesktopEntries.applications.values || [];
        if (query === "$") {
            results = categoryResults(applications);
            return ;
        }
        const categoryMatch = query.match(/^\$([^\s]+)$/);
        const categoryKey = categoryMatch ? categoryMatch[1].toLowerCase() : "";
        const scored = [];
        const action = themeAction();
        const actionScore = categoryKey === "settings" ? 0 : categoryKey ? -1 : Fuzzy.score(text, "Change theme switch appearance colours wallpaper settings");
        if (actionScore >= 0) {
            action.score = actionScore;
            scored.push(action);
        }
        for (const entry of applications) {
            if (categoryKey && !(entry.categories || []).some((category) => {
                return String(category).toLowerCase() === categoryKey;
            }))
                continue;

            const tokens = [entry.name, entry.genericName, entry.comment, entry.keywords, entry.id].join(" ");
            const value = categoryKey ? 0 : text.length ? Fuzzy.score(text, tokens) : 0;
            if (value >= 0)
                scored.push({
                "kind": entry.runInTerminal ? "command" : "app",
                "title": entry.name,
                "subtitle": entry.comment || entry.id,
                "icon": iconSource(entry),
                "score": value + (text.length ? usageBoost(entry) : 0),
                "entry": entry
            });

        }
        scored.sort((left, right) => {
            return text.length ? right.score - left.score : left.title.localeCompare(right.title);
        });
        results = text.length ? scored : categoryResults(applications).concat(scored);
        if (looksLikeCalculation(text))
            qalcDebounce.restart();

    }

    function move(delta) {
        if (calculation.length) {
            if (calculationSelected) {
                if (results.length) {
                    calculationSelected = false;
                    selectedIndex = delta < 0 ? results.length - 1 : 0;
                }
                return ;
            }
            const next = selectedIndex + delta;
            if (next < 0 || next >= results.length) {
                calculationSelected = true;
                return ;
            }
            selectedIndex = next;
            return ;
        }
        if (results.length)
            selectedIndex = (selectedIndex + delta + results.length) % results.length;

    }

    function activateCalculation() {
        if (!calculation.length)
            return ;

        copyResult.command = ["wl-copy", calculation];
        copyResult.running = true;
        closeRequested();
    }

    function activateResult(index) {
        calculationSelected = false;
        const result = results[index === undefined ? selectedIndex : index];
        if (!result)
            return ;

        if (result.kind === "category") {
            query = "$" + result.categoryKey;
            return ;
        }
        if (result.kind === "theme-action") {
            query = "%";
            return ;
        }
        if (result.kind === "theme") {
            applyTheme(result.theme);
            return ;
        }
        if (result.kind === "command") {
            recordUse(result.entry);
            const command = ["kitty", "--detach"];
            if (result.entry.workingDirectory)
                command.push("--directory", result.entry.workingDirectory);

            for (const part of result.entry.command) command.push(part)
            terminalCommand.command = command;
            terminalCommand.running = true;
        } else if (result.kind === "app") {
            recordUse(result.entry);
            pendingEntry = result.entry;
            focusApp.command = [Quickshell.shellDir + "/scripts/launcher/appctl.py", result.entry.id || "", result.entry.startupClass || ""];
            focusApp.running = true;
        } else {
            dmenuSelected(result.title);
        }
        closeRequested();
    }

    function activate() {
        if (calculation.length && calculationSelected)
            activateCalculation();
        else
            activateResult(selectedIndex);
    }

    function startPendingQalc() {
        if (qalc.running || pendingQalcSerial !== requestSerial || !pendingQalcQuery.length)
            return ;

        qalc.serial = pendingQalcSerial;
        qalc.command = ["qalc", "-t", "-m", "1200", pendingQalcQuery];
        pendingQalcSerial = 0;
        pendingQalcQuery = "";
        qalc.running = true;
    }

    onQueryChanged: {
        if (!query.startsWith("%")) {
            applyError = "";
            applyProgressComplete = false;
            applyGuideTarget = "";
        }
        refresh();
    }
    Component.onCompleted: {
        loadThemes();
        iconResolveDebounce.start();
    }

    Connections {
        function onApplicationsChanged() {
            root.refresh();
            iconResolveDebounce.restart();
        }

        target: DesktopEntries
    }

    Timer {
        id: iconResolveDebounce

        // Package installs can write the desktop entry before its icon.
        interval: 1000
        onTriggered: root.resolveApplicationIcons()
    }

    Timer {
        id: qalcDebounce

        interval: 175
        repeat: false
        onTriggered: {
            root.pendingQalcSerial = root.requestSerial;
            root.pendingQalcQuery = root.qalcQuery(root.query);
            if (qalc.running)
                qalc.signal(15);
            else
                root.startPendingQalc();
        }
    }

    Process {
        id: qalc

        property int serial: 0
        property string output: ""

        onRunningChanged: {
            if (running)
                output = "";

        }
        onExited: (exitCode) => {
            if (exitCode === 0 && qalc.serial === root.requestSerial && qalc.output.length) {
                root.calculation = qalc.output;
                root.calculationSelected = true;
            }
            if (root.pendingQalcSerial === root.requestSerial)
                Qt.callLater(root.startPendingQalc);

        }

        stdout: StdioCollector {
            onStreamFinished: {
                qalc.output = text.trim();
            }
        }

    }

    Process {
        id: copyResult
    }

    Process {
        id: iconResolver

        property string output: ""

        onRunningChanged: {
            if (running)
                output = "";

        }
        onExited: (exitCode) => {
            if (exitCode === 0 && output.length) {
                try {
                    root.resolvedIconPaths = Object.assign({
                    }, root.resolvedIconPaths, JSON.parse(output));
                } catch (error) {
                    console.warn("Could not read resolved launcher icons:", error);
                }
                root.refresh();
            }
            if (root.iconResolveQueued) {
                root.iconResolveQueued = false;
                Qt.callLater(root.resolveApplicationIcons);
            }
        }

        stdout: StdioCollector {
            onStreamFinished: iconResolver.output = text.trim()
        }

    }

    Process {
        id: focusApp

        onExited: (exitCode) => {
            if (exitCode === 3 && root.pendingEntry)
                root.executeCurrentDesktopEntry(root.pendingEntry);

            root.pendingEntry = null;
        }
    }

    Process {
        id: terminalCommand
    }

    Process {
        id: desktopLauncher
    }

    Process {
        id: themeListProcess

        property string output: ""

        onRunningChanged: {
            if (running)
                output = "";

        }
        onExited: (exitCode) => {
            root.themesLoading = false;
            try {
                const response = JSON.parse(output);
                if (exitCode === 0 && Array.isArray(response.data)) {
                    root.themes = response.data;
                    root.themeSearchRecords = response.data.map((entry, index) => {
                        return {
                            "index": index,
                            "name": String(entry.name || entry.id || ""),
                            "searchText": [entry.name, entry.id].join(" ").toLowerCase()
                        };
                    });
                    root.themeSearchWorkerInitialised = false;
                    root.initialiseThemeSearchWorker();
                    root.themesError = "";
                } else {
                    root.themesError = response.errors && response.errors.length ? response.errors.join("\n") : "Could not load themes";
                }
            } catch (error) {
                root.themesError = "Could not read the theme list";
            }
            root.refresh();
        }

        stdout: StdioCollector {
            onStreamFinished: themeListProcess.output = text
        }

    }

    Process {
        id: themeApplyProcess

        property string output: ""
        property bool cancelling: false

        onRunningChanged: {
            if (running)
                output = "";

        }
        onExited: (exitCode) => {
            if (cancelling) {
                cancelling = false;
                output = "";
                return ;
            }
            root.applyingTheme = false;
            try {
                const response = JSON.parse(output);
                if ((exitCode === 0 || exitCode === 10) && response.data && response.data.theme_id) {
                    Theme.reload();
                    applyQuickshellReloadPending = Array.isArray(response.data.pending_reloads) && response.data.pending_reloads.indexOf("quickshell") >= 0;
                    root.applyProgressValue = 1;
                    root.applyProgressComplete = true;
                    root.applyProgressMessage = "Application finished · Review follow-up actions";
                    root.retryingTarget = "";
                    return ;
                }
                root.applyError = response.errors && response.errors.length ? response.errors.join("\n") : "Could not apply theme";
            } catch (error) {
                root.applyError = "Could not read the apply result";
            }
            root.applyProgressComplete = true;
        }

        stdout: StdioCollector {
            onStreamFinished: themeApplyProcess.output = text
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: (line) => {
                try {
                    root.handleApplyProgress(JSON.parse(line));
                } catch (error) {
                }
            }
        }

    }

    Timer {
        id: themeSearchTimer

        interval: 45
        repeat: false
        onTriggered: root.requestThemeSearch()
    }

    WorkerScript {
        id: themeSearchWorker

        source: "ThemeSearchWorker.mjs"
        onReadyChanged: root.initialiseThemeSearchWorker()
        onMessage: (message) => {
            const needle = root.query.startsWith("%") ? root.query.slice(1).trim().toLowerCase() : "";
            if (message.type !== "results" || message.request !== root.themeSearchRequest || message.query !== needle)
                return ;

            root.results = root.themeResults(message.indices);
            root.selectedIndex = 0;
        }
    }

}
