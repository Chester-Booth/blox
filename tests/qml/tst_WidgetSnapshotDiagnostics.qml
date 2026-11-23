import QtQuick
import QtTest

TestCase {
    name: "WidgetSnapshotDiagnostics"
    property var subject
    function initTestCase() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../../shell/modules/DesktopWidgets.qml"), false);
        request.send();
        const source = request.responseText;
        const start = source.indexOf("    function snapshotMetadata(");
        verify(start >= 0);
        let end = source.indexOf("{", start), depth = 1;
        while (depth && ++end < source.length) {
            if (source[end] === "{") depth++;
            if (source[end] === "}") depth--;
        }
        subject = Qt.createQmlObject("import QtQuick; QtObject {" + source.slice(start, end + 1) + "}", this);
    }
    function test_progress_without_content() {
        const result = subject.snapshotMetadata({generation: 7, revision: 12,
            observedMonotonicMs: 1234.5, state: "ready", value: {text: "private content"}, error: "private path"});
        compare(JSON.stringify(result), JSON.stringify({generation: 7, revision: 12,
            observedMonotonicMs: 1234.5, state: "ready"}));
    }
    function test_absent_snapshot_is_unavailable_metadata() {
        compare(JSON.stringify(subject.snapshotMetadata(null)),
            JSON.stringify({generation: null, revision: null, observedMonotonicMs: null, state: null}));
    }
    function test_invalid_values_do_not_become_progress() {
        const result = subject.snapshotMetadata({generation: -1, revision: Infinity,
            observedMonotonicMs: "1234", state: "private content"});
        compare(JSON.stringify(result), JSON.stringify({generation: null, revision: null,
            observedMonotonicMs: null, state: null}));
    }
    function test_fractional_or_unsafe_counters_are_not_identities() {
        const result = subject.snapshotMetadata({generation: 1.5, revision: 9007199254740992,
            observedMonotonicMs: 1234.5, state: "ready"});
        compare(result.generation, null);
        compare(result.revision, null);
        compare(result.observedMonotonicMs, 1234.5);
    }
}
