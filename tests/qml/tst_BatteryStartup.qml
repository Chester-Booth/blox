import QtQuick
import QtTest
import "../../shell/services" as Services
import "../../shell/shared" as Shared

TestCase {
    name: "BatteryStartup"
    Component { id: nativeStatus; Services.PowerStatus {} }
    Component { id: fakeStatus; Services.PowerStatus { providerSource: Qt.resolvedUrl("fixtures/FakePowerProvider.qml") } }
    Shared.BatteryCapacityTile { id: capacityTile }

    function activationFor(owner) {
        for (const child of owner.data)
            if (child.objectName === "upower-activation") return child;
        fail("UPower activation process missing");
    }

    function test_native_startup_requests_dbus_activation() {
        const owner = createTemporaryObject(nativeStatus, this);
        verify(owner !== null);
        const activation = activationFor(owner);
        verify(activation.running);
        compare(activation.command.slice(-4), ["StartServiceByName", "su", "org.freedesktop.UPower", "0"]);
        verify(!owner.nativeActivated);
        verify(owner.json.stale);
        compare(owner.json.capacity, "");
    }

    function test_injected_provider_does_not_start_system_service() {
        const owner = createTemporaryObject(fakeStatus, this);
        verify(owner !== null);
        verify(!activationFor(owner).running);
        tryCompare(owner, "providerReady", true);
        compare(owner.json.capacity, 72);
    }

    function test_unknown_capacity_is_blank_and_real_zero_is_visible() {
        for (const value of [undefined, null, "", "invalid"] ) {
            capacityTile.status = {capacity: value};
            compare(capacityTile.displayCapacity(), "");
        }
        capacityTile.status = {capacity: 0};
        compare(capacityTile.displayCapacity(), "0");
        capacityTile.status = {capacity: 89};
        compare(capacityTile.displayCapacity(), "89");
    }
}
