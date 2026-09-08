import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    name: "MonitorState"

    Services.MonitorState {
        id: state
        providerReady: true
        syncReady: true
        backendAvailable: true
    }

    function test_no_active_monitor_is_typed() {
        state.monitors = [];
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "no-active-monitor");
    }

    function test_live_choices_keep_geometry() {
        state.monitors = [{"name": "renamed-panel", "width": 2560, "height": 1440, "x": -120, "y": 40, "scale": 1.5, "transform": 3, "refreshId": "60", "canChange": true, "rates": [{"id": "120", "rate": 120, "label": "120 Hz"}, {"id": "60", "rate": 60, "label": "60 Hz"}]}];
        verify(state.json.capability.canChange);
        compare(state.json.monitors[0].x, -120);
        compare(state.json.monitors[0].transform, 3);
        compare(state.json.monitors[0].rates.length, 2);
    }
}
