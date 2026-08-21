import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase

    function init() {
        controller.events = [];
        controller.calendars = [];
        controller.popoutNotice = null;
        controller.editorNotice = null;
        controller.deleteNotice = null;
        controller.cancelReconcileRetry();
        controller.error = "";
        controller.detailsOpen = false;
        controller.childPositionReady = false;
        controller.activeEvent = null;
    }

    function event(key, title) {
        return {
            "key": key,
            "title": title,
            "time": {
                "kind": "timed",
                "start_ms": 1,
                "end_ms": 2
            },
            "colour": {
            },
            "calendar": {
                "id": "main"
            },
            "recurrence": {
            },
            "can_edit": true
        };
    }

    function test_parse_requires_valid_envelope() {
        verify(!controller.parseOutput("not json").valid);
        verify(!controller.parseOutput("{}").valid);
        var parsed = controller.parseOutput('{"ok":false,"error":{"message":"failed"}}');
        verify(parsed.valid);
        verify(!parsed.response.ok);
    }

    function test_restore_is_scoped_to_one_event() {
        var first = event("main:first", "Before");
        var second = event("main:second", "Other");
        var optimistic = event("main:first", "After");
        optimistic.pending = true;
        optimistic.busy = true;
        controller.events = [optimistic, second];
        controller.restoreItem({
            "eventKey": first.key,
            "rollback": first
        });
        compare(controller.eventByKey(first.key).title, "Before");
        verify(!controller.eventByKey(first.key).pending);
        compare(controller.eventByKey(second.key).title, "Other");
    }

    function test_snapshot_data_does_not_replace_busy_event() {
        var pending = event("main:first", "Optimistic");
        pending.pending = true;
        pending.busy = true;
        controller.events = [pending];
        controller.applyData({
            "revision": 2,
            "data": {
                "events": [event("main:first", "Provider")],
                "calendars": []
            }
        });
        compare(controller.eventByKey(pending.key).title, "Optimistic");
        verify(controller.eventByKey(pending.key).busy);
    }

    function test_switching_detail_events_keeps_window_ready() {
        var first = event("main:first", "First");
        var second = event("main:second", "Second");
        controller.showDetails(first);
        controller.childPositionReady = true;

        controller.showDetails(second);

        verify(controller.detailsOpen);
        verify(controller.childPositionReady);
        compare(controller.activeEvent.key, second.key);
    }

    function test_range_refresh_keeps_events_outside_the_range() {
        var first = event("main:first", "First day");
        first.time.start_ms = new Date("2026-08-13T09:00:00Z").getTime();
        first.time.end_ms = new Date("2026-08-13T10:00:00Z").getTime();
        var second = event("main:second", "Second day");
        second.time.start_ms = new Date("2026-08-14T09:00:00Z").getTime();
        second.time.end_ms = new Date("2026-08-14T10:00:00Z").getTime();
        controller.events = [first, second];
        controller.applyData({
            "revision": 2,
            "data": {
                "events": [],
                "calendars": [],
                "refreshed_calendar_ids": ["main"]
            }
        }, {
            "start": "2026-08-13T00:00:00Z",
            "end": "2026-08-14T00:00:00Z"
        });
        compare(controller.events.length, 1);
        compare(controller.events[0].key, second.key);
    }

    function test_failures_are_scoped_to_the_action_surface() {
        controller.setFailure({
            "command": "create",
            "surface": "editor"
        }, {
            "code": "provider_error",
            "retryable": true
        }, null);
        verify(controller.editorNotice !== null);
        compare(controller.editorNotice.heading, "Event wasn’t created");
        compare(controller.editorNotice.detail, "Your details are still here. Check the connection, then try again.");
        compare(controller.popoutNotice, null);
        compare(controller.deleteNotice, null);
    }

    function test_failed_reconciliation_is_queued_for_connectivity_retry() {
        var original = {
            "command": "update",
            "surface": "popout",
            "eventKey": "main:first",
            "payload": {
            }
        };
        var retry = {
            "command": "reconcile",
            "surface": "popout",
            "original": original,
            "payload": {
            }
        };
        controller.scheduleReconcileRetry(retry);
        compare(controller.pendingReconcileRetries.length, 1);
        compare(controller.pendingReconcileRetries[0].command, "reconcile");
        compare(controller.pendingReconcileRetries[0].reconcileAttempt, 1);
        verify(controller.pendingReconcileRetries[0].nextRetryAt > Date.now());
        var second = Object.assign({
        }, retry, {
            "original": Object.assign({
            }, original, {
                "eventKey": "main:second"
            })
        });
        controller.scheduleReconcileRetry(second);
        compare(controller.pendingReconcileRetries.length, 2);
    }

    name: "CalendarController"

    Services.CalendarController {
        id: controller

        scriptRoot: "/nonexistent"
        automaticRefresh: false
    }

}
