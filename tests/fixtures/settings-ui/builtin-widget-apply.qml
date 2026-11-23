import QtQuick
import Quickshell
import qs.modules
import qs.services
import qs.shared
Scope {
    id: harness
    property int phase: 0
    property int attempts: 0
    property bool requested: false
    SettingsController { id: owner; enableColdRecovery: false }
    SettingsWindow { id: window; settingsController: owner; Component.onCompleted: openWindow() }
    function check(value, message) { if (!value) throw new Error(message); }
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: {
            try {
                attempts++;
                check(attempts < 350, "Timeout phase " + phase + " " + JSON.stringify({failure:SettingsApplyController.failureMessage, operation:SettingsApplyController.operation,busy:SettingsApplyController.busy,pending:window.settingsMutationPending,editorBusy:window.themeEditorController.busy,dirty:window.themeEditorController.dirty,error:window.themeEditorController.errorMessage}));
                const editor = window.themeEditorController;
                if (!owner.settings || owner.busy || editor.busy || window.settingsMutationPending) return;
                if (phase === 0) {
                    if (!editor.themes.length) { editor.refreshThemes(true); return; }
                    if (!requested) { if (!Theme.ready) return; Theme.activeThemeId = "catppuccin-mocha";
                        window.activeWidgetsAtOpen = [{id:"clock", name:"Clock", type:"clock", enabled:false,
                            content_command:"tty-clock -s -b", left_click_command:"", right_click_command:"",
                            interval_ms:1000, visibility:"always", anchor:"centre", offset_x:0, offset_y:0,
                            width:0, height:0, shape:"auto", options:{seconds:true, bold:true}}];
                        requested = true; editor.requestSelection("catppuccin-mocha", false); return; }
                    if (!editor.candidate || editor.selectedId !== "catppuccin-mocha") return;
                    check(editor.selectedThemeBuiltin, "Fixture did not select built-in");
                    check(editor.widgetItems().length > 0, "Legacy Settings widgets were not hydrated");
                    check(!editor.dirty, "Hydration dirtied source");
                    SettingsApplyController.startApply(); phase = 1;
                } else if (phase === 1) {
                    if (window.settingsMutationPending || SettingsApplyController.busy || SettingsApplyController.operation !== "review") return;
                    check(!editor.dirty, "Clean built-in widgets became source edits");
                    check(!SettingsApplyController.failureMessage.includes("read-only"), "Apply tried saving built-in source");
                    // Review-only fixture has no installed compositor target; reset its
                    // conservative unreadable status after proving no Apply was started.
                    SettingsApplyController.operation = "status";
                    SettingsApplyController.acceptResult({version:1, ok:true, data:null});
                    const items = editor.widgetItems().map((item, index) => index === 0 ? Object.assign({}, item, {enabled: !item.enabled}) : item);
                    editor.setWidgetItems(items); phase = 2;
                } else if (phase === 2) {
                    if (!editor.candidateValid) return;
                    check(editor.dirty, "Widget toggle was not tracked");
                    SettingsApplyController.startApply(); phase = 3;
                } else if (phase === 3) {
                    if (window.settingsMutationPending || SettingsApplyController.busy || editor.dirty) return;
                    check(owner.settings.widgets.items[0].enabled === editor.widgetItems()[0].enabled, "Widget toggle not saved to Settings");
                    check(owner.settings.widgets.items[0].options.seconds && owner.settings.widgets.items[0].options.bold, "Rich options were dropped");
                    check(!SettingsApplyController.failureMessage.includes("read-only"), "Widget Apply tried saving built-in source");
                    window.discardAndClose(); window.openWindow(); Theme.activeThemeId = "catppuccin-mocha";
                    window.activeWidgetsAtOpen = [];
                    editor.requestSelection("catppuccin-mocha", false, true);
                    phase = 4;
                } else if (phase === 4) {
                    if (!editor.candidate || editor.selectedId !== "catppuccin-mocha" || !editor.widgetItems().length) return;
                    check(editor.widgetItems()[0].options.seconds && editor.widgetItems()[0].options.bold, "Reopen lost rich Settings options");
                    check(editor.widgetItems()[0].enabled === owner.settings.widgets.items[0].enabled, "Reopen lost enabled state");
                    console.log("BUILTIN WIDGET APPLY PASS: hydrated and toggled built-in widgets commit through Settings and reopen rich options without source save");
                    window.discardAndClose(); Qt.quit();
                }
            } catch (error) { console.error("BUILTIN WIDGET APPLY FAIL", String(error)); Qt.quit(); }
        }
    }
}
