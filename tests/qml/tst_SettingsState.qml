import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "SettingsState"

    Services.SettingsState {
        id: state
    }

    function results() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../fixtures/settings-owner-results.json"), false);
        request.send();
        return JSON.parse(request.responseText);
    }

    function init() {
        state.schemaVersion = 1;
        state.revision = 0;
        state.observedAt = 0;
        state.dirty = false;
        state.conflict = false;
        state.changedComponents = [];
        state.commitState = "not-applicable";
        state.rollbackState = "not-attempted";
        state.error = null;
        state.settings = null;
        state.lastResult = null;
    }

    function test_success_result_is_typed_and_clears_dirty_state() {
        const action = results().success;
        state.markDirty();
        verify(state.validResult(action));
        verify(state.acceptResult(action));
        compare(state.schemaVersion, 1);
        compare(state.revision, 1);
        compare(state.observedAt, 100.5);
        verify(!state.dirty);
        verify(!state.conflict);
        compare(JSON.stringify(state.changedComponents), JSON.stringify(["bar"]));
        compare(state.commitState, "committed");
        compare(state.rollbackState, "not-attempted");
        compare(state.error, null);
        compare(state.settings.bar.layout.position, "right");
    }

    function test_conflict_keeps_dirty_state_and_reports_current_revision() {
        const action = results().conflict;
        state.markDirty();
        verify(state.acceptResult(action));
        compare(state.revision, 1);
        compare(action.code, "conflict");
        verify(state.dirty);
        verify(state.conflict);
        compare(JSON.stringify(state.changedComponents), "[]");
        compare(state.commitState, "not-committed");
        compare(state.error.code, "conflict");
    }

    function test_validation_failure_keeps_dirty_state_and_reports_no_changes() {
        const action = results().validationFailure;
        state.markDirty();
        verify(state.acceptResult(action));
        compare(state.revision, 1);
        compare(action.code, "invalid-data");
        verify(state.dirty);
        verify(!state.conflict);
        compare(JSON.stringify(state.changedComponents), "[]");
        compare(state.commitState, "not-committed");
        compare(state.error.code, "invalid-data");
    }

    function test_malformed_provider_result_is_rejected() {
        verify(!state.acceptResult({"version": 1, "ok": true, "code": "ok", "message": "", "data": {}}));
        compare(state.error.code, "invalid-data");
    }
}
