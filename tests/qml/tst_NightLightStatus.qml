import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    name: "NightLightStatus"
    Services.NightLightStatus { id: owner }
    function init() {
        owner.scriptRoot = "";
        findChild(owner, "nightLightProbe").running = false;
        findChild(owner, "nightLightWriter").running = false;
        owner.startupReconciled = false; owner.startupResult = null; owner.observed = false;
    }
    function test_saved_mode_reconciles_once_after_successful_probe() {
        owner.acceptState({mode: "auto", available: true, active: false});
        verify(owner.reconcileSavedMode());
        const writer = findChild(owner, "nightLightWriter");
        verify(writer.running);
        compare(writer.command[writer.command.length - 2], "auto");
        compare(writer.command[writer.command.length - 1], "--quiet");
        writer.running = false;
        owner.acceptState({mode: "auto", available: true, active: false});
        verify(!owner.reconcileSavedMode());
        verify(!writer.running);
    }
    function test_busy_denial_does_not_retry_startup_or_dispatch_second_write() {
        owner.acceptState({mode: "off", available: true, active: false});
        verify(owner.action("set", "on").ok);
        compare(owner.action("toggle", "").code, "busy");
        verify(!owner.reconcileSavedMode());
        findChild(owner, "nightLightWriter").running = false;
        verify(!owner.reconcileSavedMode());
    }
    function test_invalid_and_unavailable_requests_do_not_dispatch() {
        compare(owner.action("unknown", "on").code, "invalid-data");
        owner.acceptState({mode: "off", available: false, active: false});
        compare(owner.action("toggle", "").code, "unavailable");
        verify(!findChild(owner, "nightLightWriter").running);
    }
    function test_toggle_from_off_identity_profile_enables_filter() {
        owner.acceptState({mode: "off", available: true, active: false});
        verify(owner.action("toggle", "").ok);
        const writer = findChild(owner, "nightLightWriter");
        compare(writer.command[writer.command.length - 1], "on");
        verify(writer.command.indexOf("--quiet") < 0);
    }
}
