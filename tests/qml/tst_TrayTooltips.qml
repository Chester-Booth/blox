import QtQuick
import QtTest
import "../../shell/shared" as Shared

TestCase {
    id: testCase
    name: "TrayTooltips"
    when: windowShown
    visible: true
    width: 400
    height: 300
    property real menuCentre: -1
    QtObject {
        id: app
        property string icon: ""
        property string tooltipTitle: "Application hint"
        property string tooltipDescription: "Application status"
        property string title: "Application title"
        property string id: "fixture-app"
        function activate() {}
        function secondaryActivate() {}
    }
    Item { id: focusSink; x: 200; y: 100; width: 50; height: 50 }
    Shared.TrayRailItem {
        id: rail
        x: 20; y: 40
        item: app
        onOpenMenu: (item, centre) => testCase.menuCentre = centre
    }
    function init() {
        rail.menuOpen = false;
        app.tooltipTitle = "Application hint";
        app.tooltipDescription = "Application status";
        focusSink.forceActiveFocus();
        mouseMove(focusSink, 20, 20);
        wait(20);
        menuCentre = -1;
    }
    function test_hover_delay_leave_and_menu_suppression() {
        mouseMove(rail, 15, 15);
        verify(!rail.tooltipReady);
        tryCompare(rail, "tooltipReady", true);
        rail.menuOpen = true;
        compare(rail.tooltipReady, false);
        wait(350);
        compare(rail.tooltipReady, false);
        rail.menuOpen = false;
        tryCompare(rail, "tooltipReady", true);
        mouseMove(focusSink, 20, 20);
        tryCompare(rail, "tooltipReady", false);
    }
    function test_short_tooltip_uses_one_line_and_long_text_wraps() {
        app.tooltipTitle = "ChatGPT";
        app.tooltipDescription = "T";
        const label = findChild(rail, "tray-tooltip-label");
        wait(20);
        compare(label.lineCount, 1);
        app.tooltipDescription = Array.from({length: 40}, () => "Long tooltip text").join(" ");
        wait(20);
        verify(label.lineCount > 1);
        verify(findChild(rail, "tray-tooltip").implicitWidth <= 320);
    }
    function test_metadata_fallback_and_local_menu_anchor() {
        compare(rail.tooltipTitle, "Application hint");
        app.tooltipTitle = "";
        compare(rail.tooltipTitle, "Application title");
        mouseClick(rail, 15, 15, Qt.RightButton);
        compare(menuCentre, rail.height / 2);
        verify(!rail.tooltipReady);
    }
}
