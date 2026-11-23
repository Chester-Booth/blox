import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "VendorPerformanceQueryFailure"
    Component {
        id: provider
        Services.VendorPerformanceProvider { scriptRoot: "/fixture"; interval: 0 }
    }

    function queryFor(owner) {
        for (let i = 0; i < owner.data.length; i++) {
            const object = owner.data[i];
            if (object.command !== undefined && object.sentSignals !== undefined && object.command.length > 0)
                return object;
        }
        fail("Query process not found");
    }

    function poll(owner) {
        for (let i = 0; i < owner.data.length; i++) {
            const object = owner.data[i];
            if (object.repeat === true) {
                object.triggered();
                return;
            }
        }
        fail("Periodic query timer not found");
    }

    function unavailable(owner) {
        owner.applyPayload({vendor: "asusctl", profile: "unavailable", profiles: [],
            errorCode: "query-failed", capability: {available: false, reason: "query-failed"}});
    }

    function success(owner) {
        owner.applyPayload({vendor: "asusctl", profile: "balanced", profiles: ["balanced", "quiet"],
            capability: {available: true}});
    }

    function test_typed_failure_is_reported_and_next_success_recovers() {
        const owner = createTemporaryObject(provider, testCase);
        owner.applyPayload({vendor: "asusctl", profile: "unavailable", profiles: [],
            errorCode: "query-failed", capability: {available: false, reason: "query-failed"}});
        compare(owner.lastError, "query-failed");
        verify(!owner.ok);
        verify(!owner.json.capability.canChange);
        owner.applyPayload({vendor: "asusctl", profile: "balanced", profiles: ["balanced"],
            capability: {available: true}});
        compare(owner.lastError, "");
        verify(owner.ok);
    }

    function test_default_watchdog_allows_three_query_budgets() {
        const owner = createTemporaryObject(provider, testCase);
        verify(owner.queryTimeout >= 8000);
        compare(owner.timeout, 5000);
        owner.refresh();
        let watchdog;
        for (let i = 0; i < owner.data.length; i++) {
            const object = owner.data[i];
            if (object.interval === owner.queryTimeout && object.running === true)
                watchdog = object;
        }
        verify(watchdog !== undefined);
        watchdog.triggered();
        compare(queryFor(owner).sentSignals, [15]);
    }

    function test_typed_failure_backs_off_periodic_ticks_and_explicit_refresh_recovers() {
        const owner = createTemporaryObject(provider, testCase);
        const query = queryFor(owner);
        unavailable(owner);
        verify(owner.retryAfterMs > Date.now());
        poll(owner);
        verify(!query.running);
        owner.refresh();
        verify(query.running);
        owner.pendingRaw = JSON.stringify({vendor: "asusctl", profile: "balanced", profiles: ["balanced"],
            capability: {available: true}});
        query.finish(0, 0);
        compare(owner.retryAfterMs, 0);
        compare(owner.queryFailureCount, 0);
        poll(owner);
        verify(query.running);
    }

    function test_periodic_ticks_while_running_do_not_queue_a_failure_retry() {
        const owner = createTemporaryObject(provider, testCase);
        const query = queryFor(owner);
        poll(owner);
        poll(owner);
        verify(!owner.refreshPending);
        owner.pendingRaw = "{broken";
        query.finish(0, 0);
        wait(1);
        verify(!query.running);
        verify(owner.retryAfterMs > Date.now());
        owner.retryAfterMs = Date.now() - 1;
        poll(owner);
        verify(query.running);
    }

    function test_idle_retry_delay_grows_and_is_bounded() {
        const owner = createTemporaryObject(provider, testCase, {interval: 60000});
        unavailable(owner);
        const first = owner.retryAfterMs;
        verify(first >= Date.now() + 59000);
        unavailable(owner);
        verify(owner.retryAfterMs >= first + 59000);
        for (let i = 0; i < 10; i++)
            unavailable(owner);
        verify(owner.retryAfterMs >= Date.now() + 299000);
        verify(owner.retryAfterMs <= Date.now() + 300000);
        success(owner);
        compare(owner.retryAfterMs, 0);
    }

    function test_explicit_refresh_during_query_is_coalesced_despite_failure() {
        const owner = createTemporaryObject(provider, testCase);
        const query = queryFor(owner);
        owner.refresh();
        owner.refresh();
        owner.refresh();
        verify(owner.refreshPending);
        owner.pendingRaw = "";
        query.finish(1, 0);
        tryCompare(query, "running", true);
        verify(!owner.refreshPending);
        owner.pendingRaw = "";
        query.finish(1, 0);
        wait(1);
        verify(!query.running);
    }

    function test_action_completion_after_query_failure_data() {
        return [
            {tag: "success", code: 0, timedOut: false, error: ""},
            {tag: "failure", code: 1, timedOut: false, error: "action-failed"},
            {tag: "timeout", code: 0, timedOut: true, error: "action-timeout"}
        ];
    }

    function test_action_completion_after_query_failure(row) {
        const owner = createTemporaryObject(provider, testCase);
        const query = queryFor(owner);
        success(owner);
        verify(owner.setProfile("quiet"));
        let action;
        for (let i = 0; i < owner.data.length; i++) {
            const object = owner.data[i];
            if (object.command !== undefined && object.command[1] === "profile-set")
                action = object;
        }
        verify(action !== undefined);
        unavailable(owner);
        verify(owner.retryAfterMs > Date.now());
        owner.actionTimedOut = row.timedOut;
        action.finish(row.code, 0);
        compare(owner.actionError, row.error);
        compare(query.running, row.error.length === 0);
        verify(!owner.actionBusy);
    }
}
