import QtQuick
import QtTest
import "../../shell/modules/SettingsBarOrder.js" as BarOrder

TestCase {
    name: "SettingsBarOrder"

    function items() {
        return [
            {id: "power", region: "start", order: 0, enabled: true},
            {id: "clock", region: "start", order: 1, enabled: true},
            {id: "tray", region: "end", order: 0, enabled: true},
            {id: "sound", region: "end", order: 1, enabled: true},
            {id: "application-tray", region: "hidden", order: 0, enabled: true},
            {id: "notes", region: "hidden", order: 1, enabled: false}
        ];
    }

    function ids(items, region) {
        return items.filter(item => item.region === region).map(item => item.id).join(",");
    }

    function test_drag_reorders_same_region_without_mutating_source() {
        const before = items();
        const after = BarOrder.moveTo(before, "power", "start", 2);
        compare(ids(after, "start"), "clock,power");
        compare(ids(before, "start"), "power,clock");
        compare(after.find(item => item.id === "power").order, 1);
    }

    function test_drag_moves_between_regions_preserving_item_options() {
        const before = items();
        before[1].titleLength = "full";
        const after = BarOrder.moveTo(before, "clock", "end", 2);
        compare(ids(after, "start"), "power");
        compare(ids(after, "end"), "tray,sound,clock");
        compare(after.find(item => item.id === "clock").titleLength, "full");
        compare(after.find(item => item.id === "notes").enabled, false);
    }

    function test_tray_stays_on_region_edge() {
        compare(BarOrder.moveTo(items(), "tray", "hidden", 1), null);
        compare(BarOrder.moveTo(items(), "tray", "start", 1), null);
        const after = BarOrder.moveTo(items(), "tray", "start", 2);
        compare(ids(after, "start"), "power,clock,tray");
        compare(ids(after, "hidden"), "notes,application-tray");
    }

    function test_application_tray_cannot_leave_hidden_region() {
        compare(BarOrder.moveTo(items(), "application-tray", "start", 0), null);
        compare(BarOrder.moveTo(items(), "application-tray", "hidden", 1), null);
        verify(BarOrder.dropAllowed(items(), "application-tray", "hidden", 0));
    }

    function test_invalid_drop_does_not_produce_an_edit() {
        compare(BarOrder.moveTo(items(), "clock", "missing", 0), null);
        compare(BarOrder.moveTo(items(), "clock", "start", -1), null);
        compare(BarOrder.moveTo(items(), "missing", "start", 0), null);
    }
}
