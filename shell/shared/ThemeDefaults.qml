import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    property var document: null
    property bool ready: false
    property string error: ""
    readonly property string path: {
        const configured = Quickshell.env("BLOX_DATA_DIR") || "";
        if (configured.length > 0)
            return configured + "/defaults/v1.json";
        // Installed layout: <root>/shell and <root>/themes are siblings.
        const installed = Quickshell.shellDir + "/../themes/defaults/v1.json";
        if (Quickshell.env("BLOX_SHELL_LAYOUT") === "installed")
            return installed;
        // Source checkout: the themes tree sits four levels above the shell.
        return Quickshell.shellDir + "/../../../../themes/defaults/v1.json";
    }

    signal loaded()
    signal failed(string reason)

    function clone(value) {
        return JSON.parse(JSON.stringify(value));
    }

    function parse(raw) {
        try {
            const data = JSON.parse(raw);
            if (data.schema_version !== 1 || data.defaults_version !== 1 || !data.theme || !data.widgets)
                throw new Error("unsupported or incomplete defaults document");

            if (!data.theme.colours || !data.theme.fonts || !data.theme.shell || !data.theme.wallpaper)
                throw new Error("defaults document has incomplete theme values");

            if (!data.theme.shell.bar || !Array.isArray(data.theme.shell.bar.items) || !Array.isArray(data.theme.shell.bar.reset_items))
                throw new Error("defaults document has incomplete bar values");

            if (!data.widgets.profile || !data.widgets.profiles)
                throw new Error("defaults document has incomplete widget values");

            document = data;
            error = "";
            ready = true;
            loaded();
            return true;
        } catch (parseError) {
            document = null;
            ready = false;
            error = String(parseError);
            console.error("[blox.theme] rejected defaults document: " + error);
            failed(error);
            return false;
        }
    }

    function themeDocument() {
        return ready && document && document.theme ? document.theme : ({ });
    }

    function colour(key) {
        return themeDocument().colours && themeDocument().colours[key] ? themeDocument().colours[key] : "transparent";
    }

    function font(key) {
        return themeDocument().fonts && themeDocument().fonts[key] ? themeDocument().fonts[key] : "";
    }

    function defaultBarItems() {
        return ready ? clone(themeDocument().shell.bar.items) : [];
    }

    function resetBarItems() {
        return ready ? clone(themeDocument().shell.bar.reset_items) : [];
    }

    function defaultWidgetItems() {
        return [];
    }

    function widgetProfile(profile) {
        const name = profile || (ready ? document.widgets.profile : "");
        return ready && document.widgets.profiles[name] ? clone(document.widgets.profiles[name]) : null;
    }

    function resolvedBarItems(overrides) {
        if (!ready)
            return [];

        const items = defaultBarItems();
        const byId = { };
        for (let index = 0; index < (overrides || []).length; index++)
            byId[overrides[index].id] = overrides[index];

        if (byId["tray"] && !byId["application-tray"]) {
            byId["application-tray"] = Object.assign({ }, byId["tray"], {
                "id": "application-tray"
            });
            byId["tray"] = null;
        }

        for (let index = 0; index < items.length; index++) {
            const override = byId[items[index].id];
            if (override)
                items[index] = Object.assign({ }, items[index], override);
        }

        const tray = items.find((item) => item.id === "tray");
        const applicationTray = items.find((item) => item.id === "application-tray");
        if (!tray || !applicationTray)
            return [];

        if (tray.region === "hidden")
            tray.region = "end";

        const visible = items.filter((item) => item.region === tray.region).sort((left, right) => left.order - right.order);
        const trayIndex = visible.indexOf(tray);
        visible.splice(trayIndex, 1);
        if (tray.region === "start")
            visible.push(tray);
        else if (tray.region === "end" || trayIndex < (visible.length + 1) / 2)
            visible.unshift(tray);
        else
            visible.push(tray);
        for (let index = 0; index < visible.length; ++index)
            visible[index].order = index;

        applicationTray.region = "hidden";
        const hidden = items.filter((item) => item.region === "hidden" && item.id !== "application-tray").sort((left, right) => left.order - right.order);
        if (trayOpensForward(items))
            hidden.push(applicationTray);
        else
            hidden.unshift(applicationTray);
        for (let index = 0; index < hidden.length; index++)
            hidden[index].order = index;
        return items;
    }

    function trayOpensForward(items) {
        const tray = (items || []).find((item) => item.id === "tray");
        if (!tray || tray.region === "end")
            return false;
        if (tray.region === "start")
            return true;
        if (tray.region !== "centre")
            return false;
        const centre = (items || []).filter((item) => item.region === "centre").sort((left, right) => left.order - right.order);
        return centre.length > 0 && centre[centre.length - 1].id === "tray";
    }

    function barItemsForRegion(items, region) {
        return (items || []).filter((item) => item.enabled && item.region === region).sort((left, right) => left.order - right.order);
    }

    property FileView defaultsFile: FileView {
        path: root.path
        preload: true
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.parse(text())
        onFileChanged: root.parse(text())
    }
}
