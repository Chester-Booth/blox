import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Hyprland
import qs.services
import qs.shared
import "modules" as Modules
import "@SERVICES@" as Services

TestCase {
    id: testCase
    name: "LauncherFirstUse"
    when: windowShown
    property var host: null
    property var state: null
    Component {
        id: fixture
        Window {
            visible: true
            width: 1000
            height: 760
            property alias launcher: launcher
            property alias gateway: gateway
            property alias settings: settings
            Modules.Launcher { id: launcher }
            Services.SettingsController { id: settings; enableColdRecovery: false }
            Services.SettingsGateway { id: gateway; settingsController: settings }
        }
    }
    function init() {
        SettingsApplyController.quickWindowOpen = false;
        SettingsApplyController.busy = false;
        SettingsApplyController.editor = null;
        SettingsApplyController.windowOwner = null;
        SettingsApplyController.compositionProvider = null;
        SettingsApplyController.settingsProvider = null;
        SettingsApplyController.selectedThemeId = "";
        SettingsApplyController.applyState = "ready";
        SettingsApplyController.journalReleased = true;
        SettingsApplyController.recoveryAvailable = false;
        SettingsApplyController.externalRequestId = "";
        SettingsApplyController.contextResetPending = false;
        SettingsApplyController.coldApplyPending = false;
        SettingsApplyController.coldPreviewRestorePending = false;
        SettingsApplyController.coldPreviewRestored = false;
        Hyprland.activeToplevel = {lastIpcObject: {address: "0xabc", pid: 42, class: "editor", title: "Document"}};
        Quickshell.screens = [{name: "first"}, {name: "second"}];
        host = fixture.createObject(testCase);
        verify(host);
        state = host.launcher.inspectFixture();
        // Item-backed QsWindow adapters need the host's native focus window.
        for (const loader of state.loaders) loader.parent = host.contentItem;
        host.requestActivate();
        compare(host.gateway.window, null);
        for (const loader of state.loaders) {
            compare(loader.item, null);
            verify(!loader.active);
        }
    }
    function cleanup() {
        SettingsApplyController.quickWindowOpen = false;
        SettingsApplyController.busy = false;
        SettingsApplyController.editor = null;
        SettingsApplyController.windowOwner = null;
        SettingsApplyController.compositionProvider = null;
        SettingsApplyController.settingsProvider = null;
        host.close();
        host.destroy();
        host = null;
        state = null;
        wait(0);
    }
    function test_cold_owners_and_public_status_stay_alive() {
        verify(state.main && state.clipboard && state.emoji && state.paste && state.watcher && state.dmenu);
        compare(state.ipc.target, "launcher");
        compare(JSON.parse(state.ipc.status()), {surface: "idle", screen: "", clipboard_healthy: false});
        compare(state.ipc.close(), "idle");
        compare(state.loaders[0].item, null);
        // Both preloaded data owners and the native index remain eager.
        verify(findChild(state.emoji, "emoji-data-file").preload);
        verify(findChild(state.emoji, "nerd-font-data-file").blockLoading);
        const collections = state.watcher.data.filter(node => typeof node.command !== "undefined"
            && node.command.indexOf("wl-paste") >= 0);
        compare(collections.length, 3);
        for (const collection of collections) verify(collection.running);
        verify(state.dmenu.data.some(node => typeof node.stdinEnabled !== "undefined"
            && node.stdinEnabled && node.running));
    }
    function test_main_cold_focus_keyboard_close_and_reopen() {
        compare(state.ipc.main(), "main");
        const surface = state.loaders[0].item;
        verify(surface);
        const ui = surface.inspectFixture();
        tryCompare(ui.search, "activeFocus", true);
        compare(state.paste.targetAddress, "abc");
        for (const key of [Qt.Key_T, Qt.Key_E, Qt.Key_S, Qt.Key_T]) keyClick(key);
        compare(state.main.query, "test");
        compare(state.ipc.close(), "idle");
        compare(state.main.query, "");
        compare(state.ipc.main(), "main");
        compare(state.loaders[0].item, surface);
        tryCompare(ui.search, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(host.launcher.activeSurface, "idle");
        verify(findChild(state.paste, "picker-focus-restore").running);
        compare(state.loaders[1].item, null);
        compare(state.loaders[2].item, null);
    }
    function requestDmenu(query) {
        state.dmenu.busy = true;
        state.dmenu.request(["alpha", "beta", "alphabet"], "Pick", query,
            {monitor: "second", insensitive: true, lines: 4, bottom: true});
    }
    function test_dmenu_cold_query_updates_selection_and_abandon() {
        requestDmenu("alp");
        const surface = state.loaders[0].item;
        verify(surface && surface.open);
        compare(surface.targetScreen.name, "second");
        compare(state.main.query, "alp");
        compare(state.main.results.map(row => row.title), ["alpha", "alphabet"]);
        const ui = surface.inspectFixture();
        tryCompare(ui.search, "activeFocus", true);
        compare(ui.search.text, "alp");
        keyClick(Qt.Key_Down);
        compare(state.main.selectedIndex, 1);
        state.dmenu.updated(["alpha", "alpine"]);
        compare(state.main.results.map(row => row.title), ["alpha", "alpine"]);
        keyClick(Qt.Key_Return);
        compare(host.launcher.activeSurface, "idle");
        verify(!state.dmenu.busy);
        verify(!state.main.dmenuMode);
        requestDmenu("");
        compare(state.loaders[0].item, surface);
        state.dmenu.abandoned();
        compare(host.launcher.activeSurface, "idle");
        compare(state.main.dmenuPrompt, "");
    }
    function test_clipboard_cold_search_position_refresh_and_retention() {
        state.clipboard.query = "keep";
        const serial = state.clipboard.requestSerial;
        compare(state.ipc.clipboard(), "clipboard");
        const picker = state.loaders[1].item;
        verify(picker && picker.open && picker.searchOpen);
        verify(state.clipboard.requestSerial > serial);
        verify(!picker.positionReady);
        compare(picker.nativeWindow, host);
        compare(picker.controller, state.clipboard);
        compare(state.ipc.positioned("clipboard"), "clipboard");
        verify(picker.positionReady);
        compare(state.ipc.clipboard(), "idle");
        verify(!picker.openListFocusPending);
        compare(state.clipboard.query, "keep");
        state.clipboard.query = "";
        compare(state.ipc.clipboard(), "clipboard");
        compare(state.loaders[1].item, picker);
        verify(!picker.searchOpen);
        tryCompare(picker, "openListFocusPending", false);
        compare(state.ipc.close(), "idle");
        verify(!state.paste.tracking);
        verify(state.loaders[1].active);
    }
    function test_emoji_cold_preloaded_category_and_retention() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("assets/emoji.json"), false);
        request.send();
        verify(state.emoji.loadEmojiData(request.responseText));
        verify(state.emoji.emojiCount > 0);
        request.open("GET", Qt.resolvedUrl("assets/nerd-fonts.json"), false);
        request.send();
        verify(state.emoji.loadNerdFontData(request.responseText));
        state.emoji.category = "Symbols";
        verify(state.emoji.itemCount > 0);
        compare(state.ipc.emoji(), "emoji");
        const picker = state.loaders[2].item;
        verify(picker && picker.open);
        verify(picker.gridItems.length > 0);
        verify(picker.gridItems.some(row => row.kind === "heading"));
        compare(picker.controller, state.emoji);
        verify(!picker.positionReady);
        state.ipc.positioned("emoji");
        verify(picker.positionReady);
        state.ipc.emoji();
        compare(host.launcher.activeSurface, "idle");
        verify(!picker.suppressEmojiActivation);
        state.ipc.emoji();
        compare(state.loaders[2].item, picker);
        compare(state.emoji.category, "Symbols");
        state.ipc.close();
        compare(host.launcher.activeSurface, "idle");
    }
    function test_quick_apply_before_settings_first_open_retains_owners() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("settings-owner-results.json"), false);
        request.send();
        const result = JSON.parse(request.responseText).success;
        result.data.settings = {targets: {gtk: {enabled: true}}};
        host.settings.finish(result);
        SettingsApplyController.quickApply({id: "quick-theme", name: "Quick theme"});
        const quick = state.loaders[3].item;
        verify(quick && quick.visible);
        verify(host.gateway.window);
        verify(!host.gateway.window.windowOpen);
        compare(SettingsApplyController.windowOwner, host.gateway.window);
        compare(SettingsApplyController.editor, host.gateway.window.themeEditorController);
        const owner = SettingsApplyController.windowOwner;
        verify(owner.themeEditorController.settingsApplyPreviewPending);
        owner.themeEditorController.settingsApplyPreviewPending = false;
        owner.themeEditorController.settingsApplyPreviewPrepared(true, "");
        tryCompare(SettingsApplyController, "busy", true);
        compare(SettingsApplyController.operation, "review");
        SettingsApplyController.quickWindowOpen = false;
        verify(!quick.visible);
        SettingsApplyController.quickWindowOpen = true;
        compare(state.loaders[3].item, quick);
        compare(SettingsApplyController.windowOwner, owner);
        compare(state.loaders[0].item, null);
    }
}
