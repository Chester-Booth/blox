import QtQuick
import QtQuick.Controls
import QtTest
import Blox.Widgets 1.0
import "../../qml/Blox/Widgets/Native" as Native

TestCase {
    id: test
    name: "NativeViews"
    when: windowShown
    visible: true
    width: 1200
    height: 800
    WidgetTheme { id: widgetTheme; iconRoot: Qt.resolvedUrl("../../../shell/assets/phosphor/"); radiusScale: 0; densityScale: 0.75 }
    property var view: null
    SignalSpy { id: artworkPaintSpy; signalName: "painted" }
    Component { id: iconComponent; Native.NativeIcon {} }
    function init() { failOnWarning(/.*/); }
    readonly property var fixture: ({epochMs: 1792230120000, hour: 10, minute: 42, second: 0,
        day: 17, month: 10, year: 2026, title: "Fixture track", artist: "Fixture artist", album: "Fixture album",
        artUrl: "", playbackState: "Paused", positionSeconds: 138, lengthSeconds: 317,
        canPlay: true, canPause: true, canGoNext: true, canGoPrevious: true,
        cpuPercent: 28, memoryPercent: 63, memoryUsedBytes: 10737418240, memoryTotalBytes: 17179869184,
        cpuTemperatureC: null, cpuFrequencyGHz: null, powerW: null, uptimeSeconds: 13320,
        rxBytesPerSecond: 12000, txBytesPerSecond: 1800, interfaces: [{name: "fixture0"}],
        history: [{cpuPercent: 10, rxBytesPerSecond: 10, txBytesPerSecond: 2},
            {cpuPercent: null, rxBytesPerSecond: null, txBytesPerSecond: null},
            {cpuPercent: 28, rxBytesPerSecond: 12000, txBytesPerSecond: 1800}],
        events: [{id: "fixture", title: "Fixture event", start: "2026-10-17T11:00:00+01:00", end: "2026-10-17T12:00:00+01:00", allDay: false, color: "#89b4fa"}],
        entries: [{name: "fixture.txt", path: "/fixture/fixture.txt", isDirectory: false, sizeBytes: 100, modifiedMs: 1792230120000}],
        temperatureC: 14, weatherCode: 3, isDay: true, windSpeedKph: 12})

    function cleanup() { artworkPaintSpy.target = null; if (view) view.destroy(); view = null; widgetTheme.radiusScale = 0; widgetTheme.densityScale = 0.75; wait(0); }
    function make(kind, settings, fullscreen) {
        const component = Qt.createComponent("../../qml/Blox/Widgets/Native/" + kind + "View.qml");
        compare(component.status, Component.Ready, component.errorString());
        view = component.createObject(test, {width: fullscreen ? 1180 : 360, height: fullscreen ? 780 : 300,
            fullscreen: fullscreen, theme: widgetTheme, settings: settings || {}, context: {scrollbars: "show"},
            snapshot: {generation: 1, revision: 1, state: "ready", observedMonotonicMs: 1, value: fixture, error: ""}});
        verify(view !== null, component.errorString());
        return view;
    }
    function test_constructAndRender_data() {
        const variants = [
            {kind: "Clock", settings: {style: "digital", format: "24h", showSeconds: false}},
            {kind: "Clock", settings: {style: "analogue", format: "12h", showSeconds: true}},
            {kind: "Music", settings: {style: "card", showArtwork: true}},
            {kind: "Music", settings: {style: "radial", showArtwork: true}},
            {kind: "Music", settings: {style: "compact", showArtwork: false}},
            {kind: "System", settings: {style: "rings"}}, {kind: "System", settings: {style: "chart"}},
            {kind: "Network", settings: {}}, {kind: "Calendar", settings: {style: "month"}},
            {kind: "Calendar", settings: {style: "agenda"}},
            {kind: "Notes", settings: {title: "Fixture note", text: "<b>Literal text</b>\n" + "Long note\n".repeat(100)}},
            {kind: "Files", settings: {directory: "/fixture"}},
            {kind: "Shortcuts", settings: {items: [{id: "fixture", label: "Fixture", command: ["true"]}]}},
            {kind: "Weather", settings: {provider: "open-meteo", latitude: 51, longitude: 0}}];
        let rows = [];
        for (let i = 0; i < variants.length; i++) {
            for (let full = 0; full < 2; full++) rows.push({tag: variants[i].kind + "-" + i + "-" + full, kind: variants[i].kind, settings: variants[i].settings, fullscreen: !!full});
        }
        return rows;
    }
    function test_constructAndRender(row) {
        make(row.kind, row.settings, row.fullscreen);
        tryCompare(view, "contentReady", true);
        compare(view.scrollbarMode, row.fullscreen ? "hide" : "show");
        const scroll = findChild(view, "nativeScroll");
        if (scroll) compare(scroll.drawsScrollbar, !row.fullscreen && scroll.visible);
        verify(waitForRendering(view));
        const image = grabImage(view);
        compare(image.width, row.fullscreen ? 1180 : 360);
        compare(image.height, row.fullscreen ? 780 : 300);
    }
    function test_presentationUsesTheme_data() {
        const kinds = ["Clock", "Music", "System", "Network", "Calendar", "Notes", "Files", "Shortcuts", "Weather"];
        const rows = [];
        for (const kind of kinds) {
            for (const presentation of ["open", "compact"]) {
                for (const density of [0.75, 1.5]) {
                    for (const rounding of [0, 2]) {
                        rows.push({tag: [kind, presentation, density, rounding].join("-"), kind: kind,
                            presentation: presentation, density: density, rounding: rounding});
                    }
                }
            }
        }
        return rows;
    }
    function test_presentationUsesTheme(row) {
        make(row.kind, {style: row.kind === "System" ? "chart" : "card", text: "A note", items: [{id: "files", label: "Files"}]}, false);
        view.context = {presentation: row.presentation, scrollbars: "auto", fullscreenEnabled: true};
        widgetTheme.densityScale = row.density;
        widgetTheme.radiusScale = row.rounding;
        tryCompare(view, "contentReady", true);
        compare(view.compactPresentation, row.presentation === "compact");
        compare(view.density, row.density);
        compare(view.rounding, row.rounding);
        fuzzyCompare(view.gap, (row.presentation === "compact" ? 8 : 12) * row.density, 0.001);
        verify(view.padding > 0 && view.padding <= view.height / 10);
        verify(waitForRendering(view));
        if (row.kind === "System") {
            compare(findChild(view, "systemHistory").visible, row.presentation === "open");
            compare(findChild(view, "systemCpuMeter").visible, row.presentation === "compact");
        }
        if (row.kind === "Music") {
            const metadata = findChild(view, "musicMetadata");
            const controls = findChild(view, "musicControls");
            verify(metadata.y + metadata.height <= controls.y);
            compare(findChild(view, "musicArtwork").visible, false);
        }
        const expand = findChild(view, "widgetFullscreenAction");
        expand.forceActiveFocus();
        tryCompare(expand, "visible", true);
        compare(expand.iconName, "corners-out");
        verify(String(expand.iconRoot).endsWith("shell/assets/phosphor/"));
    }
    function test_iconUsesExactSvgAndSoftwareTint() {
        view = iconComponent.createObject(test, {width: 40, height: 40, name: "file",
            iconRoot: widgetTheme.iconRoot, tint: "#ff0000"});
        verify(waitForRendering(view));
        const image = grabImage(view);
        let redPixels = 0;
        for (let y = 0; y < 40; y++) {
            for (let x = 0; x < 40; x++) {
                const pixel = image.pixel(x, y);
                if (pixel.r > 0.9 && pixel.g < 0.1 && pixel.b < 0.1 && pixel.a > 0.5) redPixels++;
            }
        }
        verify(redPixels > 100, "The software icon renderer must preserve the requested tint");
    }
    function test_compactMusicArtworkFitsAtMaximumDensity() {
        make("Music", {style: "card", showArtwork: true}, false);
        view.height = 150;
        view.context = {presentation: "compact"};
        widgetTheme.densityScale = 1.5;
        widgetTheme.radiusScale = 2;
        view.snapshot = {state: "ready", value: Object.assign({}, fixture,
            {artUrl: Qt.resolvedUrl("../../preview-fixtures/fixture-artwork.svg")})};
        tryCompare(view, "contentReady", true);
        wait(0);
        const artwork = findChild(view, "musicArtwork");
        const metadata = findChild(view, "musicMetadata");
        const progress = findChild(view, "musicProgress");
        const controls = findChild(view, "musicControls");
        verify(artwork.visible && artwork.height > 0);
        verify(artwork.y + artwork.height <= progress.y);
        verify(metadata.y + metadata.height <= progress.y);
        verify(progress.y + progress.height <= controls.y);
    }
    function test_softwareArtworkClipsAndReplacesCurrentSource() {
        make("Music", {style: "compact", showArtwork: true}, false);
        widgetTheme.radiusScale = 2;
        // Wide and tall PNGs have contrasting borders outside their central square.
        const red = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAMgAAABkCAIAAABM5OhcAAADSElEQVR4nNXOsQ3AQBDDsNt/6c8Cds0YUC/e3fthXrCT/lcXF4S8YCf9ry4uCHnBTvpfXVwQ8oKd9L+6uCDkBTvpf3VxQcgLdtL/6uKCkBfspP/VxQUhL9hJ/6uLC0JesJP+VxcXhLxgJ/2vLi4IecFO+l9dXBDygp30v7q4IOQFO+l/dXFByAt20v/q4oKQF+yk/9XFBSEv2En/q4sLQl6wk/5XFxeEvGAn/a8uLgh5wU76X11cEPKCnfS/urgg5AU76X91cUHIC3bS/+rigpAX7KT/1cUFIS/YSf+riwtCXrCT/lcXF4S8YCf9ry4uCHnBTvpfXVwQ8oKd9L+6uCDkBTvpf3VxQcgLdtL/6uKCkBfspP/VxQUhL9hJ/6uLC0JesJP+VxcXhLxgJ/2vLi4IecFO+l9dXBDygp30v7q4IOQFO+l/dXFByAt20v/q4oKQF+yk/9XFBSEv2En/q4sLQl6wk/5XFxeEvGAn/a8uLgh5wU76X11cEPKCnfS/urgg5AU76X91cUHIC3bS/+rigpAX7KT/1cUFIS/YSf+riwtCXrCT/lcXF4S8YCf9ry4uCHnBTvpfXVwQ8oKd9L+6uCDkBTvpf3VxQcgLdtL/6uKCkBfspP/VxQUhL9hJ/6uLC0JesJP+VxcXhLxgJ/2vLi4IecFO+l9dXBDygp30v7q4IOQFO+l/dXFByAt20v/q4oKQF+yk/9XFBSEv2En/q4sLQl6wk/5XFxeEvGAn/a8uLgh5wU76X11cEPKCnfS/urgg5AU76X91cUHIC3bS/+rigpAX7KT/1cUFIS/YSf+riwtCXrCT/lcXF4S8YCf9ry4uCHnBTvpfXVwQ8oKd9L+6uCDkBTvpf3VxQcgLdtL/6uKCkBfspP/VxQUhL9hJ/6uLC0JesJP+VxcXhLxgJ/2vLi4IecFO+l9dXBDygp30v7q4IOQFO+l/dXFByAt20v/q4oKQF+yk/9XFBSEv2En/q4sLQl6wk/5XFxeEvGAn/a8uLgh5wU76X11cEPKCnfS/urgg5AU76X91cUHIC3bS/+rigpAX7KT/1cUFIS/YSf+riwtCXrCT/lcXF4S8YCf9ry4uCHnBTvpfXVwQ8oKd9D/3Af6H1mQi7rZwAAAAAElFTkSuQmCC";
        const blue = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGQAAADICAIAAACRXtOWAAACK0lEQVR4nO3QwQkAMAwDsey/dLtC+xIHAf19eM7MeuQLQnxBiC8I8QUhviDEF4T4ghBfEOILQnxBiC8I8QUhviDEF4T4ghBfEOILQnxBiC8I8QUhviDEF4T4ghBfEOILQnxBiC8I8QUhviDEF4T4ghBfEOILQnxBiC8I8QUhviDEF4T4ghBfEOILQnxBiC8I8QUhviDEF4T4ghBfEOILQvauv7t4QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFHXq/xBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeE+IIQXxDiC0J8QYgvCPEFIb4gxBeEXOC31mQUM9aGAAAAAElFTkSuQmCC";
        view.snapshot = {state: "ready", value: Object.assign({}, fixture, {artUrl: red})};
        compare(view.contentReady, false);
        tryCompare(view, "contentReady", true);
        let canvas = findChild(view, "softwareArtwork");
        const source = findChild(view, "musicArtworkImage");
        verify(canvas !== null);
        verify(canvas.ready);
        compare(String(source.source), "");
        const decoded = canvas.getContext("2d").createImageData(canvas.loadedSource);
        verify(decoded.width <= canvas.sourceSize.width && decoded.height <= canvas.sourceSize.height);
        fuzzyCompare(decoded.width / decoded.height, 2, 0.01);
        function pixel(x, y) { return canvas.getContext("2d").getImageData(x, y, 1, 1).data; }
        compare(pixel(0, 0)[3], 0);
        let centre = pixel(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2));
        compare(centre[0], 255);
        compare(centre[2], 0);
        compare(centre[3], 255);
        compare(pixel(4, Math.floor(canvas.height / 2))[0], 255);

        widgetTheme.radiusScale = 0;
        compare(view.contentReady, false);
        tryCompare(view, "contentReady", true);
        compare(findChild(view, "softwareArtwork"), null);
        const square = grabImage(source);
        verify(square.pixel(0, 0).r > 0.9);
        widgetTheme.radiusScale = 2;
        tryCompare(view, "contentReady", true);
        canvas = findChild(view, "softwareArtwork");

        view.snapshot = {state: "ready", value: Object.assign({}, fixture, {artUrl: blue})};
        compare(view.contentReady, false);
        compare(canvas.ready, false);
        compare(canvas.visible, false);
        tryCompare(view, "contentReady", true);
        compare(pixel(0, 0)[3], 0);
        centre = pixel(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2));
        compare(centre[0], 0);
        compare(centre[2], 255);
        compare(centre[3], 255);
        compare(pixel(Math.floor(canvas.width / 2), 4)[2], 255);

        const oldSourceWidth = canvas.sourceSize.width;
        view.height = 220;
        compare(view.contentReady, false);
        tryCompare(view, "contentReady", true);
        verify(canvas.sourceSize.width < oldSourceWidth);
        const resized = canvas.getContext("2d").createImageData(canvas.loadedSource);
        verify(resized.width <= canvas.sourceSize.width && resized.height <= canvas.sourceSize.height);
        compare(pixel(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2))[2], 255);
        compare(pixel(0, 0)[3], 0);

        wait(20);
        artworkPaintSpy.target = canvas;
        artworkPaintSpy.clear();
        view.snapshot = {state: "ready", value: Object.assign({}, fixture,
            {artUrl: blue, positionSeconds: fixture.positionSeconds + 1})};
        wait(20);
        compare(artworkPaintSpy.count, 0);
    }
    function test_externalReadiness_data() { return ["Clock", "Music", "System", "Network", "Calendar", "Files", "Weather"].map(kind => ({tag: kind, kind: kind})); }
    function test_externalReadiness(row) {
        make(row.kind, {}, false);
        view.snapshot = {state: "preparing", value: {}};
        compare(view.contentReady, false);
        view.snapshot = {state: "unavailable", value: {}, error: "Fixture missing data"};
        compare(view.contentReady, false);
    }
    function test_exampleClockAllowsContextAndThemeTeardown() {
        const component = Qt.createComponent("../../examples/Clock.qml");
        compare(component.status, Component.Ready, component.errorString());
        view = component.createObject(test, {width: 300, height: 200, context: undefined, theme: undefined});
        verify(view !== null);
        compare(view.contentReady, false);
        view.context = {data: {clock: {state: "ready", value: {epochMs: fixture.epochMs}}}};
        view.snapshot = {state: "ready"};
        compare(view.contentReady, true);
        view.context = undefined;
        view.theme = undefined;
        compare(view.contentReady, false);
    }
    function test_calendarMondayAndMonthLength() {
        make("Calendar", {style: "month"}, false);
        // October 2026 starts on Thursday. Monday is column zero.
        compare(view.firstWeekday, 3);
        compare(view.monthDays, 31);
        compare(view.cellCount, 35);
        view.monthOffset = 4;
        compare(view.monthDays, 28);
    }
    function test_missingMeasurementsRemainMissing() {
        make("System", {}, false);
        compare(view.numberText(view.observation.cpuTemperatureC, "°C"), "Unavailable");
        compare(view.numberText(view.observation.powerW, " W"), "Unavailable");
        compare(view.observation.history[1].cpuPercent, null);
    }
    function test_clockFormats() {
        make("Clock", {style: "digital", format: "12h", showSeconds: true}, false);
        compare(view.timeText, "10:42:00 am");
        view.settings = {style: "digital", format: "24h", showSeconds: false};
        compare(view.timeText, "10:42");
    }
    function test_musicUsesObservedProgress() {
        make("Music", {style: "radial"}, false);
        fuzzyCompare(view.progress, 138 / 317, 0.00001);
        view.snapshot = {state: "ready", value: {positionSeconds: null, lengthSeconds: null}};
        compare(view.progress, -1);
    }
    function test_radialFitsCatalogueHeight() {
        make("Music", {style: "radial"}, false);
        view.height = 220;
        verify(waitForRendering(view));
        const metadata = findChild(view, "musicMetadata");
        const controls = findChild(view, "musicControls");
        const artwork = findChild(view, "musicArtwork");
        verify(artwork.height > 0);
        verify(metadata.y + metadata.height <= controls.y);
        widgetTheme.densityScale = 1.5;
        verify(waitForRendering(view));
        verify(metadata.y + metadata.height <= controls.y);
        widgetTheme.densityScale = 0.75;
    }
}
