import QtQuick
import Quickshell
import Quickshell.Io
import "Shape.js" as Shape
pragma Singleton

Singleton {
    id: root

    property bool ready: false
    property string themeId: ""
    property string activeThemeId: ""
    property string previewThemeId: ""
    property string variant: ""
    property color background: defaults.colour("background")
    property color surface: defaults.colour("surface")
    property color surfaceAlt: defaults.colour("surface_alt")
    property color foreground: defaults.colour("foreground")
    property color muted: defaults.colour("muted")
    property color red: defaults.colour("red")
    property color green: defaults.colour("green")
    property color yellow: defaults.colour("yellow")
    property color accent: defaults.colour("accent")
    property color blue: defaults.colour("blue")
    property color mauve: defaults.colour("mauve")
    property color teal: defaults.colour("teal")
    property color selectionForeground: defaults.colour("selection_foreground")
    property color border: defaults.colour("border")
    property color terminalCanvas: defaults.ready ? defaults.themeDocument().terminal.canvas : "transparent"
    property real radiusScale: defaults.ready ? defaults.themeDocument().shape.radius_scale : 1.25
    property real densityScale: defaults.ready ? defaults.themeDocument().shape.density_scale : 1.0
    property var windowGap: defaults.ready && defaults.themeDocument().shape.window_gap !== undefined ? defaults.themeDocument().shape.window_gap : null
    readonly property int railWidth: 34
    readonly property int iconSize: 18
    readonly property int buttonSize: 30
    readonly property int radius: Shape.roundScaled(4, radiusScale)
    readonly property int cardRadius: Shape.roundScaled(8, radiusScale)
    readonly property int popoutRadius: Shape.roundScaled(12, radiusScale)
    readonly property int surfacePadding: Shape.roundScaled(12, densityScale)
    readonly property int controlSpacing: Shape.roundScaled(8, densityScale)
    readonly property int effectiveWindowGap: windowGap === null ? Shape.automaticWindowGap(densityScale) : windowGap
    property string fontFamily: defaults.font("panel")
    property string monoFontFamily: defaults.font("mono")
    property string bodyFontFamily: defaults.font("ui")
    property bool previewActive: false
    property string widgetProfile: defaults.ready ? defaults.document.widgets.profile : ""
    property real widgetOpacity: defaults.ready && defaults.widgetProfile(widgetProfile) ? defaults.widgetProfile(widgetProfile).opacity : 0
    property int widgetBasePadding: defaults.ready && defaults.widgetProfile(widgetProfile) ? defaults.widgetProfile(widgetProfile).padding : 0
    property int widgetBaseRadius: defaults.ready && defaults.widgetProfile(widgetProfile) ? defaults.widgetProfile(widgetProfile).radius : 0
    readonly property int widgetPadding: Shape.roundScaled(widgetBasePadding, densityScale)
    readonly property int widgetRadius: Shape.roundScaled(widgetBaseRadius, radiusScale)
    property int widgetFontSize: defaults.ready && defaults.widgetProfile(widgetProfile) ? defaults.widgetProfile(widgetProfile).font_size : 0
    property var widgetItems: []
    property string barPosition: defaults.ready ? defaults.themeDocument().shell.bar.position : ""
    property var barItems: []
    readonly property var barStartItems: barItemsForRegion("start")
    readonly property var barCentreItems: barItemsForRegion("centre")
    readonly property var barEndItems: barItemsForRegion("end")
    readonly property var barHiddenItems: barItemsForRegion("hidden")
    property string osdPosition: defaults.ready ? defaults.themeDocument().shell.osd.position : ""
    property int osdOffsetX: 0
    property int osdOffsetY: 0
    property string notificationPosition: defaults.ready ? defaults.themeDocument().shell.notifications.position : ""
    property int notificationOffsetX: 0
    property int notificationOffsetY: 0
    readonly property string stateRoot: {
        const configured = Quickshell.env("XDG_STATE_HOME") || "";
        return configured.length > 0 ? configured : Quickshell.env("HOME") + "/.local/state";
    }

    function scaledRadius(base) {
        return Shape.roundScaled(base, radiusScale);
    }

    function scaledSpacing(base) {
        return Shape.roundScaled(base, densityScale);
    }
    readonly property string themePath: stateRoot + "/blox-theme/current/quickshell/theme.json"
    readonly property string widgetPath: stateRoot + "/blox-theme/current/widgets/profile.json"
    readonly property string wallpaperPath: stateRoot + "/blox-theme/current/hypr/wallpaper.json"
    property string activeWallpaperSource: defaults.ready ? wallpaperUrl(defaults.themeDocument().wallpaper.path) : ""
    property string activeWallpaperFit: defaults.ready ? defaults.themeDocument().wallpaper.fit : ""
    property string wallpaperSource: activeWallpaperSource
    property string wallpaperFit: activeWallpaperFit

    signal osdPositionPreviewRequested()
    signal notificationPositionPreviewRequested()
    signal widgetEditModeRequested()
    signal widgetEditModeCancelRequested()
    signal widgetEditModeFinished(string widgetsJson, string returnWorkspace)

    function withAlpha(colour, opacity) : color {
        return Qt.rgba(colour.r, colour.g, colour.b, opacity);
    }

    function reset() : string {
        return document.reset();
    }

    function resetWidgets() : string {
        return document.resetWidgets();
    }

    function loadWidgets(raw) : bool {
        return document.loadWidgets(raw);
    }

    function defaultWidgetItems() {
        return defaults.defaultWidgetItems();
    }

    function loadJson(raw) : bool {
        return document.loadJson(raw);
    }

    function loadWidgetSource(profile) : bool {
        return document.loadWidgetSource(profile);
    }

    function loadShell(shell) : bool {
        return document.loadShell(shell);
    }

    function defaultBarItems() {
        return defaults.defaultBarItems();
    }

    function builtinBarItems() {
        return defaults.resolvedBarItems(defaults.resetBarItems());
    }

    function trayOpensForward(items) : bool {
        return defaults.trayOpensForward(items);
    }

    function resolvedBarItems(overrides, position) {
        return defaults.resolvedBarItems(overrides);
    }

    function barItemsForRegion(region) {
        return defaults.barItemsForRegion(barItems, region);
    }

    function loadActiveIdentity(raw) : bool {
        return document.loadActiveIdentity(raw);
    }

    function wallpaperUrl(path) : string {
        const value = String(path || "");
        if (value.length === 0)
            return "";

        if (value.startsWith("file:"))
            return value;

        if (value.startsWith("~/"))
            return "file://" + Quickshell.env("HOME") + value.slice(1);

        if (value.startsWith("/"))
            return "file://" + value;

        if (value.startsWith("wallpapers/")) {
            const configured = Quickshell.env("BLOX_DATA_DIR") || "";
            const dataRoot = configured.length > 0 ? configured : Quickshell.shellDir + "/../../../../themes";
            return "file://" + dataRoot + "/" + value;
        }
        return "file://" + Quickshell.shellDir + "/../../../.." + "/" + value;
    }

    function setPreviewWallpaper(data) {
        if (data.targets && data.targets.wallpaper) {
            wallpaperSource = wallpaperUrl(data.wallpaper.path);
            wallpaperFit = data.wallpaper.fit;
        } else {
            wallpaperSource = activeWallpaperSource;
            wallpaperFit = activeWallpaperFit;
        }
    }

    function loadWallpaper(raw) : bool {
        try {
            const data = JSON.parse(raw);
            if (data.schema_version !== 1 || !data.path || ["cover", "contain", "tile"].indexOf(data.fit) < 0)
                throw new Error("unsupported or incomplete wallpaper document");

            activeWallpaperSource = wallpaperUrl(data.path);
            activeWallpaperFit = data.fit;
            if (!previewActive) {
                wallpaperSource = activeWallpaperSource;
                wallpaperFit = activeWallpaperFit;
            }
            return true;
        } catch (error) {
            console.warn("[blox.theme] rejected wallpaper state: " + error);
            return false;
        }
    }

    function resetWallpaper() : string {
        const fallback = defaults.themeDocument().wallpaper;
        activeWallpaperSource = wallpaperUrl(fallback.path);
        activeWallpaperFit = fallback.fit;
        if (!previewActive) {
            wallpaperSource = activeWallpaperSource;
            wallpaperFit = activeWallpaperFit;
        }
        return activeWallpaperSource;
    }

    function reloadWallpaper() : string {
        wallpaperFile.reload();
        return activeWallpaperSource;
    }

    function previewSource(raw) : bool {
        const loaded = document.previewSource(raw);
        if (!loaded)
            return false;

        const data = typeof raw === "string" ? JSON.parse(raw) : raw;
        setPreviewWallpaper(data);
        return true;
    }

    function cancelPreview() : string {
        previewActive = false;
        previewThemeId = "";
        wallpaperSource = activeWallpaperSource;
        wallpaperFit = activeWallpaperFit;
        const active = themeFile.text();
        if (!active || !loadJson(active))
            reset();

        reloadWidgets();
        return themeId;
    }

    function reload() : string {
        previewActive = false;
        previewThemeId = "";
        wallpaperSource = activeWallpaperSource;
        wallpaperFit = activeWallpaperFit;
        themeFile.reload();
        wallpaperFile.reload();
        return themeId;
    }

    // Cursor images belong to each Wayland client. Recreate Blox's windows so
    // they request the cursor image from the newly selected theme.
    function reloadCursor() : string {
        Quickshell.reload(true);
        return "reloading";
    }

    function reloadWidgets() : string {
        widgetFile.reload();
        return widgetProfile;
    }

    ThemeDefaults {
        id: defaults
    }

    ThemeDocumentController {
        id: document

        theme: root
        defaults: defaults
    }

    FileView {
        id: themeFile

        path: root.themePath
        preload: true
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: {
            if (!defaults.ready)
                return ;

            if (!root.previewActive)
                root.loadJson(text());
            else
                root.loadActiveIdentity(text());
            root.ready = defaults.ready;
        }
        onFileChanged: {
            if (!root.previewActive)
                reload();
            else
                themeFile.reload();
        }
    }

    FileView {
        id: wallpaperFile

        path: root.wallpaperPath
        preload: true
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadWallpaper(text())
        onFileChanged: reload()
    }

    Connections {
        function onLoaded() {
            if (!root.previewActive)
                root.reload();
        }

        function onFailed(reason) {
            root.ready = false;
            console.error("[blox.theme] defaults unavailable: " + reason);
        }

        target: defaults
    }

    FileView {
        id: widgetFile

        path: root.widgetPath
        preload: true
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: {
            if (!root.previewActive && !root.loadWidgets(text()))
                root.resetWidgets();

        }
        onFileChanged: {
            if (!root.previewActive)
                reloadWidgets();

        }
    }

    IpcHandler {
        function reload() : string {
            return root.reload();
        }

        function reloadCursor() : string {
            return root.reloadCursor();
        }

        function reset() : string {
            return root.reset();
        }

        function status() : string {
            return root.themeId + ":" + root.variant;
        }

        function reloadWidgets() : string {
            return root.reloadWidgets();
        }

        function resetWidgets() : string {
            return root.resetWidgets();
        }

        function reloadWallpaper() : string {
            return root.reloadWallpaper();
        }

        function resetWallpaper() : string {
            return root.resetWallpaper();
        }

        target: "theme"
    }

}
