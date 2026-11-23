import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "ActionFreshness"
    Services.AudioStatus { id: audio; providerSource: Qt.resolvedUrl("fixtures/RejectingActionProvider.qml") }
    Services.NetworkStatus { id: network; providerSource: Qt.resolvedUrl("fixtures/RejectingActionProvider.qml") }
    Services.BluetoothStatus { id: bluetooth; providerSource: Qt.resolvedUrl("fixtures/RejectingActionProvider.qml") }
    Services.GpuStatus { id: gpu; providerSource: Qt.resolvedUrl("fixtures/RejectingActionProvider.qml") }
    Services.MonitorStatus { id: monitor; providerSource: Qt.resolvedUrl("fixtures/RejectingActionProvider.qml") }
    Services.BarContent { id: content }
    SignalSpy { id: microphoneFeedback; target: audio; signalName: "microphoneFeedbackRequested" }

    function owners() { return [audio, network, bluetooth, gpu, monitor]; }
    function invoke(owner) {
        if (owner === audio) return owner.action("set-volume", "51");
        if (owner === network) return owner.action("set-wifi", "on");
        if (owner === bluetooth) return owner.action("set-enabled", "on");
        if (owner === gpu) return owner.action("set-mode", "hybrid");
        return owner.action("set-refresh", "panel", "60");
    }
    function snapshot(changed) {
        return Object.assign({schemaVersion: 1, providerRevision: 7, observedAtMs: 1010,
            stale: false, busy: false, errorCode: null, micCanChange: true, supportedModes: ["hybrid"],
            monitors: [{name: "panel", canChange: true, rates: [{id: "60"}]}],
            capability: {available: true, ready: true, canChange: true, permission: "not-required"}}, changed);
    }
    function init() {
        microphoneFeedback.clear();
        for (const owner of owners()) {
            tryCompare(owner, "providerReady", true);
            owner.json = snapshot({});
        }
    }
    function test_guard_classification_data() {
        return [{tag: "denied", change: {capability: {available: true, canChange: false, permission: "denied"}}, code: "permission-denied"},
            {tag: "busy", change: {busy: true}, code: "busy"},
            {tag: "stale", change: {stale: true}, code: "stale"},
            {tag: "unavailable", change: {capability: {available: false, canChange: false}}, code: "unavailable"}];
    }
    function test_guard_classification(data) {
        for (const owner of owners()) {
            owner.json = snapshot(data.change);
            const reply = invoke(owner);
            compare(reply.ok, false);
            compare(reply.code, data.code);
            compare(owner.revision, 1);
        }
    }
    function test_actual_setter_refusal_is_failed() {
        for (const owner of owners()) {
            const reply = invoke(owner);
            compare(reply.ok, false);
            compare(reply.code, "failed");
        }
    }
    function test_absent_microphone_on_healthy_output_is_unavailable() {
        audio.json = snapshot({micCanChange: false});
        const reply = audio.action("set-mic", "muted");
        compare(reply.ok, false);
        compare(reply.code, "unavailable");
    }
    function test_rejected_microphone_action_never_announces_feedback() {
        audio.json = snapshot({micMuted: false});
        compare(audio.action("set-mic", "muted").code, "failed");
        compare(microphoneFeedback.count, 0);
    }
    function test_revision_change_is_not_hardware_completion() {
        const fixtures = [
            {source: "AudioStatus.qml", operation: "set-volume", value: "51"},
            {source: "NetworkStatus.qml", operation: "set-wifi", value: "on"},
            {source: "BluetoothStatus.qml", operation: "set-enabled", value: "on"},
            {source: "GpuStatus.qml", operation: "set-mode", value: "dedicated"},
            {source: "MonitorStatus.qml", operation: "set-refresh", value: "144"}
        ];
        for (const item of fixtures) {
            const component = Qt.createComponent(Qt.resolvedUrl("../../shell/services/" + item.source));
            compare(component.status, Component.Ready);
            const owner = component.createObject(testCase, {providerSource: Qt.resolvedUrl("fixtures/PendingActionProvider.qml")});
            verify(owner !== null);
            tryCompare(owner, "providerReady", true);
            const reply = item.operation === "set-refresh" ? owner.action(item.operation, "panel", item.value) : owner.action(item.operation, item.value);
            verify(reply.ok);
            verify(reply.data.afterRevision > reply.data.beforeRevision);
            compare(owner.json.busy, true);
            compare(reply.data.pending, true);
            owner.destroy();
        }
    }
    function test_monitor_invalid_choice_is_distinct_from_refusal() {
        compare(monitor.action("set-refresh", "missing", "60").code, "invalid-data");
        compare(monitor.action("set-refresh", "panel", "999").code, "invalid-data");
        compare(monitor.action("set-refresh", "panel", "60").code, "failed");
    }
    function test_public_snapshot_preserves_pending_and_terminal_metadata() {
        for (const family of ["audio", "network", "bluetooth", "gpu", "monitors", "brightness", "touchpad", "powerProfile", "vendorPerformance"]) {
            content[family] = snapshot({busy: true});
            let actual = content.statusSnapshot().data[family];
            compare(actual.providerRevision, 7);
            compare(actual.observedAtMs, 1010);
            compare(actual.busy, true);
            compare(actual.stale, false);
            content[family] = snapshot({providerRevision: 8, busy: false, errorCode: "timeout"});
            actual = content.statusSnapshot().data[family];
            compare(actual.providerRevision, 8);
            compare(actual.errorCode, "timeout");
            compare(actual.busy, false);
            verify(actual.summary === undefined);
            verify(actual.tooltip === undefined);
        }
    }
}
