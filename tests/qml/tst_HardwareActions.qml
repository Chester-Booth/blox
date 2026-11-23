import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    name: "HardwareActions"
    Services.BrightnessStatus { id: brightness; providerSource: Qt.resolvedUrl("fixtures/FakeBrightnessProvider.qml") }
    Services.TouchpadStatus { id: touchpad; providerSource: Qt.resolvedUrl("fixtures/FakeTouchpadProvider.qml") }
    Services.VendorPerformanceStatus { id: vendor; providerSource: Qt.resolvedUrl("fixtures/FakeVendorPerformanceProvider.qml") }
    Services.PowerProfileStatus { id: power; providerSource: Qt.resolvedUrl("fixtures/FakePowerProfileProvider.qml") }
    function test_relative_brightness_and_touchpad_use_loaded_provider() {
        tryCompare(brightness, "providerReady", true);
        const before = brightness.json.percent;
        const receipt = brightness.action("adjust", "-5");
        verify(receipt.ok); verify(receipt.data.pending);
        compare(brightness.json.percent, Math.max(0, before - 5));
        const enabled = touchpad.json.enabled;
        verify(touchpad.action("toggle", "").ok);
        compare(touchpad.json.enabled, !enabled);
    }
    function test_owner_denials_preserve_class_and_do_not_mutate() {
        const baseline = brightness.json;
        for (const field of [{busy: true}, {stale: true}, {capability: {available: true, canChange: true, permission: "denied"}}]) {
            brightness.json = Object.assign({}, baseline, field);
            const before = brightness.json.percent;
            const receipt = brightness.action("set", "50");
            verify(!receipt.ok);
            compare(receipt.code, field.busy ? "busy" : field.stale ? "stale" : "permission-denied");
            compare(brightness.json.percent, before);
        }
        brightness.json = baseline;
    }
    function test_unsupported_profiles_and_fan_curves_do_not_dispatch() {
        tryCompare(vendor, "providerReady", true);
        compare(vendor.action("set-profile", "unsupported").code, "invalid-data");
        compare(vendor.action("set-fan-curves", "on").code, "unavailable");
        verify(vendor.action("set-profile", "balanced").ok);
        compare(vendor.json.profile, "balanced");
        tryCompare(power, "providerReady", true);
        compare(power.action("set", "unsupported").code, "invalid-data");
    }
}
