import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "ProviderRecovery"
    Component { id: brightness; Services.BrightnessProvider { scriptRoot: "/fixture"; interval: 0; timeout: 60000 } }
    Component { id: touchpad; Services.TouchpadProvider { scriptRoot: "/fixture"; interval: 0; timeout: 60000 } }
    Component { id: vendor; Services.VendorPerformanceProvider { scriptRoot: "/fixture"; interval: 0; timeout: 60000 } }
    Component { id: gpu; Services.GpuProvider { scriptRoot: "/fixture"; interval: 0; timeout: 60000 } }
    Component { id: monitor; Services.MonitorProvider { scriptRoot: "/fixture"; interval: 0; timeout: 60000 } }

    function test_recovery_data() {
        return [
            {tag: "brightness", component: brightness, payload: {capability: {available: true}, device: "panel", backlights: ["panel"], percent: 40}, method: "setBrightness", args: [50], timeoutCode: "action-timeout"},
            {tag: "touchpad", component: touchpad, payload: {capability: {available: true}, device: "pad", devices: ["pad"], enabled: true}, method: "setEnabled", args: [false], timeoutCode: "action-timeout"},
            {tag: "vendor", component: vendor, payload: {capability: {available: true}, vendor: "asus", profile: "balanced", profiles: ["balanced", "quiet"]}, method: "setProfile", args: ["quiet"], timeoutCode: "action-timeout"},
            {tag: "gpu", component: gpu, payload: {capability: {available: true, canChange: true}, deviceCount: 2, integratedCount: 1, discreteCount: 1, backend: "drm", controller: "supergfxctl", mode: "hybrid", supportedModes: ["hybrid", "integrated"]}, method: "setMode", args: ["integrated", false], timeoutCode: "timeout"},
            {tag: "monitor", component: monitor, payload: {capability: {available: true}, monitors: [{name: "panel", canChange: true, rates: [{id: "60"}]}]}, method: "setRefresh", args: ["panel", "60"], timeoutCode: "timeout"}
        ];
    }

    function processFor(owner, isAction) {
        for (let i = 0; i < owner.data.length; i++) {
            const obj = owner.data[i];
            if (obj.command === undefined || obj.sentSignals === undefined) continue;
            if (isAction ? obj.command.length === 0 : obj.command.length > 0) return obj;
        }
        fail("Process not found");
    }
    function timerFor(owner, duration, active) {
        for (let i = 0; i < owner.data.length; i++) {
            const obj = owner.data[i];
            if (obj.interval === duration && obj.running === active && obj.repeat === false) return obj;
        }
        fail("Timer not found");
    }
    function test_recovery(row) {
        const owner = createTemporaryObject(row.component, testCase);
        verify(owner !== null);
        const query = processFor(owner, false);
        const action = processFor(owner, true);
        owner.applyPayload(row.payload);
        verify(owner.json.capability.canChange);

        // Removal and reappearance reuse the same production provider instance.
        owner.applyPayload({capability: {available: false, reason: "command-unavailable"}});
        verify(!owner.json.capability.canChange);
        verify(!owner[row.method].apply(owner, row.args));
        owner.applyPayload(row.payload);
        verify(owner.json.capability.canChange);
        verify(owner[row.method].apply(owner, row.args));
        verify(action.running);
        timerFor(owner, row.tag === "gpu" ? 180000 : 60000, true).triggered();
        compare(action.sentSignals[0], 15);
        verify(owner.actionTimedOut);

        // A parallel query must neither clear the action timeout nor cancel its kill.
        verify(!query.running);
        owner.refresh();
        owner.pendingRaw = JSON.stringify(row.payload);
        query.finish(0, 0);
        verify(owner.actionTimedOut);
        timerFor(owner, 1000, true).triggered();
        compare(action.sentSignals[1], 9);
        action.finish(0, 0);
        compare(owner.actionError, row.timeoutCode);
        verify(!owner.actionBusy);

        // The next valid discovery recovers typed readiness after a query failure.
        owner.pendingRaw = "{broken";
        query.finish(0, 0);
        compare(owner.queryError, "malformed-status");
        verify(!owner.json.capability.canChange);
        owner.refresh();
        owner.pendingRaw = JSON.stringify(row.payload);
        query.finish(0, 0);
        compare(owner.queryError, "");
        verify(owner.json.capability.canChange);
    }
    function test_query_timeout_does_not_poison_action_data() { return test_recovery_data(); }
    function test_query_timeout_does_not_poison_action(row) {
        const owner = createTemporaryObject(row.component, testCase);
        const query = processFor(owner, false);
        const action = processFor(owner, true);
        owner.applyPayload(row.payload);
        owner.refresh();
        timerFor(owner, 60000, true).triggered();
        verify(owner.queryTimedOut);
        verify(owner[row.method].apply(owner, row.args));
        verify(owner.queryTimedOut);
        verify(!owner.actionTimedOut);
        if (owner.actionRaw !== undefined) owner.actionRaw = row.tag === "brightness" ? "50\n" : JSON.stringify({ok: true, data: {changed: false}});
        action.finish(0, 0);
        compare(owner.actionError, "");
        // The action completion must not cancel an unrelated query escalation.
        timerFor(owner, 1000, true).triggered();
        compare(query.sentSignals[1], 9);
        query.finish(0, 0);
        compare(owner.queryError, "query-timeout");
        verify(!owner.json.capability.canChange);
    }

    function test_unreadable_backlight_remains_visible_but_not_actionable() {
        const owner = createTemporaryObject(brightness, testCase);
        owner.applyPayload({capability: {available: true, canChange: false, reason: "device-unavailable"}, device: "panel", backlights: ["panel"], percent: 0});
        compare(owner.json.device, "panel");
        verify(!owner.json.capability.canChange);
        verify(!owner.setBrightness(40));
        owner.applyPayload({capability: {available: true, canChange: true}, device: "panel", backlights: ["panel"], percent: 50});
        verify(owner.setBrightness(40));
    }

    Component { id: brightnessStatus; Services.BrightnessStatus { scriptRoot: "/fixture"; interval: 0 } }
    SignalSpy { id: brightnessFeedback; signalName: "brightnessApplied" }

    function loadedBrightness(status) {
        tryCompare(status, "providerReady", true);
        for (let i = 0; i < status.data.length; i++) {
            const item = status.data[i].item;
            if (item && item.pendingBrightness !== undefined) return item;
        }
        fail("Brightness provider not found");
    }

    function test_brightness_repeats_accumulate_and_publish_confirmed_values() {
        const status = createTemporaryObject(brightnessStatus, testCase);
        const provider = loadedBrightness(status);
        const action = processFor(provider, true);
        provider.applyPayload({capability: {available: true}, device: "panel", percent: 40});
        brightnessFeedback.target = status;
        brightnessFeedback.clear();
        verify(status.action("adjust", "2").ok);
        verify(status.action("adjust", "2").ok);
        verify(status.action("adjust", "2").ok);
        compare(provider.activeBrightness, "42");
        compare(provider.pendingBrightness, "46");
        compare(status.json.percent, 40);
        provider.actionRaw = "42\n";
        action.finish(0, 0);
        compare(brightnessFeedback.count, 1);
        compare(brightnessFeedback.signalArguments[0][0], 42);
        compare(provider.activeBrightness, "46");
        verify(status.action("adjust", "-2").ok);
        compare(provider.pendingBrightness, "44");
        provider.actionRaw = "46\n";
        action.finish(0, 0);
        compare(provider.activeBrightness, "44");
        provider.actionRaw = "44\n";
        action.finish(0, 0);
        compare(brightnessFeedback.count, 3);
        compare(status.json.percent, 44);
        verify(!provider.actionBusy);
        brightnessFeedback.target = null;
    }

    function test_brightness_busy_queue_preserves_permission_and_stale_denials() {
        const status = createTemporaryObject(brightnessStatus, testCase);
        const provider = loadedBrightness(status);
        provider.applyPayload({capability: {available: true}, device: "panel", percent: 40});
        verify(status.action("adjust", "2").ok);
        const before = status.json;
        status.json = Object.assign({}, before, {capability: {available: true, canChange: true, permission: "denied"}});
        compare(status.action("adjust", "2").code, "permission-denied");
        status.json = Object.assign({}, before, {stale: true});
        compare(status.action("adjust", "2").code, "stale");
        compare(provider.pendingBrightness, "42");
    }

    function test_brightness_old_query_and_malformed_readback_do_not_publish_success() {
        const provider = createTemporaryObject(brightness, testCase);
        const query = processFor(provider, false);
        const action = processFor(provider, true);
        provider.applyPayload({capability: {available: true}, device: "panel", percent: 40});
        provider.refresh();
        verify(provider.setBrightness(50));
        provider.actionRaw = "50\n";
        action.finish(0, 0);
        provider.pendingRaw = JSON.stringify({capability: {available: true}, device: "panel", percent: 40});
        query.finish(0, 0);
        compare(provider.json.percent, 50);
        brightnessFeedback.target = provider;
        brightnessFeedback.clear();
        verify(provider.setBrightness(60));
        provider.actionRaw = "not a percentage";
        action.finish(0, 0);
        compare(provider.actionError, "malformed-action-status");
        compare(provider.json.percent, 50);
        compare(brightnessFeedback.count, 0);
        brightnessFeedback.target = null;
    }

    function test_brightness_query_started_during_write_cannot_rewind_readback() {
        const provider = createTemporaryObject(brightness, testCase);
        const query = processFor(provider, false);
        const action = processFor(provider, true);
        provider.applyPayload({capability: {available: true}, device: "panel", percent: 40});
        verify(provider.setBrightness(60));
        provider.refresh();
        provider.actionRaw = "60\n";
        action.finish(0, 0);
        provider.pendingRaw = JSON.stringify({capability: {available: true}, device: "panel", percent: 40});
        query.finish(0, 0);
        compare(provider.json.percent, 60);
        compare(provider.adjustmentBase, 60);
    }

    function test_hung_gpu_client_query_releases_confirmation_flow() {
        const owner = createTemporaryObject(gpu, testCase);
        owner.applyPayload(test_recovery_data()[3].payload);
        verify(owner.requestMode("integrated"));
        let clients;
        for (let i = 0; i < owner.data.length; i++)
            if (owner.data[i].command !== undefined && owner.data[i].command[1] === "gpu-clients") clients = owner.data[i];
        verify(clients.running);
        timerFor(owner, 60000, true).triggered();
        timerFor(owner, 1000, true).triggered();
        compare(clients.sentSignals, [15, 9]);
        clients.finish(0, 0);
        compare(owner.actionError, "client-query-timeout");
        verify(!owner.actionBusy);
        verify(!owner.confirmationRequired);
        compare(owner.requestedMode, "");
    }

}
