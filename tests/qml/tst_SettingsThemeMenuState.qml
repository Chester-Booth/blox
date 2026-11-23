import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "SettingsThemeMenuState"

    Item {
        id: focusScene
        width: 300
        height: 160
        focus: true

        Rectangle {
            id: firstAnchor
            objectName: "first-theme-menu-anchor"
            x: 10
            y: 10
            width: 40
            height: 30
            activeFocusOnTab: true
            property bool hovered: false
        }

        Rectangle {
            id: secondAnchor
            x: 60
            y: 10
            width: 40
            height: 30
            activeFocusOnTab: true
            property bool hovered: false
        }

        Rectangle {
            id: menuAction
            x: 120
            y: 10
            width: 80
            height: 30
            activeFocusOnTab: true
        }
    }

    Services.SettingsThemeMenuState {
        id: state
    }

    function test_hover_does_not_change_menu_and_click_transfers_it() {
        verify(state.openMenu("first", firstAnchor, false, menuAction));
        compare(state.cardId, "first");
        secondAnchor.hovered = true;
        compare(state.cardId, "first");
        verify(state.openMenu("second", secondAnchor, false, menuAction));
        compare(state.cardId, "second");
        verify(state.open);
    }

    function test_keyboard_close_returns_focus_to_originating_card() {
        firstAnchor.forceActiveFocus();
        verify(firstAnchor.activeFocus);
        verify(state.openMenu("first", firstAnchor, true, menuAction));
        tryCompare(menuAction, "activeFocus", true);
        state.closeMenu(true);
        tryCompare(firstAnchor, "activeFocus", true);
        verify(!state.open);
    }

    function test_menu_flips_up_and_stays_inside_frame() {
        const position = state.positionFor(Qt.point(280, 140), Qt.size(30, 30), Qt.size(164, 120), Qt.size(300, 160));
        verify(position.x >= 8);
        verify(position.y >= 8);
        verify(position.y + 120 <= 152);
    }
}
