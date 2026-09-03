import "../../shell/popouts" as Popouts
import QtQuick
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

    Popouts.SystemPopoutController {
        id: controller

        audioCanChange: true
        micCanChange: true
        audioProvider: audioProvider
        actions: [{
            "id": "mic-toggle",
            "label": "Mute mic",
            "command": "/fallback/mic-toggle"
        }]

        onActionRequested: (command) => {
            testCase.actionReceived = true;
            testCase.receivedCommand = command;
        }
    }

    function init() {
        actionReceived = false;
        receivedCommand = "";
        audioProvider.volume = 0;
        audioProvider.muted = false;
        audioProvider.micMuted = false;
        audioProvider.volumeCalls = 0;
        audioProvider.muteCalls = 0;
        audioProvider.micCalls = 0;
        controller.visualAudioVolume = 0;
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
}
