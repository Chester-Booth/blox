import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "BarActionResults"
    Services.BarActions { id: actions; scriptRoot: "/isolated/scripts" }
    function process(name) { const value = findChild(actions, name); verify(value !== null); return value; }
    function init() {
        actions.notesSaveBusy = false;
        actions.generatedRefreshBusy = false;
        actions.performanceBusy = false;
        actions.caffeineBusy = false;
        for (const name of ["notes-save-process", "generated-refresh-process", "performance-action-process", "caffeine-action-process"]) {
            const value = process(name);
            value.running = false;
        }
    }
    function test_notes_busy_invalid_and_denied_are_typed() {
        compare(actions.saveNotes("", "body").code, "invalid-data");
        compare(actions.saveNotes("/isolated/note.md", "body").code, "pending");
        compare(actions.saveNotes("/isolated/note.md", "next").code, "busy");
        process("notes-save-process").finish(4, 0);
        process("notes-save-process").stderr.streamFinished();
        compare(actions.notesSaveResult.code, "permission-denied");
        verify(!actions.notesSaveResult.ok);
        verify(!actions.notesSaveResult.data.pending);
    }
    function test_generated_exit_code_controls_result_not_display_text() {
        compare(actions.refreshGeneratedNotes().code, "pending");
        const value = process("generated-refresh-process");
        actions.generatedProcessError = "permission denied and timed out";
        value.finish(75, 0);
        value.stderr.streamFinished();
        compare(actions.generatedRefreshResult.code, "busy");
        actions.refreshGeneratedNotes();
        value.finish(124, 0);
        value.stderr.streamFinished();
        compare(actions.generatedRefreshResult.code, "timeout");
        actions.refreshGeneratedNotes();
        actions.generatedProcessError = "permission denied";
        value.finish(1, 0);
        value.stderr.streamFinished();
        compare(actions.generatedRefreshResult.code, "failed");
    }
    function test_performance_waits_for_complete_process_result() {
        compare(actions.runPerformance("").code, "invalid-data");
        compare(actions.runPerformance("isolated action").code, "pending");
        compare(actions.runPerformance("another action").code, "busy");
        const value = process("performance-action-process");
        value.finish(124, 0);
        verify(actions.performanceBusy);
        value.stdout.text = "";
        value.stdout.streamFinished();
        value.stderr.text = "Not a classification source";
        value.stderr.streamFinished();
        compare(actions.performanceResult.code, "timeout");
        verify(!actions.performanceBusy);
    }
    function test_performance_preserves_structured_owner_result() {
        actions.runPerformance("isolated owner action");
        const value = process("performance-action-process");
        value.stdout.text = JSON.stringify({version: 1, ok: false, code: "stale", message: "Owner state changed", data: {pending: false, beforeRevision: 7}});
        value.stdout.streamFinished();
        value.stderr.text = "arbitrary diagnostic text";
        value.stderr.streamFinished();
        value.finish(5, 0);
        compare(actions.performanceResult.code, "stale");
        compare(actions.performanceResult.data.beforeRevision, 7);
        actions.runPerformance("another isolated owner action");
        value.stdout.text = JSON.stringify({version: 1, ok: true, code: "ok", message: "", data: {pending: true}});
        value.stdout.streamFinished();
        value.stderr.streamFinished();
        value.finish(0, 0);
        verify(actions.performanceResult.data.pending);
    }
    function test_no_second_request_before_terminal_streams_finish() {
        actions.saveNotes("/isolated/note.md", "body");
        let value = process("notes-save-process");
        value.finish(0, 0);
        compare(actions.saveNotes("/isolated/note.md", "other").code, "busy");
        value.stderr.streamFinished();
        verify(!actions.notesSaveBusy);

        actions.refreshGeneratedNotes();
        value = process("generated-refresh-process");
        value.finish(0, 0);
        compare(actions.refreshGeneratedNotes().code, "busy");
        value.stderr.streamFinished();
        verify(!actions.generatedRefreshBusy);

        actions.runPerformance("isolated owner action");
        value = process("performance-action-process");
        value.finish(0, 0);
        compare(actions.runPerformance("new action").code, "busy");
        value.stdout.text = "";
        value.stdout.streamFinished();
        value.stderr.streamFinished();
        verify(!actions.performanceBusy);

        actions.runCaffeine("off");
        value = process("caffeine-action-process");
        value.finish(0, 0);
        compare(actions.runCaffeine("indefinite").code, "busy");
        value.stdout.text = JSON.stringify({version: 1, ok: true, code: "ok", message: "", data: {pending: false}});
        value.stdout.streamFinished();
        compare(actions.caffeineResult.code, "ok");
        verify(!actions.caffeineBusy);
    }
    function test_caffeine_uses_one_owner_and_propagates_typed_failure() {
        compare(actions.run("/isolated/scripts/status/caffeine.sh indefinite").code, "pending");
        const value = process("caffeine-action-process");
        compare(value.command[3], "action");
        compare(actions.runCaffeine("indefinite").code, "busy");
        value.finish(1, 0);
        value.stdout.text = JSON.stringify({version: 1, ok: false, code: "failed", message: "No inhibitor", data: {pending: false}});
        value.stdout.streamFinished();
        compare(actions.caffeineResult.code, "failed");
        verify(!actions.caffeineResult.ok);
    }
    function test_caffeine_bad_reply_and_deadline_are_typed() {
        actions.runCaffeine("off");
        const value = process("caffeine-action-process");
        value.stdout.text = "not json";
        value.stdout.streamFinished();
        value.finish(0, 0);
        compare(actions.caffeineResult.code, "invalid-data");
        actions.runCaffeine("off");
        value.stdout.text = "";
        value.stdout.streamFinished();
        value.finish(124, 0);
        compare(actions.caffeineResult.code, "timeout");
    }
}
