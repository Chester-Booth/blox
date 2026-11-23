import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/modules" as Modules
import "../../shell/popouts" as Popouts
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "RemainingScrollInteraction"
    when: windowShown

    property var settingsWindow: null
    property var notificationWindow: null
    property var notesWindow: null
    property var clipboardWindow: null
    property var clipboardPicker: null
    property var notificationFixture: []

    readonly property var longNote: Array.from({length: 180}, (_, index) =>
        "Notes scroll fixture line " + (index + 1)).join("\n\n")
    Services.SettingsController {
        id: settingsOwner
        enableColdRecovery: false
    }

    Modules.ClipboardController {
        id: clipboardOwner
    }

    Component {
        id: notificationObjectComponent
        QtObject {
            property string appName: "Fixture app"
            property string appIcon: ""
            property string image: ""
            property string summary: "Fixture notification"
            property string body: "A short notification body for scrolling."
            property int urgency: 1
            property var actions: []
            property bool hasActionIcons: false
            property double bloxReceivedAt: Date.now()
            function dismiss() {}
        }
    }

    Component {
        id: settingsComponent
        Window {
            width: 1000
            height: 700
            visible: true
            property alias settingsSurface: settingsSurface

            Modules.SettingsWindow {
                id: settingsSurface
                objectName: "settings-window"
                anchors.fill: parent
                settingsController: settingsOwner
                windowOpen: true
            }
        }
    }

    Component {
        id: notificationsComponent
        Window {
            width: 420
            height: 360
            visible: true

            Popouts.NotificationCenterPopout {
                objectName: "notification-centre"
                x: 20
                y: 20
                maxPopoutHeight: 300
                notifications: testCase.notificationFixture
            }
        }
    }

    Component {
        id: notesComponent
        Window {
            width: 460
            height: 320
            visible: true

            Popouts.NotesPopout {
                objectName: "long-notes"
                x: 20
                y: 20
                maxPopoutWidth: 420
                maxPopoutHeight: 260
                file: "scroll-fixture.md"
                body: testCase.longNote
            }
        }
    }

    Component {
        id: clipboardComponent
        Window {
            width: 420
            height: 500
            visible: true
            property alias pickerSurface: pickerSurface

            Modules.ClipboardPicker {
                id: pickerSurface
                objectName: "clipboard-picker"
                anchors.fill: parent
                controller: clipboardOwner
                positionReady: true
                watcherHealthy: true
                targetScreen: null
                open: false
            }
        }
    }

    function cleanup() {
        closeWindow("settingsWindow");
        closeWindow("notificationWindow");
        closeWindow("notesWindow");
        closeWindow("clipboardWindow");
        clipboardPicker = null;
        clipboardOwner.items = [];
        clipboardOwner.error = "";
        if (clipboardOwner.query.length > 0) {
            clipboardOwner.query = "";
            wait(140);
            const process = clipboardQueryProcess();
            if (process && process.running)
                finishClipboardQuery(true, "", []);
            tryCompare(clipboardOwner, "loading", false, 3000);
        }
        for (let index = 0; index < notificationFixture.length; index++)
            notificationFixture[index].destroy();
        notificationFixture = [];
    }

    function closeWindow(propertyName) {
        const window = testCase[propertyName];
        if (!window)
            return;
        window.close();
        window.destroy();
        testCase[propertyName] = null;
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

    function findScrollable(item, predicate) {
        const items = descendants(item, []);
        for (let index = 0; index < items.length; index++) {
            const candidate = items[index];
            if (candidate && typeof candidate.contentY === "number"
                    && typeof candidate.contentHeight === "number"
                    && typeof candidate.height === "number"
                    && predicate(candidate))
                return candidate;
        }
        return null;
    }

    function wheel(item, targetWindow, delta) {
        const point = item.mapToItem(targetWindow.contentItem,
            Math.floor(item.width / 2), Math.floor(item.height / 2));
        mouseMove(targetWindow.contentItem, point.x, point.y);
        mouseWheel(targetWindow.contentItem, point.x, point.y,
            0, delta, Qt.NoButton, Qt.NoModifier);
    }

    function beginClipboardOpen() {
        clipboardOwner.items = [];
        clipboardOwner.error = "";
        clipboardWindow = clipboardComponent.createObject(testCase);
        verify(clipboardWindow);
        clipboardPicker = clipboardWindow.pickerSurface;
        clipboardPicker.open = true;
        clipboardWindow.requestActivate();
        tryCompare(clipboardWindow, "active", true, 3000);
        const process = clipboardQueryProcess();
        verify(process && process.running, "Opening Clipboard should start a list query");
        return process;
    }

    function openClipboard(ok, error, items) {
        beginClipboardOpen();
        finishClipboardQuery(ok !== false, error || "", items || []);
        tryCompare(clipboardOwner, "loading", false, 5000);
        wait(40);
        return clipboardPicker;
    }

    function clipboardQueryProcess() {
        return descendants(clipboardOwner, []).find(item => item && Array.isArray(item.command)
            && item.command.indexOf("list") >= 0);
    }

    function finishClipboardQuery(ok, error, items) {
        const process = clipboardQueryProcess();
        verify(process && process.stdout, "Clipboard query Process should exist");
        process.stdout.text = JSON.stringify({ok, error, items, cursor: null});
        process.stdout.streamFinished();
        process.finish(0, 0);
    }

    function makeNotifications(count) {
        const notifications = [];
        for (let index = 0; index < count; index++) {
            notifications.push(notificationObjectComponent.createObject(testCase, {
                summary: "Notification " + (index + 1),
                bloxReceivedAt: Date.now()
            }));
        }
        notificationFixture = notifications;
    }

    function clipboardItems(count) {
        return Array.from({length: count}, (_, index) => ({
            id: index + 1,
            preview: "Clipboard entry " + (index + 1),
            payload_uri: "",
            file_path: "",
            file_icon: "",
            file_size: 0,
            size: 0,
            pinned_at: null
        }));
    }

    function test_settings_detail_pane_wheel_scrolls() {
        settingsWindow = settingsComponent.createObject(testCase);
        verify(settingsWindow);
        tryCompare(settingsWindow, "visible", true);
        settingsWindow.settingsSurface.navigateTo("colours", "landing", "semantic");
        wait(80);

        const scrolls = descendants(settingsWindow, []).filter(item => item
            && typeof item.contentY === "number"
            && typeof item.contentHeight === "number");
        const overflowingScrolls = scrolls.filter(item => item.contentHeight > item.height + 1);
        const detail = overflowingScrolls.find(item => item.width >= 500);
        verify(detail, "Colours page should overflow in the Settings detail pane");

        wheel(detail, settingsWindow, -120);
        verify(detail.contentY > detail.originY);
        wheel(detail, settingsWindow, 120);
        compare(detail.contentY, detail.originY);
    }

    function test_long_notification_list_wheel_scrolls_and_returns_to_top() {
        makeNotifications(36);
        notificationWindow = notificationsComponent.createObject(testCase);
        verify(notificationWindow);
        tryCompare(notificationWindow, "visible", true);
        wait(80);

        const centre = findChild(notificationWindow, "notification-centre");
        verify(centre);
        const list = findScrollable(centre, item => item.height <= 160 && item.contentHeight > item.height + 1);
        verify(list, "Long Notifications list should expose an overflowing Flickable");
        compare(list.contentY, list.originY);

        wheel(list, notificationWindow, -120);
        verify(list.contentY > list.originY);
        verify(list.contentY <= list.originY + list.contentHeight - list.height);
        wheel(list, notificationWindow, 120);
        compare(list.contentY, list.originY);
    }

    function test_notes_long_text_moves_inside_its_editor_viewport() {
        notesWindow = notesComponent.createObject(testCase);
        verify(notesWindow);
        tryCompare(notesWindow, "visible", true);
        wait(80);

        const notes = findChild(notesWindow, "long-notes");
        verify(notes);
        const editor = findChild(notes, "notes-editor");
        const scroll = findScrollable(notes, item => item.contentHeight > item.height + 100);
        verify(scroll, "Long note should overflow the editor Flickable");
        compare(scroll.contentY, scroll.originY);

        notes.editing = true;
        wait(40);
        notesWindow.requestActivate();
        tryCompare(notesWindow, "active", true);
        editor.forceActiveFocus();
        tryCompare(editor, "activeFocus", true);
        editor.cursorPosition = 0;
        keyClick(Qt.Key_End, Qt.ControlModifier);
        verify(editor.cursorPosition > 0, "Ctrl+End should move the editor cursor into the long note");
        tryVerify(() => scroll.contentY > scroll.originY);
    }

    function test_clipboard_open_focuses_a_list_entry_or_the_empty_list() {
        const picker = openClipboard();
        compare(picker.nativeWindow, clipboardWindow);
        compare(typeof picker.active, "undefined",
            "The FloatingWindow test proxy must not inherit QWindow.active");
        compare(typeof picker.activeFocusItem, "undefined",
            "The FloatingWindow test proxy must not inherit QWindow.activeFocusItem");
        const list = findScrollable(picker, item => typeof item.itemAtIndex === "function");
        verify(list, "Clipboard history should be a ListView");
        const firstItem = list.itemAtIndex(0);
        verify(picker.nativeWindow.activeFocusItem === list
                || (firstItem && picker.nativeWindow.activeFocusItem === firstItem),
            "Opening Clipboard should give keyboard focus to the list or first entry");
    }

    function test_clipboard_does_not_replace_focus_moved_during_the_query() {
        beginClipboardOpen();
        wait(30);
        const focusTarget = descendants(clipboardPicker, []).find(item => item
            && typeof item.compact === "boolean" && item !== clipboardPicker.openFocusBaseline);
        verify(focusTarget, "Clipboard should expose a second focusable control");
        focusTarget.forceActiveFocus();
        tryVerify(() => clipboardPicker.nativeWindow.activeFocusItem === focusTarget);

        finishClipboardQuery(true, "", []);
        tryCompare(clipboardOwner, "loading", false, 5000);
        compare(clipboardPicker.nativeWindow.activeFocusItem, focusTarget,
            "The asynchronous query must not steal focus from a control the user chose");
    }

    function test_clipboard_keyboard_and_wheel_reach_real_history_rows() {
        const picker = openClipboard(true, "", clipboardItems(36));
        const list = findScrollable(picker, item => typeof item.itemAtIndex === "function");
        verify(list);

        verify(list.contentHeight > list.height);
        const firstItem = list.itemAtIndex(0);
        const secondItem = list.itemAtIndex(1);
        verify(firstItem);
        verify(secondItem);
        tryCompare(firstItem, "activeFocus", true);
        compare(clipboardOwner.selectedIndex, 0);

        keyClick(Qt.Key_Tab);
        keyClick(Qt.Key_Tab);
        tryCompare(secondItem, "activeFocus", true);
        compare(clipboardOwner.selectedIndex, 1);

        wheel(list, clipboardWindow, -120);
        verify(list.contentY > list.originY);
        wheel(list, clipboardWindow, 120);
        compare(list.contentY, list.originY);
    }

    function test_clipboard_query_failure_text_is_visible() {
        const error = "Clipboard history query failed: fixture error";
        const picker = openClipboard(false, error, []);
        const labels = descendants(picker, []).filter(item => item && item.text === error);
        verify(labels.length > 0, "The failed query should render its controller error");
        verify(labels[0].visible);
    }

    function test_clipboard_open_with_a_query_keeps_search_focused() {
        clipboardOwner.query = "fixture search";
        clipboardWindow = clipboardComponent.createObject(testCase);
        verify(clipboardWindow);
        clipboardPicker = clipboardWindow.pickerSurface;
        clipboardPicker.open = true;
        clipboardWindow.requestActivate();
        tryCompare(clipboardWindow, "active", true, 3000);
        const process = clipboardQueryProcess();
        verify(process && process.running);
        finishClipboardQuery(true, "", []);
        const search = descendants(clipboardPicker, []).find(item => item
            && item.placeholderText === "Search clipboard");
        verify(search, "Clipboard search field should be present for an existing query");
        tryCompare(search, "editorFocused", true, 1000);
        verify(clipboardPicker.searchOpen);
    }
}
