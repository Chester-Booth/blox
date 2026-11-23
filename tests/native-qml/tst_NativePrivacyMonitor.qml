import QtQuick
import QtTest
import Blox.Services 1.0

TestCase {
    name: "NativePrivacyMonitor"

    NativePrivacyMonitor {
        id: monitor
        enabled: true
    }

    function test_exposes_typed_privacy_contract() {
        verify(monitor.json !== undefined);
        compare(typeof monitor.json.icon, "string");
        compare(typeof monitor.json.active, "boolean");
        compare(typeof monitor.json.microphoneCount, "number");
        compare(typeof monitor.json.videoCount, "number");
        compare(typeof monitor.json.details, "string");
        verify(monitor.json.capability !== undefined);
        compare(monitor.json.capability.canChange, false);
        monitor.refresh();
        monitor.enabled = false;
        compare(monitor.enabled, false);
    }
}
