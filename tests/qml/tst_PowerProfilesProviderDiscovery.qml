import QtQuick
import QtTest
import Quickshell.Services.UPower
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "PowerProfilesProviderDiscovery"
    QtObject { id: profiles; property bool hasPerformanceProfile: false; property int profile: PowerProfile.Balanced; property string degradationReason: "none" }
    Component { id: component; Services.PowerProfilesProvider { profilesService: profiles; upowerService: null; interval: 0 } }
    function process(owner) {
        for (let i = 0; i < owner.data.length; i++)
            if (owner.data[i].sentSignals !== undefined) return owner.data[i];
        fail("Discovery process missing");
    }
    function availabilityFixture(owner) {
        const guard = findChild(owner, "power-profile-service-availability");
        const fixture = findChild(guard, "native-service-owner-fixture");
        verify(fixture, "Native owner fixture missing");
        guard.enabled = true;
        return fixture;
    }
    function output(names) {
        return JSON.stringify({type:"aa{sv}", data:names.map(name => ({Profile:{type:"s", data:name}}))});
    }
    function test_balanced_only_daemon_is_actionable_without_performance() {
        const owner = createTemporaryObject(component, testCase);
        const query = process(owner);
        owner.refreshProfileDiscovery();
        owner.discoveryRaw = output(["power-saver", "balanced"]);
        query.finish(0, 0);
        verify(owner.json.capability.canChange);
        compare(owner.json.profiles, ["power-saver", "balanced"]);
        verify(!owner.setProfile("performance"));
        verify(owner.setProfile("power-saver"));
        compare(profiles.profile, PowerProfile.PowerSaver);
    }
    function test_daemon_loss_legacy_retry_and_return() {
        const owner = createTemporaryObject(component, testCase);
        const query = process(owner);
        owner.refreshProfileDiscovery();
        owner.discoveryRaw = output(["balanced", "performance"]);
        query.finish(0, 0);
        verify(owner.json.capability.canChange);
        owner.refreshProfileDiscovery();
        query.finish(1, 0);
        verify(query.running);
        compare(query.command[4], "net.hadess.PowerProfiles");
        query.finish(1, 0);
        compare(owner.json.profiles, []);
        verify(!owner.json.capability.canChange);
        verify(!owner.setProfile("balanced"));
        owner.refreshProfileDiscovery();
        owner.discoveryRaw = output(["balanced"]);
        query.finish(0, 0);
        verify(owner.json.capability.canChange);
        compare(owner.json.profiles, ["balanced"]);
    }
    function test_malformed_and_hung_discovery_disable_actions() {
        const owner = createTemporaryObject(component, testCase);
        const query = process(owner);
        owner.refreshProfileDiscovery();
        owner.discoveryRaw = "{}";
        query.finish(0, 0);
        verify(!owner.json.capability.canChange);
        owner.refreshProfileDiscovery();
        for (let i = 0; i < owner.data.length; i++)
            if (owner.data[i].interval === owner.discoveryTimeout) owner.data[i].triggered();
        compare(query.sentSignals[0], 15);
        owner.discoveryRaw = output(["balanced"]);
        query.finish(0, 0);
        verify(!owner.json.capability.canChange);
    }
    function test_owner_loss_masks_cached_profile_without_waiting_for_poll_and_return_rediscovers() {
        const owner = createTemporaryObject(component, testCase);
        const query = process(owner);
        owner.interval = 60000;
        owner.refreshProfileDiscovery();
        owner.discoveryRaw = output(["balanced", "performance"]);
        query.finish(0, 0);
        verify(owner.json.capability.canChange);
        const probe = availabilityFixture(owner);
        probe.setOwner(":1.23");
        owner.discoveryRaw = output(["balanced", "performance"]);
        query.finish(0, 0);
        owner.discoveryRaw = output(["balanced", "performance"]);
        query.finish(0, 0);
        verify(owner.json.capability.canChange);
        const revision = owner.json.providerRevision;
        probe.setOwner("");
        verify(!owner.json.capability.canChange);
        compare(owner.json.profileServiceAvailable, false);
        compare(owner.json.profile, "unavailable");
        compare(owner.json.profiles, []);
        verify(owner.json.providerRevision > revision);
        verify(!owner.setProfile("balanced"));
        probe.setOwner(":1.45");
        verify(query.running);
        verify(!owner.json.capability.canChange);
        owner.discoveryRaw = output(["balanced"]);
        query.finish(0, 0);
        if (query.running) {
            owner.discoveryRaw = output(["balanced"]);
            query.finish(0, 0);
        }
        verify(owner.json.capability.canChange);
        compare(owner.json.profiles, ["balanced"]);
    }
    function test_replaced_owner_rejects_old_discovery_result() {
        const owner = createTemporaryObject(component, testCase);
        const query = process(owner);
        const probe = availabilityFixture(owner);
        probe.setOwner(":1.23");
        owner.refreshProfileDiscovery();
        verify(query.running);
        owner.discoveryRaw = output(["balanced"]);
        query.finish(0, 0);
        compare(owner.discoveryOwner, ":1.23");
        owner.refreshProfileDiscovery();
        verify(query.running);
        probe.setOwner(":1.45");
        owner.discoveryRaw = output(["performance"]);
        query.finish(0, 0);
        verify(!owner.json.capability.canChange);
        verify(query.running);
        owner.discoveryRaw = output(["balanced"]);
        query.finish(0, 0);
        compare(owner.json.profiles, ["balanced"]);
        verify(owner.json.capability.canChange);
    }

}
