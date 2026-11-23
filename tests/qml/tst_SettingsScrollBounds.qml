import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/modules" as Modules
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "SettingsScrollBounds"
    when: windowShown

    property var settingsWindow: null

    Services.SettingsController {
        id: settingsOwner
        enableColdRecovery: false
    }

    Component {
        id: settingsComponent
        Window {
            width: 1000
            height: 520
            visible: true
            property alias settingsSurface: settingsSurface

            Modules.SettingsWindow {
                id: settingsSurface
                anchors.fill: parent
                settingsController: settingsOwner
                windowOpen: true
            }
        }
    }

    function cleanup() {
        if (!settingsWindow)
            return;
        settingsWindow.close();
        settingsWindow.destroy();
        settingsWindow = null;
    }

    function descendants(item, result) {
        if (!item)
            return result;
        result.push(item);
        const children = item.children || [];
        for (let index = 0; index < children.length; index++)
            descendants(children[index], result);
        const data = item.data || [];
        for (let index = 0; index < data.length; index++) {
            if (data[index] !== item && children.indexOf(data[index]) < 0)
                descendants(data[index], result);
        }
        if (item.contentItem && item.contentItem !== item
                && children.indexOf(item.contentItem) < 0)
            descendants(item.contentItem, result);
        return result;
    }

    function wheel(item, targetWindow, delta) {
        const point = item.mapToItem(targetWindow.contentItem,
            Math.floor(item.width / 2), Math.floor(item.height / 2));
        mouseMove(targetWindow.contentItem, point.x, point.y);
        mouseWheel(targetWindow.contentItem, point.x, point.y,
            0, delta, Qt.NoButton, Qt.NoModifier);
    }

    function atMaximum(scroll) {
        return Math.max(scroll.originY, scroll.originY + scroll.contentHeight - scroll.height);
    }

    function test_expanded_sidebar_scrolls_between_its_bounds() {
        settingsWindow = settingsComponent.createObject(testCase);
        verify(settingsWindow);
        tryCompare(settingsWindow, "visible", true);
        settingsWindow.settingsSurface.navigateTo("colours", "landing", "semantic");
        wait(80);

        const items = descendants(settingsWindow.settingsSurface, []);
        const categories = items.filter(item => item && item.objectName
            && item.objectName.indexOf("category-") === 0);
        const sections = items.filter(item => item && item.objectName
            && item.objectName.indexOf("section-colours-") === 0);
        compare(categories.length, 8, "The complete category list should be present");
        compare(sections.length, 5, "The selected category should expose its sections");

        const sidebar = items.find(item => item && typeof item.contentY === "number"
            && typeof item.contentHeight === "number" && item.width >= 200
            && item.width < 300 && item.contentHeight > item.height + 1);
        verify(sidebar, "Expanded categories should overflow the Settings sidebar");
        compare(sidebar.contentY, sidebar.originY);

        for (let index = 0; index < 20; index++)
            wheel(sidebar, settingsWindow, -120);
        compare(sidebar.contentY, atMaximum(sidebar));
        wheel(sidebar, settingsWindow, -120);
        compare(sidebar.contentY, atMaximum(sidebar), "Scrolling past the end should stay within bounds");

        for (let index = 0; index < 20; index++)
            wheel(sidebar, settingsWindow, 120);
        compare(sidebar.contentY, sidebar.originY);
        wheel(sidebar, settingsWindow, 120);
        compare(sidebar.contentY, sidebar.originY, "Scrolling above the start should stay within bounds");
    }

    function test_theme_shelf_empty_search_and_wheel_bounds() {
        settingsWindow = settingsComponent.createObject(testCase);
        verify(settingsWindow);
        tryCompare(settingsWindow, "visible", true);

        const fixtures = Array.from({length: 36}, (_, index) => ({
            id: "scroll-fixture-" + index,
            name: "Scroll fixture " + index,
            builtin: false,
            preview: {}
        }));
        const library = settingsWindow.settingsSurface.libraryProvider;
        library.themes = fixtures;
        library.selectedThemeId = fixtures[0].id;
        settingsWindow.settingsSurface.shelfOpen = true;
        wait(80);

        const shelf = descendants(settingsWindow.settingsSurface, []);
        const list = shelf.find(item => item && typeof item.count === "number"
            && typeof item.contentY === "number" && typeof item.contentHeight === "number");
        verify(list, "The theme shelf should expose its real ListView");
        tryCompare(list, "count", fixtures.length);
        verify(list.contentHeight > list.height + 1, "The theme fixture should overflow the shelf");

        library.searchText = "no matching fixture";
        tryCompare(list, "count", 0);
        tryVerify(() => shelf.some(item => item && item.text === "No themes match the search."
            && item.visible));

        library.searchText = "";
        tryCompare(list, "count", fixtures.length);
        tryVerify(() => list.contentHeight > list.height + 1);
        compare(list.contentY, list.originY);

        for (let index = 0; index < 20; index++)
            wheel(list, settingsWindow, -120);
        compare(list.contentY, atMaximum(list));
        wheel(list, settingsWindow, -120);
        compare(list.contentY, atMaximum(list), "Scrolling past the last theme should stay within bounds");

        for (let index = 0; index < 20; index++)
            wheel(list, settingsWindow, 120);
        compare(list.contentY, list.originY);
        wheel(list, settingsWindow, 120);
        compare(list.contentY, list.originY, "Scrolling above the first theme should stay within bounds");
    }
}
