import qs.shared
import qs.services
import "../shared/Fuzzy.js" as Fuzzy
import "../shared/LauncherLogic.js" as LauncherLogic
import QtQml.WorkerScript
import QtQuick
import Quickshell
import Quickshell.Hyprland
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
    property var launchQueue: []
    property var activeLaunch: null
    property var workspaceTransfers: []
    property int launchSerial: 0
    property var themes: []
    property bool themesLoading: false
    property string themesError: ""
    property var themeSearchRecords: []
    property bool themeSearchWorkerInitialised: false
    property int themeSearchRequest: 0
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
    signal dismissRequested()
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
        if (SettingsApplyController.busy || !entry || !entry.id) return;
        SettingsApplyController.quickApply(entry);
        themeApplyStarted();
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

    function newLaunchId() {
        launchSerial++;
        return Date.now().toString(16) + "-" + launchSerial.toString(16) + "-" + Math.floor(Math.random() * 4294967296).toString(16);
    }

    function createLaunchRequest(entry, kind) {
        const workspaceValue = Hyprland.focusedWorkspace ? Number(Hyprland.focusedWorkspace.id) : 0;
        const workspaceId = Number.isInteger(workspaceValue) && workspaceValue > 0 && workspaceValue <= 2147483647 ? workspaceValue : 0;
        const request = {
            "entry": entry,
            "kind": kind,
            "desktopId": String(entry.id || "").replace(/\.desktop$/, ""),
            "startupClass": String(entry.startupClass || ""),
            "workspaceId": workspaceId,
            "launchId": newLaunchId()
        };
        return request;
    }

    function enqueueLaunch(entry, kind) {
        launchQueue = launchQueue.concat([createLaunchRequest(entry, kind)]);
        processLaunchQueue();
    }

    function processLaunchQueue() {
        if (activeLaunch || focusApp.running || desktopLauncher.running || terminalCommand.running || !launchQueue.length)
            return ;

        const request = launchQueue[0];
        launchQueue = launchQueue.slice(1);
        activeLaunch = request;
        if (request.workspaceId > 0) {
            workspaceTransfers = workspaceTransfers.concat([{
                "launchId": request.launchId,
                "workspaceId": request.workspaceId,
                "desktopId": request.desktopId,
                "startupClass": request.startupClass,
                "existingAddresses": (Hyprland.toplevels && Hyprland.toplevels.values || []).map(item => String((item.lastIpcObject || {}).address || "")),
                "startedAt": Date.now(),
                "expiresAt": Date.now() + 300000
            }]);
        }
        if (request.kind === "terminal") {
            const command = [
                "python3",
                Quickshell.shellDir + "/scripts/launcher/command_exec.py",
                String(request.workspaceId),
                request.launchId,
                String(request.entry.workingDirectory || "")
            ].concat(request.entry.command || []);
            terminalCommand.launchContext = request;
            terminalCommand.command = command;
            terminalCommand.running = true;
            return ;
        }

        focusApp.launchContext = request;
        focusApp.command = [
            Quickshell.shellDir + "/scripts/launcher/appctl.py",
            request.desktopId,
            request.startupClass
        ];
        focusApp.running = true;
    }

    function executeCurrentDesktopEntry(request) {
        if (!request) {
            finishActiveLaunch(false);
            return ;
        }
        if (!request.desktopId.length) {
            if (request.entry && request.entry.execute)
                request.entry.execute();
            finishActiveLaunch(false);
            return ;
        }

        // Resolve the desktop entry again so activation uses its current Exec value.
        desktopLauncher.launchContext = request;
        desktopLauncher.command = [
            Quickshell.shellDir + "/scripts/launcher/desktop_exec.py",
            request.desktopId,
            String(request.workspaceId),
            request.launchId
        ];
        desktopLauncher.running = true;
    }

    function removeWorkspaceTransfer(launchId) {
        Quickshell.execDetached(["python3", Quickshell.shellDir + "/scripts/launcher/assign_workspace.py", "--release", launchId]);
        workspaceTransfers = workspaceTransfers.filter((item) => item.launchId !== launchId);
    }

    function finishActiveLaunch(keepWorkspaceTransfer) {
        if (activeLaunch && !keepWorkspaceTransfer)
            removeWorkspaceTransfer(activeLaunch.launchId);
        activeLaunch = null;
        processLaunchQueue();
    }

    function expireWorkspaceTransfers() {
        const now = Date.now();
        for (const item of workspaceTransfers.filter(item => item.expiresAt <= now))
            removeWorkspaceTransfer(item.launchId);
    }

    function handleHyprlandEvent(event) {
        if (!event)
            return ;

        if (event.name === "custom" && String(event.data || "").startsWith("blox_launch_workspace_assigned>>")) {
            const launchId = String(event.data).slice("blox_launch_workspace_assigned>>".length);
            // Splash screens and later main windows belong to the same startup.
            // Keep a short quiet period, bounded by the original launch deadline.
            workspaceTransfers = workspaceTransfers.map(item => item.launchId === launchId
                ? Object.assign({}, item, {expiresAt: Math.min(item.startedAt + 300000, Date.now() + 15000)}) : item);
            return ;
        }
        expireWorkspaceTransfers();
        if (event.name !== "openwindow" || !workspaceTransfers.length)
            return ;

        let address = String(event.data || "").split(",")[0].trim();
        if (/^[0-9a-fA-F]+$/.test(address))
            address = "0x" + address;
        if (!/^0x[0-9a-fA-F]+$/.test(address))
            return ;

        const contexts = workspaceTransfers.map((item) => {
            return {"launchId": item.launchId, "workspaceId": item.workspaceId,
                "desktopId": item.desktopId, "startupClass": item.startupClass,
                "existingAddresses": item.existingAddresses};
        });
        Quickshell.execDetached([
            "python3",
            Quickshell.shellDir + "/scripts/launcher/assign_workspace.py",
            address,
            JSON.stringify(contexts)
        ]);
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
            enqueueLaunch(result.entry, "terminal");
        } else if (result.kind === "app") {
            recordUse(result.entry);
            enqueueLaunch(result.entry, "application");
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

        property var launchContext: null

        onExited: (exitCode) => {
            const request = launchContext;
            launchContext = null;
            if (exitCode === 3 && request)
                root.executeCurrentDesktopEntry(request);
            else
                root.finishActiveLaunch(false);
        }
    }

    Process {
        id: terminalCommand

        property var launchContext: null

        onExited: (exitCode) => {
            const request = launchContext;
            launchContext = null;
            root.finishActiveLaunch(exitCode === 0 && !!request);
        }
    }

    Process {
        id: desktopLauncher

        property var launchContext: null

        onExited: (exitCode) => {
            const request = launchContext;
            launchContext = null;
            root.finishActiveLaunch(exitCode === 0 && !!request);
        }
    }

    Connections {
        function onRawEvent(event) {
            root.handleHyprlandEvent(event);
        }

        target: Hyprland
    }

    Timer {
        interval: 10000
        repeat: true
        running: true
        onTriggered: root.expireWorkspaceTransfers()
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
                    const validThemes = response.data.filter((entry) => {
                        return entry && !entry.invalid && typeof entry.id === "string" && entry.id.length > 0;
                    });
                    root.themes = validThemes;
                    root.themeSearchRecords = validThemes.map((entry, index) => {
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
