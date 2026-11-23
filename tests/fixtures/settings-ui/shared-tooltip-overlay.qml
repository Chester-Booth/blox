import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
TestCase {
    name: "BloxTooltipOverlay"
    when: windowShown
    Window {
        id: host
        width: 360
        height: 240
        visible: true
        Item {
            id: anchor
            x: 90; y: 20
            width: 40; height: 32
            BloxToolTip {
                id: tooltip
                text: "Show all search results"
                delay: 1
            }
        }
        Popup {
            id: suggestions
            parent: host.contentItem
            x: 10; y: 50
            width: 330; height: 170
            z: 1000
            contentItem: Item {}
            background: Rectangle { color: "#dd4422" }
        }
    }
    function test_tooltip_is_above_search_popup_and_inside_window() {
        suggestions.open();
        tooltip.shown = true;
        tryCompare(tooltip, "visible", true);
        verify(tooltip.contentItem.parent.z > suggestions.contentItem.parent.z);
        const point = tooltip.contentItem.parent.mapToItem(host.contentItem, 0, 0);
        verify(point.x >= 4);
        verify(point.y >= 4);
        verify(point.x + tooltip.width <= host.width - 4);
        verify(point.y + tooltip.height <= host.height - 4);
        let captured = false;
        host.contentItem.grabToImage(result => {
            result.saveToFile("/tmp/blox-tooltip-overlay.png");
            captured = true;
        });
        tryVerify(() => captured);
        tooltip.shown = false;
        tryCompare(tooltip, "visible", false);
        suggestions.close();
    }
}
