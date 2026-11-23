import QtQuick
import QtQuick.Window
import QtTest
import qs.popouts as NativePopouts
import "../../shell/popouts" as Popouts
import "../../shell/shared" as Shared

TestCase {
    id: testCase
    name: "RemainingInteractionControls"
    when: windowShown
    property var window: null
    Component {
        id: controls
        Window {
            visible: true
            width: 680
            height: 680
            property string selectedColour: ""
            property alias colourMenu: colourMenu
            property int clockClicks: 0
            property int trayActivations: 0
            property int trayMenus: 0
            property var selectedDay: null
            property int eventOpens: 0
            property int eventMenus: 0
            property int railClicks: 0
            property int railMenus: 0
            property int trayCloses: 0
            property int trayClicks: 0
            property int saves: 0
            property int notesOwnerEscapes: 0
            property int calendarOwnerEscapes: 0
            property string savedText: ""
            property string selectedPlayer: ""
            property alias mediaControl: media
            property alias player: fakePlayer
            property alias trayEntries: menu.items
            QtObject {
                id: fakePlayer
                signal trackChanged()
                property string dbusName: "fixture.player.one"
                property string identity: "Fixture"
                property bool isPlaying: true
                property bool canSeek: true
                property bool positionSupported: true
                property bool lengthSupported: true
                property real position: 50
                property real length: 100
                property string trackTitle: "Fixture song"
                property string trackArtist: "Fixture artist"
                property string trackAlbum: ""
                property string trackArtUrl: ""
            }
            QtObject {
                id: fakeEntry
                property bool isSeparator: false
                property bool enabled: true
                property string text: "Fixture action"
                function triggered() { testCase.window.trayClicks++; }
            }
            QtObject { id: menu; property var items: [fakeEntry] }
            QtObject { id: trayItem; property string icon: ""; function activate() { testCase.window.trayActivations++; } }
            QtObject {
                id: fakeCalendar
                property date selectedDate: new Date(2026, 9, 9)
                property var events: [{key: "fixture-event", title: "Fixture event", can_edit: true, busy: false, colour: {display: "#89b4fa", calendar_fallback: "#89b4fa", event_id: "9"}, calendar: {summary: "Fixture calendar"}, time: {kind: "timed", start_ms: new Date(2026, 9, 9, 9, 0).getTime(), end_ms: new Date(2026, 9, 9, 10, 0).getTime()}}]
                property var calendars: []
                property bool simulatedChildWindowOpen: false
                property bool eventMenuOpen: false
                readonly property bool childWindowOpen: simulatedChildWindowOpen || eventMenuOpen
                property bool editorOpen: false
                property bool refreshing: false
                property var popoutNotice: null
                function snapshot() {}
                function finishNavigation() {}
                function refreshViewedDate() {}
                function createEvent() {}
                function retryNotice() {}
                function showDetails() {}
                function editEvent() {}
                function moveEventTime() {}
                function resizeEventTime() {}
                function changeEventColour() {}
                function requestDelete() {}
            }
            Shared.RailClock { objectName:"clock-control"; x:400; text:"12:00"; onClicked:testCase.window.clockClicks++ }
            Shared.TrayRailItem { objectName:"tray-control"; x:460; item:trayItem; onOpenMenu:testCase.window.trayMenus++ }
            Popouts.CalendarMonthView {
                x:380; y:40; width:280; height:300
                shownMonth:new Date(2026,9,1); selectedDate:new Date(2026,9,9); events:[]; calendars:[]
                onSelected:day=>testCase.window.selectedDay=day
            }
            Popouts.CalendarEventBlock {
                objectName:"calendar-event"; x:380; y:360; width:200; height:40
                event:({title:"Fixture event",colour:{display:"#ffffff",calendar_fallback:"#ffffff"}})
                onOpened:testCase.window.eventOpens++
                onMenuRequested:testCase.window.eventMenus++
            }
            Popouts.CalendarDayView {
                x:380; y:410; width:280; height:180
                selectedDate:new Date(2026,9,9); events:[]
                onSelected:day=>testCase.window.selectedDay=day
            }
            Popouts.CalendarEventMenu {
                id:colourMenu
                event:({can_edit:true,busy:false,colour:{event_id:"1"}})
                onColourRequested:(event,id)=>testCase.window.selectedColour=id
            }
            Shared.RailButton {
                objectName: "rail-control"
                onClicked: testCase.window.railClicks++
                onRightClicked: testCase.window.railMenus++
            }
            Popouts.TrayMenuPopout { objectName:"tray-menu"; y: 40; menuHandle: menu; onCloseRequested:testCase.window.trayCloses++ }
            Item {
                anchors.fill: parent
                Keys.onEscapePressed: event => {
                    testCase.window.notesOwnerEscapes++;
                    event.accepted = true;
                }
                Popouts.NotesPopout {
                    objectName: "notes"
                    y: 100
                    file: "fixture.md"
                    body: "Private fixture text"
                    onSave: (file, body) => { testCase.window.saves++; testCase.window.savedText = body; }
                }
            }
            Item {
                anchors.fill: parent
                Keys.onEscapePressed: event => {
                    testCase.window.calendarOwnerEscapes++;
                    event.accepted = true;
                }
                NativePopouts.CalendarPopout {
                    objectName: "calendar-popout"
                    x: 10
                    y: 10
                    controller: fakeCalendar
                }
            }
            Popouts.MediaPlayer {
                id: media
                y: 340
                width: 350
                Component.onCompleted: mediaPlayers = [fakePlayer, {dbusName: "fixture.player.two", isPlaying: false}]
                onSelectPlayer: name => testCase.window.selectedPlayer = name
            }
        }
    }
    function init() { window = controls.createObject(testCase); verify(window); wait(20); }
    function cleanup() { if (window) { window.close(); window.destroy(); window = null; } }
    function lookup(item, name) {
        if (item.objectName === name) return item;
        const children = item.children || [];
        for (let i = 0; i < children.length; i++) {
            const found = lookup(children[i], name);
            if (found) return found;
        }
        return null;
    }
    function control(name) { return lookup(window.contentItem, name); }
    function findCalendarEventBlock(item) {
        if (item && item.event && item.event.key === "fixture-event" && typeof item.menuRequested === "function")
            return item;
        const children = item && item.children ? item.children : [];
        for (let i = 0; i < children.length; i++) {
            const found = findCalendarEventBlock(children[i]);
            if (found)
                return found;
        }
        return null;
    }
    function press(name, key) {
        const item = control(name);
        verify(item, name);
        item.forceActiveFocus();
        tryCompare(item, "activeFocus", true);
        keyClick(key);
        wait(20);
        return item;
    }
    function test_rail_keyboard_click_and_context() {
        press("rail-control", Qt.Key_Space);
        compare(window.railClicks, 1);
        press("rail-control", Qt.Key_Menu);
        compare(window.railMenus, 1);
    }
    function test_tray_keyboard_action_and_disabled_guard() {
        const entry = press("tray-menu-entry-0", Qt.Key_Return);
        compare(window.trayClicks, 1);
        entry.enabled = false;
        entry.activate();
        compare(window.trayClicks, 1);
    }
    function test_notes_keyboard_edit_and_save_preserves_text() {
        press("notes-edit", Qt.Key_Space);
        verify(control("notes").editing);
        press("notes-save", Qt.Key_Return);
        compare(window.saves, 1);
        compare(window.savedText, "Private fixture text");
        control("notes").saveBusy = true;
        verify(!control("notes-save").enabled);
    }
    function test_notes_escape_bubbles_when_clean_and_stays_for_dirty_draft() {
        const notes = control("notes");
        let editButton = control("notes-edit");
        editButton.forceActiveFocus();
        tryCompare(editButton, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(window.notesOwnerEscapes, 1);

        notes.editing = true;
        wait(20);
        const editor = control("notes-editor");
        editor.text = "Unsaved private draft";
        editor.forceActiveFocus();
        tryCompare(editor, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(notes.editing, true);
        compare(editor.text, "Unsaved private draft");
        compare(window.notesOwnerEscapes, 1);

        notes.editing = false;
        wait(20);
        editButton = control("notes-edit");
        editButton.forceActiveFocus();
        tryCompare(editButton, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(window.notesOwnerEscapes, 1);

        notes.body = notes.draftBody;
        editButton = control("notes-edit");
        editButton.forceActiveFocus();
        tryCompare(editButton, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(window.notesOwnerEscapes, 2);
    }
    function test_calendar_child_escape_is_kept_by_calendar_owner() {
        const calendar = control("calendar-popout");
        calendar.forceActiveFocus();
        tryCompare(calendar, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(window.calendarOwnerEscapes, 1);

        window.calendarOwnerEscapes = 0;
        calendar.controller.simulatedChildWindowOpen = true;
        calendar.forceActiveFocus();
        tryCompare(calendar, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(calendar.controller.childWindowOpen, true);
        compare(window.calendarOwnerEscapes, 0);

        calendar.controller.simulatedChildWindowOpen = false;
        calendar.viewIndex = 1;
        wait(20);
        const eventBlock = findCalendarEventBlock(calendar);
        verify(eventBlock);
        eventBlock.menuRequested(eventBlock.event, Qt.point(eventBlock.width / 2, eventBlock.height / 2));
        tryCompare(calendar.controller, "eventMenuOpen", true);
        keyClick(Qt.Key_Escape);
        tryCompare(calendar.controller, "eventMenuOpen", false);
        tryCompare(calendar.controller, "childWindowOpen", false);
        compare(window.calendarOwnerEscapes, 0);
    }
    function test_clock_and_tray_keyboard_routes() {
        press("clock-control",Qt.Key_Return); compare(window.clockClicks,1);
        press("tray-control",Qt.Key_Space); compare(window.trayActivations,1);
        press("tray-control",Qt.Key_Menu); compare(window.trayMenus,1);
    }
    function test_calendar_date_and_event_keyboard_routes() {
        const day=press("calendar-day-11",Qt.Key_Space);
        compare(window.selectedDay.getTime(),day.day.getTime());
        press("calendar-event",Qt.Key_Return); compare(window.eventOpens,1);
        press("calendar-event",Qt.Key_Menu); compare(window.eventMenus,1);
    }
    function test_calendar_week_and_colour_keyboard_routes() {
        const day=press("calendar-week-day-3",Qt.Key_Return);
        compare(window.selectedDay.getTime(),day.day.getTime());
        window.colourMenu.open();
        wait(20);
        verify(window.colourMenu.activeFocus);
        const colour=lookup(window.colourMenu.contentItem,"calendar-event-colour-9");
        verify(colour);
        colour.forceActiveFocus();
        tryCompare(colour,"activeFocus",true);
        keyClick(Qt.Key_Space);
        tryCompare(window,"selectedColour","9");
        window.colourMenu.event=({can_edit:true,busy:true,colour:{event_id:"1"}});
        verify(!colour.enabled);
    }
    function test_tray_context_initial_focus_and_escape() {
        control("tray-menu").keyboardOpen=true;
        tryCompare(control("tray-menu").rootPanel,"activeFocus",true);
        compare(control("tray-menu").rootPanel.selectedIndex, -1);
        verify(!control("tray-menu-scrollbar").visible);
        keyClick(Qt.Key_Escape);
        compare(window.trayCloses,1);
    }
    function test_medium_tray_menu_uses_available_screen_height() {
        const tray = control("tray-menu");
        const scroll = control("tray-menu-scroll");
        const original = window.trayEntries[0];
        window.trayEntries = Array.from({length:15}, () => original);
        wait(20);
        verify(tray.maximumHeight > 420);
        verify(tray.height > 420);
        verify(scroll.contentHeight <= scroll.height);
        verify(!control("tray-menu-scrollbar").visible);
    }
    function test_long_tray_menu_scrolls_and_keeps_focus_visible() {
        const tray=control("tray-menu-entry-0");
        const scroll=control("tray-menu-scroll");
        const original=window.trayEntries[0];
        window.trayEntries=Array.from({length:30},()=>original);
        wait(20);
        verify(scroll.contentHeight>scroll.height);
        verify(control("tray-menu-scrollbar").visible);
        press("tray-menu-scroll",Qt.Key_End);
        compare(scroll.contentY,scroll.contentHeight-scroll.height);
        press("tray-menu-scroll",Qt.Key_Home); compare(scroll.contentY,0);
        press("tray-menu-entry-29",Qt.Key_Space);
        verify(scroll.contentY>0);
    }
    function test_media_keyboard_seek_clamps_and_selects_correct_player() {
        press("media-seek", Qt.Key_Right);
        compare(window.player.position, 55);
        press("media-seek", Qt.Key_End);
        compare(window.player.position, 100);
        press("media-seek", Qt.Key_Right);
        compare(window.player.position, 100);
        press("media-player-1", Qt.Key_Space);
        compare(window.selectedPlayer, "fixture.player.two");
        window.player.canSeek = false;
        verify(!control("media-seek").enabled);
        compare(window.mediaControl.seekDisabledReason, "This player does not support seeking.");
        window.player.canSeek = true;
        window.player.lengthSupported = false;
        verify(!control("media-seek").enabled);
        compare(window.mediaControl.seekDisabledReason, "The track length is unavailable.");
    }
    function test_calendar_read_only_event_explains_disabled_actions() {
        const reason = "This calendar is read-only or not locally allowed.";
        window.colourMenu.event = {can_edit: false, busy: false, capability_reason: reason, colour: {event_id: "1"}};

        const edit = lookup(window.colourMenu.contentItem, "calendar-event-edit");
        const remove = lookup(window.colourMenu.contentItem, "calendar-event-delete");
        verify(edit);
        verify(remove);
        verify(!edit.enabled);
        verify(!remove.enabled);
        compare(window.colourMenu.actionDisabledReason, reason);

        const swatch = lookup(window.colourMenu.contentItem, "calendar-event-colour-9");
        const swatchTarget = lookup(window.colourMenu.contentItem, "calendar-event-colour-target-9");
        verify(swatch);
        verify(swatchTarget);
        const reasonTooltip = swatchTarget.reasonTooltip;
        verify(reasonTooltip);
        verify(!swatch.enabled);
        reasonTooltip.delay = 0;
        window.colourMenu.open();
        wait(20);
        const point = swatchTarget.mapToItem(window.contentItem,
            Math.floor(swatchTarget.width / 2), Math.floor(swatchTarget.height / 2));
        mouseMove(window.contentItem, point.x, point.y);
        tryCompare(reasonTooltip, "shown", true);
        compare(reasonTooltip.text, reason);
        tryCompare(reasonTooltip, "opened", true);

        window.colourMenu.event = {can_edit: true, busy: true, capability_reason: "", colour: {event_id: "1"}};
        compare(window.colourMenu.actionDisabledReason, "Event update in progress.");
        compare(reasonTooltip.text, "Event update in progress.");
    }
}
