import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import "../../shell/modules" as Modules

TestCase {
    id: testCase
    name: "LauncherEmojiInteraction"
    when: windowShown

    property var emojiController: null
    property var emojiWindow: null
    property var emojiPicker: null
    property int pasteRequests: 0
    property int savedEmojiTone: 0
    property var savedLauncherState: null

    Component {
        id: emojiControllerComponent

        Modules.EmojiController {
            onPasteRequested: testCase.pasteRequests++
        }
    }

    Component {
        id: emojiWindowComponent

        Window {
            width: 500
            height: 380
            visible: true
            property alias pickerSurface: pickerSurface

            Modules.EmojiPicker {
                id: pickerSurface
                anchors.fill: parent
                controller: testCase.emojiController
                positionReady: true
                targetScreen: null
                open: false
            }
        }
    }

    function init() {
        pasteRequests = 0;
        savedEmojiTone = Modules.LauncherState.emojiTone;
        savedLauncherState = JSON.stringify({pins: Modules.LauncherState.pinnedEmoji,
            recent: Modules.LauncherState.recentEmoji, usage: Modules.LauncherState.emojiUsage,
            variants: Modules.LauncherState.emojiVariants});
        Modules.LauncherState.pinnedEmoji = [];
        Modules.LauncherState.recentEmoji = [];
        Modules.LauncherState.emojiUsage = ({});
        Modules.LauncherState.emojiVariants = ({});
        if (!emojiController)
            emojiController = emojiControllerComponent.createObject(testCase);
        verify(emojiController, "EmojiController should be available for the mounted picker");
    }

    function cleanup() {
        if (emojiPicker) {
            emojiPicker.open = false;
            emojiPicker = null;
        }
        destroyObject("emojiWindow");
        emojiPicker = null;
        emojiWindow = null;
        Modules.LauncherState.emojiTone = savedEmojiTone;
        const saved = JSON.parse(savedLauncherState);
        Modules.LauncherState.pinnedEmoji = saved.pins;
        Modules.LauncherState.recentEmoji = saved.recent;
        Modules.LauncherState.emojiUsage = saved.usage;
        Modules.LauncherState.emojiVariants = saved.variants;
    }

    function cleanupTestCase() {
        destroyObject("emojiController");
    }

    function destroyObject(name) {
        const object = testCase[name];
        if (!object)
            return;
        if (typeof object.close === "function")
            object.close();
        object.destroy();
        testCase[name] = null;
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

    function firstWhere(item, predicate) {
        const items = descendants(item, []);
        for (let index = 0; index < items.length; index++) {
            if (predicate(items[index]))
                return items[index];
        }
        return null;
    }

    function emojiRows(count) {
        return Array.from({length: count}, (_, index) => ({
            value: String.fromCodePoint(0x1f600 + index),
            name: "fixture emoji " + index,
            keywords: "fixture",
            category: "Smileys & Emotion"
        }));
    }

    function loadEmojiRows(rows) {
        const emojiFile = findChild(emojiController, "emoji-data-file");
        const nerdFontFile = findChild(emojiController, "nerd-font-data-file");
        verify(emojiFile && nerdFontFile, "Emoji fixture FileViews should be present");
        emojiFile.fixtureText = JSON.stringify({items: rows});
        emojiFile.loaded();
        nerdFontFile.fixtureText = JSON.stringify({items: [], purposes: [], source_filters: []});
        nerdFontFile.loaded();
        emojiController.category = "Smileys & Emotion";
    }

    function mountEmojiPicker() {
        emojiWindow = emojiWindowComponent.createObject(testCase);
        verify(emojiWindow, "Emoji picker host Window should be created");
        emojiPicker = emojiWindow.pickerSurface;
        verify(emojiPicker, "EmojiPicker proxy should mount in the host Window");
        emojiPicker.open = true;
        tryCompare(emojiWindow, "visible", true);
        tryCompare(emojiPicker, "visible", true);
        const windowProxy = emojiPicker.contentItem.Window.window;
        verify(windowProxy === emojiWindow,
            "The FloatingWindow proxy should resolve its mounted QQuickWindow");
        return windowProxy;
    }

    function emojiGrid() {
        return firstWhere(emojiPicker, item => item
            && typeof item.currentIndex === "number"
            && typeof item.cellWidth === "number"
            && typeof item.contentY === "number"
            && typeof item.itemAtIndex === "function");
    }

    function wheel(item, targetWindow, delta) {
        const point = item.mapToItem(targetWindow.contentItem,
            Math.floor(item.width / 2), Math.floor(item.height / 2));
        mouseMove(targetWindow.contentItem, point.x, point.y);
        mouseWheel(targetWindow.contentItem, point.x, point.y,
            0, delta, Qt.NoButton, Qt.NoModifier);
    }

    function clickItem(item, targetWindow) {
        const point = item.mapToItem(targetWindow.contentItem,
            Math.floor(item.width / 2), Math.floor(item.height / 2));
        mouseClick(targetWindow.contentItem, point.x, point.y);
    }

    function test_emoji_grid_keyboard_moves_selection_and_scrolls_long_results() {
        const rows = emojiRows(100);
        rows.push({
            value: "🍇",
            name: "fixture food",
            keywords: "fixture",
            category: "Food & Drink"
        });
        loadEmojiRows(rows);
        mountEmojiPicker();
        const grid = emojiGrid();
        verify(grid, "EmojiPicker should expose its real GridView");
        compare(emojiController.itemCount, 100);
        tryCompare(grid, "count", 100);
        tryVerify(() => grid.height > 0 && grid.contentHeight > grid.height + 1);

        emojiWindow.requestActivate();
        tryCompare(emojiWindow, "active", true);
        grid.forceActiveFocus();
        tryVerify(() => grid.activeFocus);
        const start = emojiController.selectedIndex;
        keyClick(Qt.Key_Right);
        compare(emojiController.selectedIndex, start + 1);
        compare(grid.currentIndex, start + 1);
        keyClick(Qt.Key_Down);
        verify(emojiController.selectedIndex > start + 1,
            "Down should advance by a grid row");
        compare(grid.currentIndex, emojiController.selectedIndex);

        keyClick(Qt.Key_End);
        tryVerify(() => emojiController.selectedIndex === grid.count - 1);
        compare(grid.currentIndex, grid.count - 1);
        tryVerify(() => grid.contentY > grid.originY);
        keyClick(Qt.Key_PageDown);
        compare(emojiController.selectedIndex, grid.count - 1,
            "PageDown should stop at the category's final result");
        keyClick(Qt.Key_Home);
        tryVerify(() => emojiController.selectedIndex === 0);
        compare(grid.currentIndex, 0);
        tryVerify(() => grid.contentY <= grid.originY + 1);

        emojiController.category = "Search";
        tryCompare(grid, "count", 101);
        keyClick(Qt.Key_PageDown);
        tryVerify(() => emojiController.selectedIndex > 0);
        compare(grid.currentIndex, emojiController.selectedIndex);
        tryVerify(() => grid.contentY > grid.originY);
        const pageDownY = grid.contentY;
        keyClick(Qt.Key_PageUp);
        compare(emojiController.selectedIndex, 0);
        compare(grid.currentIndex, 0);
        verify(grid.contentY < pageDownY);
        tryVerify(() => grid.contentY <= grid.originY + 1);
        keyClick(Qt.Key_PageUp);
        compare(emojiController.selectedIndex, 0,
            "PageUp should stop at the first search result");
        keyClick(Qt.Key_End);
        compare(emojiController.selectedIndex, 100,
            "Search browse End should reach the final item without wrapping");
        compare(grid.currentIndex, 100);
        keyClick(Qt.Key_Home);
        compare(emojiController.selectedIndex, 0);

        wheel(grid, emojiWindow, -120);
        verify(grid.contentY > grid.originY,
            "A wheel event over the focused grid should move long results");
        verify(grid.contentY <= grid.originY + grid.contentHeight - grid.height + 1,
            "Grid scrolling should remain within its content bounds");
        wheel(grid, emojiWindow, 120);
        compare(grid.contentY, grid.originY);
        compare(pasteRequests, 0, "Navigation must not activate an emoji");
        keyClick(Qt.Key_Return);
        const fakeCopyProcess = firstWhere(emojiController, item => item
            && typeof item.running === "boolean"
            && typeof item.finish === "function"
            && Array.isArray(item.command));
        verify(fakeCopyProcess, "EmojiController should use the test Process stub");
        tryCompare(fakeCopyProcess, "running", true);
        compare(fakeCopyProcess.command[0], "wl-copy");
        fakeCopyProcess.finish(0, 0);
        compare(pasteRequests, 1, "Keyboard activation should emit one paste request");
    }

    function test_emoji_picker_distinguishes_load_error_from_valid_empty() {
        loadEmojiRows([]);
        mountEmojiPicker();
        const emojiFile = findChild(emojiController, "emoji-data-file");
        emojiFile.loadFailed("fixture read failure");
        const grid = emojiGrid();
        tryVerify(() => grid && grid.count === 0);
        const errorText = firstWhere(emojiPicker, item => item
            && item.text === "Emoji data could not be loaded.");
        verify(errorText && errorText.visible,
            "The mounted picker should show its load failure");
        compare(emojiController.emptyStateIsError, true);

        emojiFile.fixtureText = JSON.stringify({items: []});
        emojiFile.loaded();
        tryVerify(() => emojiController.emptyStateText === "No emoji available.");
        const emptyText = firstWhere(emojiPicker, item => item
            && item.text === "No emoji available.");
        verify(emptyText && emptyText.visible,
            "A valid empty file should show the empty state, not an error");
        compare(emojiController.emptyStateIsError, false);
        compare(pasteRequests, 0);
    }

    function test_query_results_update_visible_rows_when_count_changes() {
        const rows = emojiRows(8);
        rows[3].keywords = "fixture narrow";
        rows[4].keywords = "fixture alternate";
        loadEmojiRows(rows);
        emojiController.query = "";
        emojiController.category = "Search";
        mountEmojiPicker();
        const grid = emojiGrid();
        for (const step of [{query: "narrow", count: 1, name: rows[3].name},
                {query: "alternate", count: 1, name: rows[4].name},
                {query: "fixture", count: 8, name: rows[0].name},
                {query: "absent", count: 0, name: ""},
                {query: "fixture", count: 8, name: rows[0].name},
                {query: "", count: 8, name: rows[0].name}]) {
            emojiController.query = step.query;
            tryCompare(emojiController, "itemCount", step.count);
            tryCompare(grid, "count", step.count);
            if (step.count) {
                tryVerify(() => grid.itemAtIndex(0)
                    && grid.itemAtIndex(0).modelData.item
                    && grid.itemAtIndex(0).modelData.item.name === step.name);
                verify(emojiController.itemAt(step.count - 1));
                compare(emojiController.itemAt(step.count), null);
            }
        }
        emojiController.query = "";
    }

    function test_visible_virtual_cell_reorders_after_pin_without_count_change() {
        const rows = emojiRows(3);
        loadEmojiRows(rows);
        emojiController.category = "Search";
        mountEmojiPicker();
        const grid = emojiGrid();
        tryCompare(grid, "count", 3);
        tryVerify(() => grid.itemAtIndex(0) && grid.itemAtIndex(0).modelData.item.name === rows[0].name);
        emojiController.togglePin(2);
        compare(Modules.LauncherState.pinnedEmoji[0], rows[2].value);
        compare(grid.count, 3);
        tryVerify(() => grid.itemAtIndex(0).modelData.item.name === rows[2].name);
        verify(grid.itemAtIndex(0).modelData.item.pinned);
        emojiController.togglePin(0);
        compare(Modules.LauncherState.pinnedEmoji.length, 0);
        compare(grid.count, 3);
        tryVerify(() => grid.itemAtIndex(0).modelData.item.name === rows[0].name);
        verify(!grid.itemAtIndex(0).modelData.item.pinned);
    }

    function test_visible_virtual_cell_updates_tone_and_current_value_persistence() {
        Modules.LauncherState.emojiTone = 0;
        loadEmojiRows([
            {value: "👍", baseValue: "👍", name: "thumbs up", keywords: "thumb", category: "People & Body"},
            {value: "👍🏽", baseValue: "👍", name: "thumbs up: medium skin tone", keywords: "thumb", category: "People & Body"}
        ]);
        emojiController.category = "Search";
        mountEmojiPicker();
        const grid = emojiGrid();
        tryCompare(grid, "count", 1);
        tryVerify(() => grid.itemAtIndex(0) && grid.itemAtIndex(0).modelData.item.value === "👍");
        Modules.LauncherState.emojiTone = 3;
        compare(grid.count, 1);
        tryVerify(() => grid.itemAtIndex(0).modelData.item.value === "👍🏽");
        emojiController.togglePin(0);
        compare(Modules.LauncherState.pinnedEmoji[0], "👍");
        emojiController.activate();
        compare(Modules.LauncherState.recentEmoji[0].value, "👍🏽");
        compare(Modules.LauncherState.recentEmoji[0].baseValue, "👍");
        verify(Modules.LauncherState.emojiUsage["👍"].count > 0);
        const copy = firstWhere(emojiController, item => item && typeof item.running === "boolean" && typeof item.finish === "function" && Array.isArray(item.command));
        compare(copy.command[1], "👍🏽");
        copy.finish(0, 0);
        compare(pasteRequests, 1);
    }

    function test_recent_keeps_pin_priority_and_usage_order() {
        const rows = emojiRows(3);
        loadEmojiRows(rows);
        Modules.LauncherState.recentEmoji = rows;
        const usage = {};
        rows.forEach((item, i) => usage[item.value] = {count: 1, lastUsed: 100 + i});
        Modules.LauncherState.emojiUsage = usage;
        Modules.LauncherState.pinnedEmoji = [rows[0].value];
        emojiController.category = "Recent";
        compare(emojiController.itemCount, 3);
        compare(emojiController.itemAt(0).value, rows[0].value);
        compare(emojiController.itemAt(1).value, rows[2].value);
        compare(emojiController.itemAt(2).value, rows[1].value);
        emojiController.togglePin(0);
        compare(emojiController.itemAt(0).value, rows[2].value);
        compare(emojiController.itemAt(1).value, rows[1].value);
        compare(emojiController.itemAt(2).value, rows[0].value);
    }

    function test_disabled_tone_copy_explains_missing_variant() {
        Modules.LauncherState.emojiTone = 3;
        loadEmojiRows([{
            value: "🫱‍🫲",
            name: "fixture pair",
            keywords: "fixture",
            category: "Smileys & Emotion"
        }, {
            value: "🫱🏻‍🫲🏿",
            name: "fixture pair, light skin tone, dark skin tone",
            keywords: "fixture",
            category: "Smileys & Emotion"
        }]);
        const windowProxy = mountEmojiPicker();
        const grid = emojiGrid();
        tryCompare(grid, "count", 1);
        tryVerify(() => grid.itemAtIndex(0) && grid.itemAtIndex(0).mixedToneCapable);
        const cell = grid.itemAtIndex(0);
        verify(cell && cell.mixedToneCapable,
            "A mixed-tone fixture should expose the tone composer");
        cell.openToneComposer();

        const copyButton = firstWhere(emojiPicker, item => item
            && item.text === "Copy" && typeof item.enabled === "boolean");
        tryVerify(() => copyButton && !copyButton.enabled);
        const composer = firstWhere(emojiPicker, item => item
            && item.opened === true && item.contentItem
            && firstWhere(item.contentItem, child => child && child.text === "Copy"));
        verify(composer, "The actual tone composer should be open");
        const reasonTip = firstWhere(composer.contentItem, item => item
            && item.text === "No emoji for these tones."
            && typeof item.opened === "boolean");
        verify(reasonTip, "The disabled Copy control should have its existing tooltip");
        const copyWrapper = copyButton.parent;
        verify(copyWrapper && copyWrapper.activeFocusOnTab,
            "The disabled Copy wrapper should remain keyboard reachable");
        for (let index = 0; index < 14 && !copyWrapper.activeFocus; index++)
            keyClick(Qt.Key_Tab);
        tryVerify(() => copyWrapper.activeFocus);
        tryCompare(reasonTip, "opened", true);
        compare(reasonTip.text, "No emoji for these tones.");

        const defaultButton = firstWhere(composer.contentItem, item => item
            && item.text === "Default" && typeof item.enabled === "boolean");
        verify(defaultButton, "The composer should offer the valid default variant");
        keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        tryVerify(() => defaultButton.activeFocus);
        keyClick(Qt.Key_Space);
        tryCompare(copyButton, "enabled", true);
        tryCompare(reasonTip, "opened", false);

        composer.defaultSelected = false;
        tryCompare(copyButton, "enabled", false);
        keyClick(Qt.Key_Tab);
        tryVerify(() => copyWrapper.activeFocus);
        tryCompare(reasonTip, "opened", true);
        clickItem(defaultButton, windowProxy);
        tryCompare(copyButton, "enabled", true);
        tryCompare(reasonTip, "opened", false);
        verify(copyButton.activeFocus || defaultButton.activeFocus,
            "Enabling Copy should move focus off the disabled-state wrapper");
        compare(pasteRequests, 0);
    }

}
