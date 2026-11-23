import QtQuick
import QtTest
import "../../shell/shared/WidgetWorkArea.js" as WorkArea

TestCase {
    id: test
    name: "WidgetWorkAreaEditor"
    when: windowShown
    visible: true
    width: 1000
    height: 700
    property var subject: null
    property var frame: null
    property var host: null
    property string editorSource: ""
    QtObject {
        id: provider
        property int subscriptions: 0
        property int cancellations: 0
        signal snapshotReady(string consumerId, var snapshot)
        function subscribe(id, kind, settings, generation) {
            subscriptions++;
            Qt.callLater(function() {
                snapshotReady(id, {generation: generation, revision: 0, observedMonotonicMs: 1,
                    state: "ready", error: "", value: {text: Array(30).fill("Natural output ".repeat(20)).join("\n")}});
            });
        }
        function unsubscribe(id) { cancellations++; }
    }

    function block(source, start) {
        verify(start >= 0);
        let index = source.indexOf("{", start), depth = 1;
        while (depth && ++index < source.length) {
            if (source[index] === "{") depth++;
            if (source[index] === "}") depth--;
        }
        return source.slice(start, index + 1);
    }
    function profile(anchor, x, y) {
        return {id: "output", name: "Output", kind: "command", enabled: true,
            placement: {anchor: anchor, sizing: "content", x: x, y: y, width: 200, height: 100},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.5, scrollbars: "auto"},
            fullscreen: {enabled: true, mode: "native"}, settings: {command: ["fixture-never-executed"]}};
    }
    function initTestCase() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/modules/WidgetEditMode.qml"), false);
        request.send();
        const source = request.responseText;
        const functions = ["clone", "initialX", "initialY", "geometryItem"].map(name =>
            block(source, source.indexOf("    function " + name + "("))).join("\n");
        const delegate = block(source, source.indexOf("        Item {\n            id: editor"))
            .replace("required property string document", "property string document: root.document")
            .replace("required property int index", "property int index: 0");
        editorSource = 'import QtQuick; import qs.shared; import "../../widgets/qml/Blox/Widgets" as Widgets; Item { id: root;'
            + 'visible: false; property string document: ' + JSON.stringify(JSON.stringify(profile("top-left", -20, -10)))
            + '; property rect widgetBounds: Qt.rect(58, 9, 936, 681); property var widgetTheme: null;'
            + 'property var provider: null; property var qmlRegistry: ({}); property bool active: true;'
            + 'property string selectedWidgetId: ""; property int selectedIndex: -1; signal itemChanged(int index, var item);'
            + functions + delegate + '}';
    }
    function init() {
        failOnWarning(/.*[Bb]inding loop.*/);
        provider.subscriptions = 0;
        provider.cancellations = 0;
        // Exercise the production editor delegate with the real SDK host/view.
        subject = Qt.createQmlObject(editorSource, test, Qt.resolvedUrl("WorkAreaEditorFixture.qml"));
        subject.visible = false;
        subject.width = 1000;
        subject.height = 700;
        subject.provider = provider;
        subject.document = JSON.stringify(profile("top-left", -20, -10));
        frame = subject.children[0];
        host = frame.children.find(child => typeof child.normalWidth === "number");
        verify(host);
        subject.visible = true;
        tryCompare(host, "phase", "visible");
    }
    function cleanup() {
        subject.destroy();
        subject = null;
        frame = null;
        host = null;
        wait(0);
    }

    function test_natural_size_and_clamp_follow_animated_bounds_without_provider_restart() {
        failOnWarning(/.*[Bb]inding loop.*/);
        const view = host.view;
        const generation = host.revealGeneration;
        const naturalWidth = host.contentWidth, naturalHeight = host.contentHeight;
        compare(provider.subscriptions, 1);
        verify(naturalWidth > subject.widgetBounds.width);
        compare(frame.x, 58);
        compare(frame.y, 9);
        compare(frame.width, host.normalWidth);
        for (const extent of [34, 25, 17, 8, 0, 8, 17, 25, 34]) {
            subject.widgetBounds = WorkArea.bounds(1000, 700, [24, 9, 6, 10], {position: "left", extent: extent});
            wait(0);
            compare(frame.x, 24 + extent);
            compare(frame.y, 9);
            compare(frame.width, subject.widgetBounds.width);
            compare(frame.height, Math.min(naturalHeight, subject.widgetBounds.height));
            compare(host.width, frame.width);
            compare(host.height, frame.height);
            compare(host.contentWidth, naturalWidth);
            compare(host.contentHeight, naturalHeight);
            compare(host.view, view);
            compare(host.revealGeneration, generation);
        }
        subject.widgetBounds = WorkArea.bounds(1000, 700, [24, 9, 6, 10], {position: "top", extent: 34});
        compare(frame.x, 24);
        compare(frame.y, 43);
        compare(provider.subscriptions, 1);
        compare(provider.cancellations, 0);
    }

    function test_editor_matches_sdk_clamp_for_each_anchor_and_excessive_offset() {
        failOnWarning(/.*[Bb]inding loop.*/);
        for (const anchor of ["top-left", "top-right", "bottom-left", "bottom-right", "centre"]) {
            for (const offset of [-1000, 0, 1000]) {
                subject.document = JSON.stringify(profile(anchor, offset, offset));
                tryCompare(host, "phase", "visible");
                compare(frame.x, host._normalGeometry.x);
                compare(frame.y, host._normalGeometry.y);
                verify(frame.x >= subject.widgetBounds.x);
                verify(frame.y >= subject.widgetBounds.y);
                verify(frame.x + frame.width <= subject.widgetBounds.x + subject.widgetBounds.width);
                verify(frame.y + frame.height <= subject.widgetBounds.y + subject.widgetBounds.height);
            }
        }
    }
}
