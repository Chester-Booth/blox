import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    name: "NativeServiceAvailability"

    Component {
        id: probe
        Services.NativeServiceAvailability {
            enabled: false
            service: "org.blox.Proof"
        }
    }

    function test_disabled_wrapper_contract() {
        const guard = createTemporaryObject(probe, this);
        compare(guard.service, "org.blox.Proof");
        compare(guard.alternateService, "");
        verify(guard.available);
        verify(!guard.ready);
        compare(guard.owner, "");
        guard.refresh();
        verify(guard.available);
        verify(!guard.ready);
    }
}
