import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
    name: "ScriptPoller"
    Component { id: factory; Services.ScriptPoller { command: [] } }
    function complete(poller, output, code) {
        poller.pendingRaw = output;
        for (let i = 0; i < poller.data.length; i++) {
            if (typeof poller.data[i].finish === "function") {
                poller.data[i].finish(code, 0);
                return;
            }
        }
        fail("Missing isolated process");
    }
    function test_text_widget_success_and_command_failure() {
        const poller = createTemporaryObject(factory, this, {parseJson: false});
        complete(poller, "# todo 1/1\nBuy milk", 0);
        verify(poller.ok);
        compare(poller.raw, "# todo 1/1\nBuy milk");
        compare(poller.lastError, "");
        complete(poller, "", 2);
        verify(!poller.ok);
        compare(poller.lastError, "command exited 2");
        complete(poller, "Recovered text", 0);
        verify(poller.ok);
        compare(poller.lastError, "");
    }
    function test_json_callers_still_reject_malformed_output() {
        const poller = createTemporaryObject(factory, this);
        complete(poller, "not JSON", 0);
        verify(!poller.ok);
        complete(poller, '{"ready":true}', 0);
        verify(poller.ok);
        verify(poller.json.ready);
    }
}
