import "../../shell/services" as Services
import QtQuick
import QtQuick.Window
import QtTest
import qs.modules as Modules

TestCase {
    id: testCase
    name: "SettingsThemeCards"
    when: windowShown

    Window {
        id: testWindow
        width: 360
        height: 230
        visible: true

        Item {
            id: testScene
            anchors.fill: parent
            focus: true

            Modules.SettingsThemeCard {
                id: firstCard
            x: 10
            y: 10
            width: 300
            themeData: ({id: "first", name: "First", palette: ["#82aaff", "#c3e88d", "#ffcb6b", "#e7ebf2"]})
            onChosen: themeId => themeLibrary.selectTheme(themeId)
            onContextMenuRequested: (anchor, keyboardOpened) => menuState.openMenu(cardId, anchor, keyboardOpened, menuAction)
            }

            Modules.SettingsThemeCard {
                id: secondCard
            x: 10
            y: 110
            width: 300
            themeData: ({id: "second", name: "Second", palette: ["#82aaff", "#c3e88d", "#ffcb6b", "#e7ebf2"]})
            onChosen: themeId => themeLibrary.selectTheme(themeId)
            onContextMenuRequested: (anchor, keyboardOpened) => menuState.openMenu(cardId, anchor, keyboardOpened, menuAction)
            }

            Rectangle {
                id: menuAction
                x: 320
                y: 10
                width: 30
                height: 30
                activeFocusOnTab: true
            }
        }
    }

    Services.SettingsThemeMenuState {
        id: menuState
    }

    Services.SettingsThemeLibrary {
        id: themeLibrary
    }

    function init() {
        firstCard.pointerCoordinateItem = null;
        firstCard.globalPointer = ({x: -1, y: -1, occluded: false});
        secondCard.pointerCoordinateItem = null;
        secondCard.globalPointer = ({x: -1, y: -1, occluded: false});
        menuState.closeMenu(false);
        themeLibrary.themes = [
            {id: "blox-panel", name: "Default", builtin: true, preview: {}},
            {id: "second", name: "Second", builtin: false, preview: {}}
        ];
        themeLibrary.selectedThemeId = "blox-panel";
    }

    function test_clicking_theme_card_changes_selection_without_applying() {
        mouseClick(secondCard, 60, secondCard.height / 2);
        compare(themeLibrary.selectedThemeId, "second");
        compare(themeLibrary.appliedThemeId, "blox-panel");
        verify(themeLibrary.dirty);
    }

    function test_clicking_another_ellipsis_transfers_the_open_menu() {
        mouseClick(firstCard, firstCard.width - 15, firstCard.height / 2);
        compare(menuState.cardId, "first");
        mouseClick(secondCard, secondCard.width - 15, secondCard.height / 2);
        compare(menuState.cardId, "second");
        verify(menuState.open);
    }

    function test_global_hover_tracks_other_ellipsis_while_menu_stays_open() {
        mouseClick(firstCard, firstCard.width - 15, firstCard.height / 2);
        compare(menuState.cardId, "first");

        secondCard.pointerCoordinateItem = testScene;
        const actionPosition = secondCard.mapToItem(testScene,
            secondCard.width - 15, secondCard.height / 2);
        secondCard.globalPointer = ({x: actionPosition.x, y: actionPosition.y, occluded: false});
        compare(secondCard.pointerPolling, true);
        secondCard.syncGlobalPointer();

        verify(secondCard.cardHovered);
        verify(secondCard.actionHovered);
        compare(menuState.cardId, "first");
    }

}
