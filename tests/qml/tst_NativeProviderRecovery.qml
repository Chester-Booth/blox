import QtQuick
import QtTest
import Quickshell.Services.UPower
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "NativeProviderRecovery"
    QtObject { id: nodes; property var values: [] }
    QtObject { id: audio; property real volume: 0.5; property bool muted: false }
    QtObject { id: sink; property var audio: audio; property bool ready: true; property string description: "Sink"; property string name: "sink" }
    QtObject { id: pipewire; property bool ready: true; property var nodes: nodes; property var defaultAudioSink: sink; property var defaultAudioSource: sink }
    QtObject { id: btDevices; property var values: [] }
    QtObject { id: adapter; property bool enabled: true; property int state: 99 }
    QtObject { id: bluetooth; property var defaultAdapter: adapter; property var devices: btDevices }
    QtObject { id: powerDevices; property var values: [] }
    QtObject { id: battery; property bool isPresent: true; property int type: UPowerDeviceType.Battery; property int state: UPowerDeviceState.Discharging; property real percentage: 0.6; property string model: "Battery"; property string nativePath: "battery" }
    QtObject { id: upower; property var displayDevice: battery; property var devices: powerDevices; property bool onBattery: true }
    QtObject { id: profiles; property bool hasPerformanceProfile: true; property int profile: PowerProfile.Balanced; property string degradationReason: "none" }
    Services.PipewireAudioProvider { id: audioProvider; pipewireService: pipewire }
    Services.BluezProvider { id: btProvider; bluetoothService: bluetooth; syncReady: true; interval: 0 }
    Services.UPowerProvider { id: powerProvider; upowerService: upower; syncReady: true; interval: 0 }
    Services.PowerProfilesProvider { id: profileProvider; profilesService: profiles; upowerService: upower; syncReady: true; interval: 0 }
    function test_pipewire_loss_blocks_actions_and_reappearance_recovers() {
        verify(audioProvider.canChange);
        audioProvider.pipewireService = null;
        verify(!audioProvider.canChange);
        verify(!audioProvider.setVolume(25));
        audioProvider.pipewireService = pipewire;
        verify(audioProvider.setVolume(25));
        compare(audio.volume, 0.25);
    }
    function test_bluez_adapter_removal_and_return() {
        verify(btProvider.json.capability.canChange);
        bluetooth.defaultAdapter = null;
        verify(!btProvider.json.capability.canChange);
        verify(!btProvider.setBluetoothEnabled(false));
        bluetooth.defaultAdapter = adapter;
        verify(btProvider.setBluetoothEnabled(false));
        compare(adapter.enabled, false);
        btProvider.bluetoothService = null;
        verify(!btProvider.json.capability.available);
        btProvider.bluetoothService = bluetooth;
        verify(btProvider.json.capability.canChange);
    }
    function test_upower_battery_removal_ac_only_and_daemon_return() {
        verify(powerProvider.json.capability.ready);
        battery.isPresent = false;
        compare(powerProvider.json.batteryPresent, false);
        verify(powerProvider.json.capability.ready);
        powerProvider.upowerService = null;
        verify(!powerProvider.json.capability.ready);
        battery.isPresent = true;
        powerProvider.upowerService = upower;
        compare(powerProvider.json.batteryPresent, true);
    }
    function test_profile_service_removal_and_return() {
        profileProvider.acceptProfileDiscovery(JSON.stringify({type:"aa{sv}", data:[{Profile:{type:"s", data:"balanced"}}, {Profile:{type:"s",data:"power-saver"}}]}));
        verify(profileProvider.json.capability.canChange);
        profileProvider.profilesService = null;
        verify(!profileProvider.setProfile("power-saver"));
        verify(!profileProvider.json.capability.available);
        profileProvider.profilesService = profiles;
        profileProvider.acceptProfileDiscovery(JSON.stringify({type:"aa{sv}", data:[{Profile:{type:"s", data:"balanced"}}, {Profile:{type:"s",data:"power-saver"}}]}));
        verify(profileProvider.setProfile("power-saver"));
        compare(profiles.profile, PowerProfile.PowerSaver);
    }
}
