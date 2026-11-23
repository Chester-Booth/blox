pragma Singleton
import QtQuick

QtObject {
    signal osdPositionPreviewRequested()
    property string barPosition: "left"
    property bool ready: true
    property int barEdgeInset: 0
    readonly property int railWidth: 34
    property string themeStateRoot: "/tmp/blox-test-theme"
    property string activeThemeId: "blox-panel"
    property color background: "#151922"
    property color surface: "#1d2330"
    property color surfaceAlt: "#252d3b"
    property color foreground: "#e7ebf2"
    property color muted: "#8791a3"
    property color red: "#f38ba8"
    property color blue: "#82aaff"
    property color green: "#c3e88d"
    property color yellow: "#ffcb6b"
    property color mauve: "#cba6f7"
    property color teal: "#94e2d5"
    property color accent: "#89b4fa"
    property color border: "#394252"
    property string bodyFontFamily: "sans-serif"
    property string fontFamily: "sans-serif"
    property string monoFontFamily: "monospace"
    property string themeId: "search-fixture"
    property bool previewActive: false
    property real densityScale: 1.0
    property real radiusScale: 1.25

    property string widgetError: ""
    property var widgetItems: []
    signal widgetLayoutEditRequested()
    signal widgetEditModeRequested(var widgets)
    signal widgetEditModeFinished(string payload, string returnWorkspace)

    property int reloadRequests: 0
    function reloadCursor() { reloadRequests += 1; }

    function widgetPresetDefaults(profile) { return {opacity: 0.52, padding: 12, radius: 6, font_size: 12}; }

    function wallpaperUrl(path) {
        return String(path || "");
    }

    function scaledRadius(value) {
        return value;
    }

    property color selectionForeground: foreground
    property int buttonSize: 30
    property int barRadius: 5
    property int iconSize: 16
    function barScaledSpacing(value) { return value; }

    function scaledSpacing(value) {
        return value;
    }

    function withAlpha(value, opacity) {
        return Qt.rgba(value.r, value.g, value.b, opacity);
    }

    function cancelPreview() { previewActive = false; }
    function loadShell(shell) { return true; }
    function loadWidgetSource(profile) { return true; }
}
