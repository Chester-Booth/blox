import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PowerState"

    Services.PowerState {
        id: state

        providerReady: true
        syncReady: true
        batteryPresent: true
        linePowerPresent: true
        onBattery: true
        percentage: 72
        batteryState: "discharging"
        timeToEmpty: 7500
        batteryModel: "Test battery"
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.batteryPresent = true;
        state.linePowerPresent = true;
        state.onBattery = true;
        state.percentage = 72;
        state.batteryState = "discharging";
        state.timeToEmpty = 7500;
        state.timeToFull = 0;
        state.batteryModel = "Test battery";
        state.actionError = "";
    }

    function test_discharging_state_is_typed() {
        compare(state.json.class, "normal");
        compare(state.json.capacity, 72);
        compare(state.json.status, "Discharging");
        compare(state.json.timeLabel, "2h 5m left");
        compare(state.json.source, "battery");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
    }

    function test_charging_and_low_battery_states_are_distinct() {
        state.batteryState = "charging";
        state.onBattery = false;
        state.percentage = 48;
        state.timeToFull = 3900;
        compare(state.json.class, "charging");
        compare(state.json.status, "Charging");
        compare(state.json.timeLabel, "1h 5m to full");
        state.batteryState = "discharging";
        state.onBattery = true;
        state.percentage = 8;
        compare(state.json.class, "critical");
    }

    function test_ac_only_and_no_source_are_valid_ready_states() {
        state.batteryPresent = false;
        state.linePowerPresent = true;
        compare(state.json.class, "plugged");
        compare(state.json.status, "AC power");
        compare(state.json.capacity, "");
        compare(state.json.timeLabel, "Plugged in");
        verify(state.json.capability.ready);
        state.linePowerPresent = false;
        compare(state.json.class, "unavailable");
        compare(state.json.status, "No power source");
        verify(state.json.capability.ready);
    }

    function test_loading_state_is_stale_and_not_actionable() {
        state.syncReady = false;
        compare(state.json.class, "loading");
        verify(state.json.stale);
        verify(!state.json.capability.ready);
        compare(state.json.capability.reason, "provider-loading");
    }
}
