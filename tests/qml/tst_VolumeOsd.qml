import QtQuick
import QtTest
import Quickshell
import "../../shell/services" as Services
import "../../shell/modules" as Modules

TestCase {
    id: testCase
    name: "VolumeOsd"

    Component {
        id: fixture
        Item {
            property alias content: content
            property alias osd: osd
            Services.BarContentController {
                id: content
                scriptRoot: "/fixture"
                audio.providerSource: Qt.resolvedUrl("fixtures/ObservedAudioProvider.qml")
            }
            Modules.OsdController { id: osd; audioStatus: content.audio }
        }
    }
    Component {
        id: replacementSink
        QtObject {
            property bool ready: true
            property string name: "replacement"
            property var audio: QtObject { property real volume: 0.8; property bool muted: false }
        }
    }
    property var owner
    property var provider
    property var osd
    SignalSpy { id: shown; signalName: "showingChanged" }

    function init() {
        owner = createTemporaryObject(fixture, testCase);
        verify(owner !== null);
        osd = owner.osd;
        tryCompare(owner.content.audio, "providerReady", true);
        for (const child of owner.content.audio.data)
            if (child.item) provider = child.item;
        verify(provider !== null);
        tryCompare(osd, "observedAudioVolume", 50);
        compare(osd.audioStatus, owner.content.audio);
        compare(osd.observedAudioSink, provider.sink);
        verify(!osd.showing);
        shown.target = osd; shown.clear();
        Quickshell.detachedCalls = [];
    }
    function cleanup() { shown.target = null; provider = null; }
    function settle() { wait(0); }
    function dismiss() { osd.showing = false; shown.clear(); }
    function restoreStatusBinding() {
        const p = provider;
        owner.content.audio.json = Qt.binding(function() { return p.json; });
    }
    function test_startup_is_silent_and_the_same_native_owner_is_observed() {
        wait(30);
        verify(!osd.showing);
        compare(shown.count, 0);
        compare(osd.audioStatus, owner.content.audio);
        verify(osd.observedAudioSink === provider.sink);
    }
    function test_external_observations_mute_overdrive_and_mic_metadata_noops() {
        provider.volume = 1.37;
        tryCompare(osd, "value", 137);
        verify(osd.showing); verify(osd.volumeOverdriven); compare(osd.fillValue, 100);
        compare(osd.valueText, "137%");
        provider.muted = true;
        tryCompare(osd, "muted", true);
        compare(osd.valueText, "Muted"); verify(!osd.volumeOverdriven);
        provider.muted = false;
        tryCompare(osd, "muted", false);
        dismiss();
        provider.micMuted = true;
        provider.source.audio.volume = 0.2;
        provider.sink.name = "renamed-output";
        provider.refresh();
        provider.volume = 1.37;
        settle();
        verify(!osd.showing); compare(shown.count, 0);
        // Existing microphone confirmation/feedback is retained without a volume popup.
        verify(owner.content.audio.action("toggle-mic", "").ok);
        settle(); verify(!osd.showing); compare(osd.label, "Volume");
        compare(Quickshell.detachedCalls, [["/fixture/providers/mic-feedback.sh", "false"]]);
    }
    function test_unavailable_recovery_and_replaced_sink_establish_silent_baselines() {
        provider.ready = false;
        settle(); compare(osd.observedAudioVolume, null); verify(!osd.showing);
        provider.volume = 0.7;
        provider.ready = true;
        tryCompare(osd, "observedAudioVolume", 70);
        verify(!osd.showing);
        provider.volume = 0.72;
        tryCompare(osd, "value", 72);
        dismiss();
        const sink = createTemporaryObject(replacementSink, testCase);
        provider.output = sink;
        tryCompare(osd, "observedAudioSink", sink);
        compare(osd.observedAudioVolume, 80); verify(!osd.showing);
        sink.audio.volume = 0.82;
        tryCompare(osd, "value", 82);
        dismiss();
        provider.output = null;
        settle(); compare(osd.observedAudioVolume, null);
        provider.output = sink;
        tryCompare(osd, "observedAudioVolume", 82);
        verify(!osd.showing);
    }
    function test_two_second_burst_reconciles_actual_observations_not_receipts() {
        provider.deferWrites = true;
        let keys = null;
        for (const child of owner.content.data)
            if (typeof child.handleHyprlandEvent === "function") keys = child;
        verify(keys !== null);
        for (let i = 0; i < 80; i++) {
            const receipt = keys.handleHyprlandEvent({name: "custom", data: "blox_media_key>>volume-" + (i < 40 ? "up" : "down")});
            verify(receipt.ok); compare(receipt.data.operation, "adjust-volume");
            const target = receipt.data.value;
            // Receipt leaves observed state alone. Only fake native readback moves OSD.
            if (i === 0) { settle(); verify(!osd.showing); compare(osd.observedAudioVolume, 50); }
            provider.volume = (target + 1) / 100;
            wait(25);
            compare(osd.value, target + 1);
        }
        provider.volume = 0.47;
        tryCompare(osd, "value", 47);
        compare(osd.valueText, "47%");
        compare(Quickshell.detachedCalls, []);
        // OSD itself owns no Process. The unrelated bar provider I/O is stubbed.
        for (const child of osd.data) verify(child.command === undefined);
    }
    function test_preview_defers_observations_then_reads_latest_final_state() {
        osd.preview("volume", 120, false);
        compare(osd.value, 120);
        provider.volume = 0.6;
        settle(); compare(osd.value, 120);
        wait(180);
        osd.preview("volume", 125, false);
        provider.volume = 0.65;
        wait(180); compare(osd.value, 125);
        provider.volume = 0.67;
        tryCompare(osd, "value", 67, 500);
        compare(osd.valueText, "67%");
        provider.volume = 0.68;
        tryCompare(osd, "value", 68);
        compare(Quickshell.detachedCalls, []);
    }
    function test_failed_or_noop_preview_uses_observed_state_and_invalid_readback_stays_silent() {
        provider.deferWrites = true;
        osd.preview("volume", 100, false);
        verify(owner.content.audio.action("set-volume", "100").data.pending);
        tryCompare(osd, "value", 50, 600);
        const baseline = owner.content.audio.json;
        for (const patch of [
            {stale: true}, {busy: true}, {errorCode: "readback-failed"},
            {capability: {available: true, ready: true, canChange: true, permission: "denied"}},
            {volume: NaN}, {volume: -1}, {muted: "false"}
        ]) {
            dismiss();
            osd.preview("volume", 100, false);
            owner.content.audio.json = Object.assign({}, baseline, patch);
            settle(); verify(!osd.showing);
            wait(320); verify(!osd.showing);
            restoreStatusBinding();
            tryCompare(osd, "observedAudioVolume", 50);
            verify(!osd.showing);
        }
        provider.volume = 0.52;
        tryCompare(osd, "value", 52);
        verify(osd.showing);
    }
    function test_device_or_owner_replacement_cancels_old_preview() {
        osd.preview("volume", 110, false);
        const sink = createTemporaryObject(replacementSink, testCase);
        provider.output = sink;
        settle(); verify(!osd.showing);
        wait(330); verify(!osd.showing);
        compare(osd.observedAudioVolume, 80);
        osd.preview("volume", 120, false);
        osd.audioStatus = null;
        settle(); verify(!osd.showing);
        osd.audioStatus = owner.content.audio;
        tryCompare(osd, "observedAudioVolume", 80);
        wait(330); verify(!osd.showing);
    }
    function test_explicit_show_and_other_osds_cancel_preview_reconciliation() {
        osd.preview("volume", 120, false);
        osd.show("volume", 99, true);
        wait(330); compare(osd.value, 99); verify(osd.muted);
        osd.preview("volume", 120, false);
        provider.volume = 0.6;
        // Its observation is queued, then an explicit IPC-style show wins.
        osd.show("mic", 0, true);
        wait(330); compare(osd.label, "Microphone");
        osd.preview("volume", 120, false);
        provider.volume = 0.65;
        osd.showNotice("Failure", "Unavailable", "", "error", 1200);
        wait(330); compare(osd.label, "Failure");
        osd.preview("volume", 120, false);
        osd.showBlueLight("on", true);
        wait(330); compare(osd.label, "Blue light");
        osd.show("brightness", 42, false);
        compare(osd.label, "Brightness"); compare(osd.value, 42);
    }
}
