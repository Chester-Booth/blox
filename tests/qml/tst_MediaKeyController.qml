import QtQuick
import QtTest
import Quickshell
import Quickshell.Hyprland
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "MediaKeyController"

    Component {
        id: fixture
        Item {
            property alias audio: audioStatus
            property alias brightness: brightnessStatus
            property alias keys: keys
            Services.AudioStatus {
                id: audioStatus
                providerSource: Qt.resolvedUrl("fixtures/MediaKeyAudioProvider.qml")
                scriptRoot: "/fixture"
            }
            Services.BrightnessStatus { id: brightnessStatus; scriptRoot: "/fixture"; interval: 0 }
            Services.MediaKeyController { id: keys; audio: audioStatus; brightness: brightnessStatus }
        }
    }
    Component { id: contentController; Services.BarContentController { scriptRoot: "/fixture"; audio.providerSource: Qt.resolvedUrl("fixtures/MediaKeyAudioProvider.qml") } }
    SignalSpy { id: feedback; signalName: "brightnessApplied" }
    SignalSpy { id: micFeedback; signalName: "microphoneFeedbackRequested" }
    property var owner
    property var brightnessProvider
    property var audioProvider
    property var actionProcess
    property var queryProcess

    function provider(status) {
        tryCompare(status, "providerReady", true);
        for (const child of status.data)
            if (child.item) return child.item;
        fail("Loaded provider missing");
    }
    function processes(brightness) {
        const result = [];
        for (const child of brightness.data)
            if (child.command !== undefined && child.sentSignals !== undefined) result.push(child);
        compare(result.length, 2);
        return result;
    }
    function event(key) { return {name: "custom", data: "blox_media_key>>" + key}; }
    function send(key) { return owner.keys.handleHyprlandEvent(event(key)); }
    function init() {
        owner = createTemporaryObject(fixture, testCase);
        verify(owner !== null);
        audioProvider = provider(owner.audio);
        brightnessProvider = provider(owner.brightness);
        const p = processes(brightnessProvider);
        queryProcess = p[0]; actionProcess = p[1];
        brightnessProvider.applyPayload({capability: {available: true}, device: "fake-panel", percent: 50});
        feedback.target = owner.brightness; feedback.clear();
        micFeedback.target = owner.audio; micFeedback.clear();
        Quickshell.detachedCalls = [];
    }
    function cleanup() {
        feedback.target = null;
        micFeedback.target = null;
    }
    function completeBrightness(readback, code) {
        brightnessProvider.actionRaw = String(readback) + "\n";
        actionProcess.finish(code || 0, 0);
    }
    function verifyNoIpc() {
        compare(Quickshell.detachedCalls, []);
        // The only process starts are the existing provider's write/discovery.
        compare(actionProcess.command.slice(0, 2), ["/fixture/providers/hardware-control.sh", "brightness-set"]);
        compare(queryProcess.command, ["/fixture/status/brightness.sh", ""]);
    }
    function test_bar_content_wires_the_existing_owners() {
        const content = createTemporaryObject(contentController, testCase);
        verify(content !== null);
        const loadedAudio = provider(content.audio);
        const loadedBrightness = provider(content.brightness);
        loadedBrightness.applyPayload({capability: {available: true}, device: "fake-panel", percent: 50});
        let keyController = null;
        for (const child of content.data)
            if (typeof child.handleHyprlandEvent === "function") keyController = child;
        verify(keyController !== null);
        compare(keyController.audio, content.audio);
        compare(keyController.brightness, content.brightness);
        Hyprland.rawEvent(event("volume-up"));
        compare(content.audio.json.volume, 52);
        Hyprland.rawEvent(event("brightness-up"));
        compare(loadedBrightness.pendingBrightness, "52");
        compare(Quickshell.detachedCalls, []);
    }
    function test_raw_socket_signal_routes_in_order_to_existing_audio_owner() {
        const before = owner.audio.revision;
        Hyprland.rawEvent(event("volume-up"));
        Hyprland.rawEvent(event("volume-up"));
        Hyprland.rawEvent(event("volume-down"));
        compare(owner.audio.json.volume, 52);
        verify(owner.audio.revision > before);
        compare(Quickshell.detachedCalls, []);
    }
    function test_two_second_repeat_stream_data() {
        return [{tag: "volume", kind: "volume"}, {tag: "brightness", kind: "brightness"}];
    }
    function test_two_second_repeat_stream(row) {
        // 80 events at 25 ms spacing, with a reversal halfway through.
        // This is a functional burst, not a performance benchmark.
        let target = 50;
        let completions = 0;
        for (let i = 0; i < 80; i++) {
            const direction = i < 40 ? "up" : "down";
            target = Math.max(0, Math.min(row.kind === "volume" ? 150 : 100, target + (i < 40 ? 2 : -2)));
            const receipt = send(row.kind + "-" + direction);
            verify(receipt.ok, JSON.stringify(receipt));
            compare(receipt.data.value, target);
            if (row.kind === "brightness") {
                verify(receipt.data.pending);
                compare(brightnessProvider.pendingBrightness, String(target));
                // A slower write completes every fourth event. Repeats replace
                // one pending target instead of creating an IPC/process queue.
                if (i % 4 === 3) {
                    completeBrightness(brightnessProvider.activeBrightness);
                    completions++;
                }
            } else {
                compare(owner.audio.json.volume, target);
                verify(!receipt.data.pending);
            }
            wait(25);
        }
        if (row.kind === "brightness") {
            while (actionProcess.running) { completeBrightness(brightnessProvider.activeBrightness); completions++; }
            compare(owner.brightness.json.percent, target);
            compare(feedback.count, completions);
            compare(brightnessProvider.pendingBrightness, "");
            verify(!owner.brightness.json.busy);
            verifyNoIpc();
        } else compare(Quickshell.detachedCalls, []);
    }
    function test_clamps_and_reversal_use_pending_brightness_and_current_audio() {
        for (let i = 0; i < 100; i++) { verify(send("volume-up").ok); verify(send("brightness-up").ok); }
        compare(owner.audio.json.volume, 150);
        compare(brightnessProvider.pendingBrightness, "100");
        verify(send("volume-down").ok); verify(send("brightness-down").ok);
        compare(owner.audio.json.volume, 148);
        compare(brightnessProvider.pendingBrightness, "98");
        for (let i = 0; i < 100; i++) { verify(send("volume-down").ok); verify(send("brightness-down").ok); }
        compare(owner.audio.json.volume, 0);
        compare(brightnessProvider.pendingBrightness, "0");
        verify(send("volume-up").ok); verify(send("brightness-up").ok);
        compare(owner.audio.json.volume, 2);
        compare(brightnessProvider.pendingBrightness, "2");
        while (actionProcess.running) completeBrightness(brightnessProvider.activeBrightness);
        compare(owner.brightness.json.percent, 2);
        verifyNoIpc();
    }
    function test_denials_do_not_bypass_the_action_contract() {
        const baseline = owner.brightness.json;
        verify(send("brightness-up").ok);
        const pending = brightnessProvider.pendingBrightness;
        const rows = [
            {patch: {stale: true}, code: "stale"},
            {patch: {capability: {available: true, canChange: true, permission: "denied"}}, code: "permission-denied"},
            {patch: {capability: {available: false, canChange: false}}, code: "unavailable"}
        ];
        for (const row of rows) {
            owner.brightness.json = Object.assign({}, baseline, row.patch);
            compare(send("brightness-up").code, row.code);
            compare(brightnessProvider.pendingBrightness, pending);
            owner.audio.json = Object.assign({}, owner.audio.json, row.patch);
            const before = audioProvider.volume;
            compare(send("volume-up").code, row.code);
            compare(audioProvider.volume, before);
            // Restore the provider-backed AudioStatus binding explicitly.
            owner.audio.json = Qt.binding(function() { return audioProvider.json; });
        }
        owner.audio.json = Object.assign({}, owner.audio.json, {busy: true});
        compare(send("volume-up").code, "busy");
        owner.brightness.json = baseline;
        completeBrightness("52");
        audioProvider.ready = false;
        owner.audio.json = Qt.binding(function() { return audioProvider.json; });
        verify(!send("volume-up").ok);
        compare(Quickshell.detachedCalls, []);
    }
    function test_readback_is_authority_and_failure_discards_pending_target() {
        verify(send("brightness-up").data.pending);
        verify(send("brightness-up").data.pending);
        compare(feedback.count, 0);
        compare(owner.brightness.json.percent, 50);
        completeBrightness("51");
        compare(feedback.signalArguments[0][0], 51);
        compare(brightnessProvider.activeBrightness, "54");
        completeBrightness("53");
        compare(owner.brightness.json.percent, 53);
        compare(feedback.signalArguments[1][0], 53);
        // A query started during the write cannot rewind confirmed readback.
        brightnessProvider.pendingRaw = JSON.stringify({capability: {available: true}, device: "fake-panel", percent: 53});
        queryProcess.finish(0, 0);
        verify(send("brightness-up").ok);
        brightnessProvider.refresh();
        verify(send("brightness-up").ok);
        completeBrightness("54");
        completeBrightness("not-an-integer");
        compare(brightnessProvider.actionError, "malformed-action-status");
        compare(brightnessProvider.pendingBrightness, "");
        compare(owner.brightness.json.percent, 54);
        compare(feedback.count, 3);
        brightnessProvider.pendingRaw = JSON.stringify({capability: {available: true}, device: "fake-panel", percent: 12});
        queryProcess.finish(0, 0);
        compare(owner.brightness.json.percent, 54);
        verify(send("brightness-down").ok);
        completeBrightness("52", 1);
        compare(brightnessProvider.actionError, "action-failed");
        compare(feedback.count, 3);
        verifyNoIpc();
    }
    function test_mute_and_microphone_keep_existing_owner_and_feedback() {
        verify(send("volume-mute").ok); compare(owner.audio.json.muted, true);
        verify(send("volume-mute").ok); compare(owner.audio.json.muted, false);
        verify(send("mic-mute").ok); compare(owner.audio.json.micMuted, true);
        verify(send("mic-mute").ok); compare(owner.audio.json.micMuted, false);
        compare(micFeedback.count, 2);
        // Microphone feedback retains its existing LED/OSD adapter, stubbed here.
        compare(Quickshell.detachedCalls, [["/fixture/providers/mic-feedback.sh", "true"], ["/fixture/providers/mic-feedback.sh", "false"]]);
    }
    function test_unknown_or_command_payloads_are_ignored() {
        const events = [null, {}, {name: "exec", data: "blox_media_key>>volume-up"},
            {name: "custom", data: {toString: function() { return "blox_media_key>>volume-up"; }}},
            event("volume-up 20"), event("volume-up; touch /tmp/no"), event("brightness-set>>100"),
            event("camera-toggle"), event("touchpad-toggle"), event("volume-down\n"),
            {name: "custom", data: "blox_shortcut_guide>>toggle"}];
        for (const e of events) compare(owner.keys.handleHyprlandEvent(e), null);
        compare(owner.audio.json.volume, 50);
        compare(owner.brightness.json.percent, 50);
        verify(!actionProcess.running);
        compare(Quickshell.detachedCalls, []);
    }
}
