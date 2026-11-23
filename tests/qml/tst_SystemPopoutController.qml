import "../../shell/popouts" as Popouts
import QtQuick
import QtQuick.Window
import QtTest

TestCase {
    id: testCase
    name: "SystemPopoutController"

    property bool actionReceived: false
    property string receivedCommand: ""

    QtObject {
        id: audioProvider

        property int volume: 0
        property bool muted: false
        property bool micMuted: false
        property int volumeCalls: 0
        property int muteCalls: 0
        property int micCalls: 0

        property bool rejected: false
        property var json: ({errorCode: "", busy: false, capability: {canChange: true, reason: null}})
        function action(operation, value) {
            if (rejected) return {ok: false, code: "busy", message: "audio action rejected"};
            const accepted = operation === "set-volume" ? setVolume(Number(value)) : operation === "set-mic" ? setMicMuted(value === "muted") : toggleMute();
            return {ok: accepted, code: accepted ? "ok" : "failed"};
        }
        function setVolume(value) {
            volume = value;
            volumeCalls += 1;
            return true;
        }

        function toggleMute() {
            muted = !muted;
            muteCalls += 1;
            return true;
        }

        function setMicMuted(value) {
            micMuted = value;
            micCalls += 1;
            return true;
        }
    }

    QtObject {
        id: networkProvider

        property bool wifiEnabled: true
        property int calls: 0
        property bool rejected: false
        property var json: ({errorCode: "", busy: false, capability: {canChange: true, reason: null}})

        function setWifiEnabled(value) {
            wifiEnabled = value === true;
            calls += 1;
            return true;
        }

        function action(operation, value) {
            if (rejected) return {ok: false, code: "permission-denied", message: "Wi-Fi change rejected"};
            const accepted = operation === "set-wifi" && setWifiEnabled(value === "on");
            return {ok: accepted, code: accepted ? "ok" : "failed"};
        }
    }

    QtObject {
        id: bluetoothProvider

        property bool enabled: true
        property int calls: 0
        property bool rejected: false
        property string rejectionCode: "permission-denied"
        property var json: ({errorCode: "", busy: false, capability: {canChange: true, reason: null}})

        function setBluetoothEnabled(value) {
            enabled = value === true;
            calls += 1;
            return true;
        }

        function action(operation, value) {
            if (rejected) return {ok: false, code: rejectionCode, message: "Bluetooth change rejected"};
            const accepted = operation === "set-enabled" && setBluetoothEnabled(value === "on");
            return {ok: accepted, code: accepted ? "ok" : "failed"};
        }
    }

    QtObject {
        id: brightnessProvider

        property int calls: 0
        property int value: 0

        property bool rejected: false
        property var json: ({errorCode: "", busy: false, capability: {canChange: true, reason: null}})
        function action(operation, next) {
            return {ok: !rejected && setBrightness(Number(next)), code: rejected ? "busy" : "ok", message: rejected ? "brightness action rejected" : ""};
        }
        function setBrightness(next) {
            value = next;
            calls += 1;
            return true;
        }
    }

    Popouts.SystemPopoutController {
        id: controller

        audioCanChange: true
        micCanChange: true
        audioProvider: audioProvider
        networkCanChange: true
        networkProvider: networkProvider
        bluetoothCanChange: true
        bluetoothProvider: bluetoothProvider
        brightnessCanChange: true
        brightnessProvider: brightnessProvider
        actions: [{
            "id": "mic-toggle",
            "label": "Mute mic",
            "command": "/fallback/mic-toggle"
        }, {
            "id": "network-toggle",
            "label": "Disable Wi-Fi",
            "command": "/fallback/wifi"
        }, {
            "id": "bluetooth-toggle",
            "label": "Disable Bluetooth",
            "command": "/fallback/bluetooth"
        }]

        onActionRequested: (command) => {
            testCase.actionReceived = true;
            testCase.receivedCommand = command;
        }
    }

    Window {
        id: feedbackWindow

        width: 360
        height: 520
        visible: true

        Popouts.SystemPopout {
            id: popout

            anchors.fill: parent
            opacity: 0
            mode: "network"
            networkCanChange: false
            networkProvider: networkProvider
        }
    }

    function init() {
        audioProvider.rejected = false; networkProvider.rejected = false; bluetoothProvider.rejected = false; bluetoothProvider.rejectionCode = "permission-denied"; brightnessProvider.rejected = false;
        audioProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        networkProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        bluetoothProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        brightnessProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        controller.actionError = ""; controller.pendingActions = []; controller.actionErrorProvider = null; controller.actionErrorCode = "";
        actionReceived = false;
        receivedCommand = "";
        audioProvider.volume = 0;
        audioProvider.muted = false;
        audioProvider.micMuted = false;
        audioProvider.volumeCalls = 0;
        audioProvider.muteCalls = 0;
        audioProvider.micCalls = 0;
        controller.visualAudioVolume = 0;
        networkProvider.wifiEnabled = true;
        networkProvider.calls = 0;
        bluetoothProvider.enabled = true;
        bluetoothProvider.calls = 0;
        controller.networkEnabled = true;
        controller.bluetoothEnabled = true;
        brightnessProvider.calls = 0;
        brightnessProvider.value = 0;
        controller.visualBrightnessPercent = 0;
    }

    function cleanupTestCase() {
        feedbackWindow.close();
    }

    function test_audio_actions_use_the_structured_provider() {
        controller.visualAudioVolume = 73;
        controller.applyAudio();
        compare(audioProvider.volume, 73);
        compare(audioProvider.volumeCalls, 1);
        verify(!actionReceived);

        controller.toggleAudio();
        verify(audioProvider.muted);
        compare(audioProvider.muteCalls, 1);
        verify(!actionReceived);
    }

    function test_microphone_selector_and_action_use_the_structured_provider() {
        controller.setMicMuted(true);
        verify(audioProvider.micMuted);
        compare(audioProvider.micCalls, 1);
        verify(!actionReceived);

        controller.micMuted = true;
        controller.runLabel("mute mic", true);
        verify(!audioProvider.micMuted);
        compare(audioProvider.micCalls, 2);
        verify(!actionReceived);
    }

    function test_connectivity_actions_use_the_structured_providers() {
        controller.setNetworkEnabled(false);
        verify(!networkProvider.wifiEnabled);
        compare(networkProvider.calls, 1);
        verify(!actionReceived);

        controller.setBluetoothEnabled(false);
        verify(!bluetoothProvider.enabled);
        compare(bluetoothProvider.calls, 1);
        verify(!actionReceived);

        controller.networkEnabled = false;
        controller.bluetoothEnabled = false;
        controller.runLabel("Disable Wi-Fi", true);
        controller.runLabel("Disable Bluetooth", true);
        verify(networkProvider.wifiEnabled);
        verify(bluetoothProvider.enabled);
        compare(networkProvider.calls, 2);
        compare(bluetoothProvider.calls, 2);
        verify(!actionReceived);
    }

    function test_brightness_action_uses_the_structured_provider() {
        controller.visualBrightnessPercent = 71;
        controller.applyBrightness();
        compare(brightnessProvider.value, 71);
        compare(brightnessProvider.calls, 1);
        verify(!actionReceived);
    }
    function test_rejected_owner_actions_never_run_script_fallback() {
        actionReceived = false;
        audioProvider.rejected = true; networkProvider.rejected = true; bluetoothProvider.rejected = true; brightnessProvider.rejected = true;
        controller.toggleAudio();
        verify(!controller.setMicMuted(true));
        controller.runLabel("mute mic", true);
        compare(controller.actionError, "Microphone action is already in progress");
        verify(!actionReceived);
        audioProvider.rejected = false;
        controller.runLabel("mute mic", true);
        compare(controller.actionError, "");
        verify(!controller.setNetworkEnabled(false));
        verify(!controller.setBluetoothEnabled(false));
        controller.applyAudio(); controller.applyBrightness();
        verify(!actionReceived);
        compare(controller.actionError, "Brightness action is already in progress");
        audioProvider.rejected = false; networkProvider.rejected = false; bluetoothProvider.rejected = false; brightnessProvider.rejected = false;
    }

    function test_disabled_capabilities_show_the_provider_reason() {
        controller.mode = "network";
        controller.networkCanChange = false;
        networkProvider.json = ({errorCode: "no-wifi-hardware", busy: false, capability: {canChange: false, reason: "no-wifi-hardware"}});
        compare(controller.disabledReason(), "No Wi-Fi hardware is available");

        controller.mode = "audio";
        controller.audioCanChange = true;
        controller.micCanChange = false;
        compare(controller.disabledReason(), "Default microphone is unavailable");
    }

    function test_async_provider_failure_is_visible_and_clears_on_recovery() {
        networkProvider.json = ({errorCode: "", busy: true, capability: {canChange: true, reason: null}});
        verify(controller.setNetworkEnabled(false));
        compare(controller.actionError, "");

        networkProvider.json = ({errorCode: "timeout", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "Wi-Fi action timed out");

        networkProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "");
    }

    function test_overlapping_provider_actions_keep_their_async_feedback() {
        networkProvider.json = ({errorCode: "", busy: true, capability: {canChange: true, reason: null}});
        verify(controller.setNetworkEnabled(false));
        bluetoothProvider.json = ({errorCode: "", busy: true, capability: {canChange: true, reason: null}});
        verify(controller.setBluetoothEnabled(false));

        networkProvider.json = ({errorCode: "timeout", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "Wi-Fi action timed out");
        bluetoothProvider.json = ({errorCode: "timeout", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "Bluetooth action timed out");

        networkProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "Bluetooth action timed out");
        bluetoothProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "");
    }

    function test_busy_rejection_does_not_detach_an_accepted_action() {
        networkProvider.json = ({errorCode: "", busy: true, capability: {canChange: true, reason: null}});
        verify(controller.setNetworkEnabled(false));

        bluetoothProvider.rejected = true;
        bluetoothProvider.rejectionCode = "busy";
        verify(!controller.setBluetoothEnabled(false));
        compare(controller.actionError, "Bluetooth action is already in progress");

        networkProvider.json = ({errorCode: "timeout", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "Wi-Fi action timed out");
        networkProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "");
    }

    function test_immediate_permission_rejection_clears_when_capability_recovers() {
        bluetoothProvider.rejected = true;
        bluetoothProvider.json = ({errorCode: "permission-denied", busy: false, capability: {canChange: false, reason: "permission-denied"}});
        verify(!controller.setBluetoothEnabled(false));
        compare(controller.actionError, "Permission denied");

        bluetoothProvider.rejected = false;
        bluetoothProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "");
    }

    function test_brightness_query_failure_is_not_reported_as_an_action_failure() {
        brightnessProvider.json = ({errorCode: "", busy: true, capability: {canChange: true, reason: null}});
        verify(controller.applyBrightness());
        compare(controller.actionError, "");

        brightnessProvider.json = ({errorCode: "query-timeout", busy: true, capability: {canChange: false, reason: "device-unavailable"}});
        compare(controller.actionError, "");
        brightnessProvider.json = ({errorCode: "query-timeout", busy: false, capability: {canChange: false, reason: "device-unavailable"}});
        compare(controller.actionError, "");
        controller.mode = "brightness";
        controller.brightnessCanChange = false;
        compare(controller.disabledReason(), "Control device is unavailable");

        controller.brightnessCanChange = true;
        brightnessProvider.json = ({errorCode: "", busy: true, capability: {canChange: true, reason: null}});
        verify(controller.applyBrightness());
        brightnessProvider.json = ({errorCode: "action-timeout", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "Brightness action timed out");
        brightnessProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(controller.actionError, "");
    }

    function test_popout_feedback_text_reports_action_error_and_disabled_reason() {
        const feedback = findChild(popout, "systemFeedbackMessage");
        verify(feedback !== null);

        popout.actionError = "Wi-Fi action timed out";
        compare(popout.actionError, "Wi-Fi action timed out");
        compare(feedback.text, "Wi-Fi action timed out");
        compare(feedback.visible, true);

        popout.actionError = "";
        networkProvider.json = ({errorCode: "no-wifi-hardware", busy: false, capability: {canChange: false, reason: "no-wifi-hardware"}});
        compare(feedback.visible, true);
        compare(feedback.text, "No Wi-Fi hardware is available");

        popout.networkCanChange = true;
        networkProvider.json = ({errorCode: "", busy: false, capability: {canChange: true, reason: null}});
        compare(feedback.visible, false);
    }
}
