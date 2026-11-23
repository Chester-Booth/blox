import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "WidgetActionController"
    property var process
    property var edited: []
    property int calendarOpens: 0

    Services.WidgetActionController {
        id: controller
        scriptRoot: "/fixture/scripts"
        workspaceId: 7
        settingsWindow: QtObject {
            function openWidgetEditor(id) { testCase.edited = testCase.edited.concat([id]); return true; }
        }
        openCalendar: function() { testCase.calendarOpens++; return true; }
    }
    function init() {
        process = findChild(controller, "widget-action-process");
        verify(process !== null);
        controller.activeRequest = null;
        process.running = false;
        process.sentSignals = [];
        controller.timeoutMs = 10000;
        controller.validateCommandHost = null;
        edited = [];
        calendarOpens = 0;
        controller.widgetItems = [
            {id: "note", kind: "notes", enabled: true, settings: {}},
            {id: "calendar", kind: "calendar", enabled: true, settings: {}},
            {id: "files", kind: "files", enabled: true, settings: {directory: "/fixture/files"}},
            {id: "shortcut", kind: "shortcuts", enabled: true, settings: {items: [{id: "app", command: ["trusted", "two words"]}]}},
            {id: "music", kind: "music", enabled: true, settings: {}}
        ];
    }
    function cleanup() {
        if (controller.activeRequest) controller.finish(1, 0, "{}");
        process.running = false;
    }
    function complete(output, code) {
        process.stdout.text = output;
        process.finish(code || 0, 0);
        verify(controller.busy);
        process.stdout.streamFinished();
        verify(!controller.busy);
    }
    function test_settings_and_calendar_use_application_apis() {
        verify(controller.dispatch("note", "edit", {command: "bad"}).ok);
        compare(edited, ["note"]);
        verify(controller.dispatch("calendar", "open", {}).ok);
        compare(calendarOpens, 1);
        verify(!process.running);
    }
    function test_shortcut_resolves_current_identity_and_serialises_launches() {
        compare(controller.dispatch("shortcut", "launch", {id: "app", command: ["bad"]}).code, "pending");
        compare(process.command, ["python3", "/fixture/scripts/widgets/action.py"]);
        const input = JSON.parse(controller.activeRequest.input);
        compare(input.payload, {id: "app"});
        compare(input.widget.settings.items[0].command, ["trusted", "two words"]);
        compare(input.workspaceId, 7);
        compare(controller.dispatch("files", "open", {path: "/fixture/files/a"}).code, "busy");
        complete('{"ok":true,"code":"ok","message":""}');
        compare(controller.lastResult.code, "ok");
        controller.widgetItems = controller.widgetItems.filter(item => item.id !== "shortcut");
        compare(controller.dispatch("shortcut", "launch", {id: "app"}).code, "unavailable");
        verify(!process.running);
    }
    function test_invalid_unsupported_and_provider_actions_do_not_start_process() {
        compare(controller.dispatch("shortcut", "launch", {id: "missing"}).code, "invalid-data");
        compare(controller.dispatch("note", "launch", {command: ["bad"]}).code, "unsupported");
        compare(controller.dispatch("music", "playPause", {}).code, "provider-managed");
        compare(controller.dispatch("files", "open", {path: 5}).code, "invalid-data");
        verify(!process.running);
    }
    function test_timeout_and_malformed_completion_release_busy_state() {
        controller.dispatch("files", "open", {path: "/fixture/files/a"});
        complete("invalid");
        compare(controller.lastResult.code, "failed");
        controller.dispatch("files", "open", {path: "/fixture/files/a"});
        controller.timedOut = true;
        complete('{"ok":true,"code":"ok","message":""}');
        compare(controller.lastResult.code, "timeout");
    }
    function test_timeout_terminates_then_kills_before_accepting_more_work() {
        controller.timeoutMs = 1;
        controller.dispatch("files", "open", {path: "/fixture/files/a"});
        tryCompare(controller, "timedOut", true);
        compare(process.sentSignals, [15]);
        compare(controller.dispatch("shortcut", "launch", {id: "app"}).code, "busy");
        findChild(controller, "widget-action-kill-timeout").triggered();
        compare(process.sentSignals, [15, 9]);
        complete('{"ok":true,"code":"ok","message":""}');
        compare(controller.lastResult.code, "timeout");
    }

    function commandFixture() {
        const item = {id:"command", kind:"command", enabled:true,
            settings:{actions:{left:{kind:"run", command:["finite"]},
                right:{kind:"launch", command:["current-app", "literal ; arg"]}}}};
        controller.widgetItems = controller.widgetItems.concat([item]);
        return {widgetId:"command", consumerId:"host-7", generation:12, button:"right"};
    }
    function sourceContext() { return {outputName:"DP-2", workspace:{id:4, name:"4", special:false}}; }
    function test_command_resolves_binding_and_requires_fixed_host_callback() {
        const identity = commandFixture();
        const context = sourceContext();
        compare(controller.dispatch("command", "activate", identity, context).code, "unavailable");
        verify(!process.running);
        let calls = 0;
        controller.validateCommandHost = function(id, origin) {
            calls++;
            compare(id, identity); compare(origin, context); return true;
        };
        compare(controller.dispatch("command", "activate", identity, context).code, "pending");
        compare(calls, 2);
        const input = JSON.parse(controller.activeRequest.input);
        compare(input.payload, {button:"right"}); compare(input.identity, identity);
        compare(input.hostContext, context);
        compare(input.widget.settings.actions.right.command, ["current-app", "literal ; arg"]);
        context.workspace.id = 99; identity.button = "left";
        compare(JSON.parse(controller.activeRequest.input).hostContext.workspace.id, 4);
        compare(controller.dispatch("command", "activate", identity, sourceContext()).code, "busy");
        complete('{"ok":true,"code":"ok","message":""}');
        compare(controller.lastResult.identity, {widgetId:"command",consumerId:"host-7",generation:12,button:"right"});
    }
    function test_command_rejects_run_payload_argv_disabled_and_unsupported_workspace() {
        const identity = commandFixture(); controller.validateCommandHost = function() { return true; };
        const left = Object.assign({}, identity, {button:"left"});
        compare(controller.dispatch("command", "activate", left, sourceContext()).code, "unavailable");
        const forged = Object.assign({}, identity, {command:["evil"]});
        compare(controller.dispatch("command", "activate", forged, sourceContext()).code, "invalid-data");
        for (const workspace of [{id:-99,name:"special:notes",special:true}, {id:4,name:"named",special:false}]) {
            compare(controller.dispatch("command", "activate", identity, {outputName:"DP-2",workspace:workspace}).code, "unavailable");
        }
        compare(controller.dispatch("command", "activate", identity, null).code, "unavailable");
        controller.widgetItems[controller.widgetItems.length-1].enabled = false;
        compare(controller.dispatch("command", "activate", identity, sourceContext()).code, "unavailable");
        verify(!process.running);
    }
    function test_callback_profile_mutation_and_reentry_cannot_launch() {
        const identity = commandFixture();
        controller.validateCommandHost = function() {
            compare(controller.dispatch("command", "activate", identity, sourceContext()).code, "busy");
            controller.widgetItems[controller.widgetItems.length-1].settings.actions.right.command = ["replacement"];
            return true;
        };
        compare(controller.dispatch("command", "activate", identity, sourceContext()).code, "unavailable");
        verify(!process.running);
    }
    function test_host_stale_at_process_start_gets_no_request_and_no_retry() {
        const identity = commandFixture(); let calls = 0;
        controller.validateCommandHost = function() { return ++calls === 1; };
        compare(controller.dispatch("command", "activate", identity, sourceContext()).code, "pending");
        verify(controller.activeRequest.rejected);
        compare(process.sentSignals, [15]);
        complete('{}', 1);
        compare(controller.lastResult.code, "unavailable"); compare(calls, 2);
    }
}
