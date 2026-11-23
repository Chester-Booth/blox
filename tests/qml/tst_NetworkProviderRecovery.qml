import QtQuick
import QtTest
import Quickshell.Networking
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "NetworkProviderRecovery"
    QtObject { id: devices; property var values: [] }
    QtObject { id: networks; property var values: [] }
    QtObject { id: first; property int type: DeviceType.Wifi; property string name: "first"; property bool connected: true; property var networks: networks }
    QtObject { id: second; property int type: DeviceType.Wifi; property string name: "second"; property bool connected: true; property var networks: networks }
    QtObject { id: service; property var devices: devices; property int backend: NetworkBackendType.NetworkManager; property bool wifiEnabled: true; property bool wifiHardwareEnabled: true }
    Services.NetworkManagerProvider { id: provider; networkingService: service; interval: 0; syncReady: true }
    property var probe
    function initTestCase() {
        for (let i = 0; i < provider.data.length; i++)
            if (provider.data[i].sentSignals !== undefined) probe = provider.data[i];
        verify(probe !== undefined);
    }
    function init() {
        probe.running = false;
        first.connected = true;
        second.connected = true;
        devices.values = [first];
        provider.refreshWifiStatus();
    }
    function complete(ssid, signal) {
        provider.pendingWifiStatus = JSON.stringify({ssid:ssid, signal:signal});
        probe.finish(0, 0);
    }
    function test_old_device_reply_is_discarded_and_new_device_reprobed() {
        compare(probe.command[2], "first");
        devices.values = [second];
        complete("First network", 88);
        compare(provider.measuredWifiSsid, "");
        compare(provider.measuredWifiSignal, 0);
        tryCompare(probe, "running", true);
        compare(probe.command[2], "second");
        complete("Second network", 63);
        compare(provider.json.ssid, "Second network");
    }
    function test_disconnect_reconnect_discards_old_connection_reply() {
        first.connected = false;
        first.connected = true;
        complete("Old connection", 88);
        compare(provider.measuredWifiSsid, "");
        tryCompare(probe, "running", true);
        complete("Current connection", 44);
        compare(provider.measuredWifiSsid, "Current connection");
    }
    function test_removed_device_is_unavailable_then_recovers() {
        devices.values = [];
        complete("Removed", 90);
        verify(!provider.json.wifiConnected);
        compare(provider.measuredWifiSsid, "");
        devices.values = [second];
        tryCompare(probe, "running", true);
        complete("Returned", 32);
        compare(provider.measuredWifiSsid, "Returned");
    }
    function test_failed_probe_does_not_keep_old_reading() {
        complete("Old reading", 80);
        provider.refreshWifiStatus();
        probe.finish(1, 0);
        compare(provider.measuredWifiSsid, "");
        compare(provider.measuredWifiSignal, 0);
    }
}
