import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "NetworkState"

    Services.NetworkState {
        id: state

        providerReady: true
        syncReady: true
        backendAvailable: true
        wifiEnabled: true
        wifiHardwareEnabled: true
        wifiConnected: true
        wifiSsid: "Home"
        wifiSignal: 78
        wifiDevice: "wlp2s0"
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.backendAvailable = true;
        state.wifiEnabled = true;
        state.wifiHardwareEnabled = true;
        state.wifiConnected = true;
        state.wifiSsid = "Home";
        state.wifiSignal = 78;
        state.wifiDevice = "wlp2s0";
        state.wiredConnected = false;
        state.wiredName = "";
        state.wiredDevice = "";
        state.busy = false;
        state.actionError = "";
    }

    function test_connected_wifi_is_typed() {
        compare(state.json.class, "wifi");
        compare(state.json.summary, "Home");
        compare(state.json.signal, 78);
        compare(state.json.device, "wlp2s0");
        compare(state.json.wifiEnabled, true);
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
        compare(state.json.capability.reason, null);
    }

    function test_disabled_wifi_is_available_but_not_connected() {
        state.wifiEnabled = false;
        state.wifiConnected = false;
        compare(state.json.class, "disabled");
        compare(state.json.summary, "Wi-Fi disabled");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
    }

    function test_missing_wifi_hardware_is_not_actionable() {
        state.wifiHardwareEnabled = false;
        compare(state.json.class, "unavailable");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "no-wifi-hardware");
    }

    function test_loading_and_backend_loss_are_distinct() {
        state.syncReady = false;
        verify(state.json.capability.available);
        verify(!state.json.capability.ready);
        compare(state.json.capability.reason, "provider-loading");
        state.syncReady = true;
        state.backendAvailable = false;
        verify(!state.json.capability.available);
        verify(!state.json.capability.ready);
        compare(state.json.capability.reason, "backend-unavailable");
    }

    function test_wired_connection_is_projected_without_wifi_details() {
        state.wiredConnected = true;
        state.wiredName = "Office LAN";
        state.wiredDevice = "enp1s0";
        compare(state.json.class, "wired");
        compare(state.json.summary, "Office LAN");
        compare(state.json.details, "Connected via enp1s0");
    }

    function test_action_error_and_busy_are_typed() {
        state.busy = true;
        state.actionError = "timeout";
        verify(state.json.busy);
        compare(state.json.errorCode, "timeout");
        verify(state.json.details.indexOf("Action error: timeout") >= 0);
    }
}
