import QtQuick
import ".."

WidgetView {
    id: root
    readonly property var observation: snapshot && snapshot.value ? snapshot.value : ({})
    readonly property bool dataReady: !!snapshot && snapshot.state === "ready"
    readonly property bool compactPresentation: context && context.presentation === "compact"
    readonly property real gap: (compactPresentation ? 8 : 12) * density
    readonly property real density: theme && theme.densityScale !== undefined ? theme.densityScale : 1
    readonly property real rounding: theme && theme.radiusScale !== undefined ? theme.radiusScale : 1
    readonly property string bodyFont: theme && theme.fontFamily ? theme.fontFamily : "Sans Serif"
    readonly property string monoFont: theme && theme.monospaceFamily ? theme.monospaceFamily : "monospace"
    readonly property real baseSize: theme && theme.fontSize ? theme.fontSize : 14
    readonly property color foreground: colour("foreground", "#cdd6f4")
    readonly property color muted: colour("muted", "#a6adc8")
    readonly property color accent: colour("accent", "#89b4fa")
    readonly property color borderColour: colour("border", "#3b3c4a")
    readonly property color positive: colour("positive", "#94e2d5")
    readonly property color secondary: colour("secondary", colour("accent", "#89b4fa"))
    readonly property color background: colour("background", "#1e1e1e")
    readonly property real padding: Math.min(width / 10, height / 10, (fullscreen ? 40 : compactPresentation ? 16 : 20) * density)
    readonly property real displayScale: fullscreen ? Math.max(1, Math.min(width / 600, height / 420, 2.5)) : 1
    readonly property string scrollbarMode: fullscreen ? "hide" : context && context.scrollbars ? context.scrollbars : "auto"
    contentReady: dataReady && width > 0 && height > 0
    clip: true

    HoverHandler { id: viewHover }
    NativeAction {
        objectName: "widgetFullscreenAction"
        x: Math.max(0, root.width - width - 2 * root.density)
        y: 2 * root.density
        z: 10
        visible: !!root.context && root.context.fullscreenEnabled === true
            && (root.fullscreen || viewHover.hovered || root.activeFocus || activeFocus)
        iconName: root.fullscreen ? "arrows-in-line-horizontal" : "corners-out"
        iconRoot: root.theme && root.theme.iconRoot ? root.theme.iconRoot : ""
        text: root.fullscreen ? "Restore" : "Expand"
        Accessible.name: root.fullscreen ? "Restore widget" : "Expand widget"
        foreground: root.muted
        accent: root.accent
        rounding: root.rounding
        pixelSize: 16
        density: root.density
        implicitWidth: 24 * root.density
        implicitHeight: 24 * root.density
        onClicked: root.actionRequested("fullscreen", {})
    }

    function colour(key, fallback) {
        return theme && theme.palette && theme.palette[key] !== undefined ? theme.palette[key] : fallback;
    }
    function numeric(value) { return typeof value === "number" && isFinite(value); }
    function numberText(value, suffix, digits) {
        return numeric(value) ? value.toFixed(digits === undefined ? 0 : digits) + (suffix || "") : "Unavailable";
    }
    function bytes(value) {
        if (!numeric(value)) return "Unavailable";
        const units = ["B", "KiB", "MiB", "GiB", "TiB"];
        let unit = 0;
        while (Math.abs(value) >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
        return value.toFixed(unit > 0 && value < 10 ? 1 : 0) + " " + units[unit];
    }
}
