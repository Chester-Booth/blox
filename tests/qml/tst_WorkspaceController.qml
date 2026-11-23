import QtQuick
import QtTest
import Quickshell
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "WorkspaceController"

    QtObject {
        id: compositor
        property var focusedWorkspace: ({id: 1})
        signal rawEvent(var event)
        signal focusedMonitorChanged()
    }
    Component {
        id: factory
        Services.WorkspaceController { hyprland: compositor; scriptRoot: "/fixture" }
    }
    SignalSpy { id: refreshSpy; signalName: "statusRefreshRequested" }
    SignalSpy { id: privacySpy; signalName: "privacyRefreshRequested" }
    SignalSpy { id: monitorSpy; signalName: "focusedMonitorChanged" }
    property var controller

    function init() {
        compositor.focusedWorkspace = {id: 1};
        Quickshell.detachedCalls = [];
        controller = createTemporaryObject(factory, testCase);
        verify(controller);
        refreshSpy.target = controller;
        privacySpy.target = controller;
        monitorSpy.target = controller;
        refreshSpy.clear(); privacySpy.clear(); monitorSpy.clear();
    }
    function event(name, data) { compositor.rawEvent({name: name, data: data || ""}); }
    function lookupProcess() {
        for (let index = 0; index < controller.data.length; index++) {
            if (typeof controller.data[index].finish === "function") return controller.data[index];
        }
        fail("Missing isolated lookup process");
    }
    function finishLookup(output, code, exitFirst) {
        const lookup = lookupProcess();
        if (exitFirst) lookup.finish(code || 0, 0);
        lookup.stdout.text = JSON.stringify(output || {});
        lookup.stdout.streamFinished();
        if (!exitFirst) lookup.finish(code || 0, 0);
    }

    function test_compositor_burst_requests_one_snapshot_without_a_timer_delay() {
        event("workspace", "2");
        event("workspacev2", "2,work");
        event("activewindow", "code,Source");
        event("activewindowv2", "0xabc");
        event("windowtitle", "0xabc");
        event("windowtitlev2", "0xabc,Source");
        compare(refreshSpy.count, 0);
        tryCompare(refreshSpy, "count", 1);
        event("movewindowv2", "0xabc,3,other");
        tryCompare(refreshSpy, "count", 2);
    }

    function test_events_that_do_not_change_workspace_snapshot_do_not_spawn_refreshes() {
        const unrelated = ["openlayer", "closelayer", "submap", "activelayout", "screencast", "screencastv2",
            "fullscreen", "changefloatingmode", "togglegroup", "bell", "custom"];
        for (let repeat = 0; repeat < 10; repeat++) {
            for (const name of unrelated) event(name, "fixture");
        }
        wait(0);
        compare(refreshSpy.count, 0);
        verify(!controller.statusRefreshQueued);
    }

    function test_recorded_event_counts_preserve_focus_and_skip_capture_noise() {
        // A 30-second observer sample on 20 October 2026. Payloads and timing were discarded.
        const counts = {screencast: 37, screencastv2: 37, custom: 8, closelayer: 7,
            activewindow: 2, activewindowv2: 2, openlayer: 5};
        let observed = 0;
        let snapshots = 0;
        for (const name in counts) {
            for (let index = 0; index < counts[name]; index++) {
                event(name);
                observed++;
                if (name === "activewindow" || name === "activewindowv2") {
                    snapshots++;
                    tryCompare(refreshSpy, "count", snapshots);
                } else {
                    wait(0);
                    compare(refreshSpy.count, snapshots);
                }
            }
        }
        compare(observed, 98);
        compare(refreshSpy.count, 4);
    }

    function test_snapshot_changes_and_recovery_remain_fresh() {
        const relevant = ["workspace", "workspacev2", "createworkspace", "createworkspacev2",
            "destroyworkspace", "destroyworkspacev2", "renameworkspace", "moveworkspace", "moveworkspacev2",
            "activespecial", "activespecialv2", "focusedmon", "focusedmonv2", "monitoradded", "monitoraddedv2",
            "monitorremoved", "monitorremovedv2", "openwindow", "closewindow", "movewindow", "movewindowv2",
            "activewindow", "activewindowv2", "windowtitle", "windowtitlev2", "urgent", "pin", "configreloaded"];
        for (const name of relevant) {
            const previous = refreshSpy.count;
            event(name);
            tryCompare(refreshSpy, "count", previous + 1);
        }
        // Explicit refresh remains available for actions and snapshot recovery.
        controller.refresh();
        compare(refreshSpy.count, relevant.length + 1);
    }

    function test_workspace_arrival_clears_alert_before_queued_snapshot() {
        controller.alertWorkspaceIds = ",2,3,";
        event("workspacev2", "2,named workspace");
        verify(!controller.hasAlert(2));
        verify(controller.hasAlert(3));
        compare(refreshSpy.count, 0);
        tryCompare(refreshSpy, "count", 1);
        event("workspace", "3");
        verify(!controller.hasAlert(3));
    }

    function test_privacy_and_monitor_signals_are_not_delayed_by_snapshot_batching() {
        event("openwindow", "abc,1,code,Source");
        event("closewindow", "abc");
        compare(privacySpy.count, 2);
        compare(refreshSpy.count, 0);
        compositor.focusedMonitorChanged();
        compare(monitorSpy.count, 1);
        tryCompare(refreshSpy, "count", 1);
    }

    function test_urgent_and_focus_lookup_keep_latest_window() {
        const lookup = lookupProcess();
        event("urgent", "abc");
        compare(controller.alertWindowAddress, "0xabc");
        compare(lookup.command, ["python3", "/fixture/workspaces/window-for-address.py", "0xabc"]);
        verify(lookup.running);
        event("activewindowv2", "def");
        compare(controller.pendingLookupAddress, "0xdef");
        finishLookup();
        tryCompare(controller, "pendingLookupAddress", "");
        tryVerify(() => lookup.command[2] === "0xdef");
        verify(lookup.running);
    }

    function test_snapshot_addresses_and_empty_or_invalid_events() {
        const lookup = lookupProcess();
        event("activewindowv2", "");
        event("activewindowv2", "invalid-address");
        verify(!lookup.running);
        event("activewindowv2", "0xabc");
        compare(lookup.command[2], "0xabc");
        compare(controller.normaliseWindowAddress("abc"), "0xabc");
        verify(!controller.focusWindow('abc"; invalid'));
    }

    function test_old_focus_reply_cannot_create_alert_after_workspace_change() {
        event("activewindowv2", "abc");
        compositor.focusedWorkspace = {id: 2};
        event("workspacev2", "2,two");
        event("activewindowv2", "def");
        finishLookup({workspace: 1, address: "0xabc"});
        verify(!controller.hasAlert(1));
        tryVerify(() => lookupProcess().command[2] === "0xdef");
        finishLookup({workspace: 2, address: "0xdef"});
        verify(!controller.hasAlert(1));
        verify(!controller.hasAlert(2));
    }

    function test_new_focus_replaces_pending_request_before_deferred_drain() {
        event("activewindowv2", "abc");
        event("activewindowv2", "def");
        compare(controller.pendingLookupAddress, "0xdef");
        finishLookup();
        event("activewindowv2", "fed");
        compare(lookupProcess().command[2], "0xfed");
        wait(0);
        compare(controller.pendingLookupAddress, "");
    }

    function test_exit_before_stdout_cannot_assign_old_output_to_new_focus() {
        event("activewindowv2", "abc");
        const lookup = lookupProcess();
        lookup.finish(0, 0);
        event("activewindowv2", "def");
        compare(lookup.command[2], "0xabc");
        lookup.stdout.text = JSON.stringify({workspace: 3, address: "0xabc"});
        lookup.stdout.streamFinished();
        verify(!controller.hasAlert(3));
        tryVerify(() => lookup.command[2] === "0xdef");
    }

    function test_urgency_survives_new_focus_and_rejects_mismatched_reply() {
        event("activewindowv2", "abc");
        event("urgent", "def");
        event("activewindowv2", "fed");
        finishLookup({workspace: 3, address: "0xabc"});
        verify(!controller.hasAlert(3));
        tryVerify(() => lookupProcess().command[2] === "0xdef");
        finishLookup({workspace: 2, address: "0xdef"}, 0, true);
        verify(controller.hasAlert(2));
        compare(controller.alertWindowAddress, "0xdef");
        tryVerify(() => lookupProcess().command[2] === "0xfed");
        finishLookup({workspace: 4, address: "0xabc"});
        verify(!controller.hasAlert(4));
    }

    function test_focus_loss_cancels_pending_focus_and_failed_urgency_cannot_alert() {
        event("activewindowv2", "abc");
        event("activewindowv2", "def");
        event("activewindowv2", "");
        compare(controller.pendingLookupAddress, "");
        finishLookup({workspace: 3, address: "0xabc"});
        verify(!controller.hasAlert(3));
        event("urgent", "fed");
        finishLookup({workspace: 4, address: "0xfed"}, 1);
        verify(!controller.hasAlert(4));
    }

    function test_failed_exec_does_not_block_newest_pending_lookup() {
        event("activewindowv2", "abc");
        const lookup = lookupProcess();
        // Process emits runningChanged, without exited or stream completion, on exec failure.
        lookup.running = false;
        event("activewindowv2", "def");
        tryVerify(() => lookup.command[2] === "0xdef");
        verify(lookup.running);
        finishLookup({workspace: 1, address: "0xdef"});
        verify(!controller.activeLookupRequest);
    }

    function test_workspace_change_cancels_already_accepted_focus_alert() {
        controller.items = [{id: 2, active: false, urgent: false}];
        event("activewindowv2", "abc");
        finishLookup({workspace: 2, address: "0xabc"});
        verify(controller.hasAlert(2));
        compare(controller.alertWindowAddress, "");
        compositor.focusedWorkspace = {id: 3};
        event("workspacev2", "3,three");
        verify(!controller.hasAlert(2));
        wait(150);
        compare(Quickshell.detachedCalls.length, 0);
    }

    function test_focus_invalidation_keeps_genuine_urgency_for_same_workspace() {
        event("urgent", "abc");
        finishLookup({workspace: 2, address: "0xabc"});
        verify(controller.hasAlert(2));
        event("activewindowv2", "def");
        finishLookup({workspace: 2, address: "0xdef"});
        compare(controller.alertLookupRequests[2].purpose, "urgent");
        compare(controller.alertWindowAddress, "0xabc");
        compositor.focusedWorkspace = {id: 3};
        event("workspacev2", "3,three");
        verify(controller.hasAlert(2));
    }

    function test_new_focus_cancels_already_accepted_old_focus_alert() {
        controller.items = [{id: 2, active: false, urgent: false}];
        event("activewindowv2", "abc");
        finishLookup({workspace: 2, address: "0xabc"});
        verify(controller.hasAlert(2));
        event("activewindowv2", "def");
        verify(!controller.hasAlert(2));
        finishLookup({workspace: 1, address: "0xdef"});
        wait(150);
        compare(Quickshell.detachedCalls.length, 0);
    }
}
