import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules
import qs.services
import qs.shared
Scope {
    id: harness
    property int phase: 0
    property int attempts: 0
    property string savedBar: ""
    property bool requested: false
    SettingsController { id: owner; enableColdRecovery: false }
    SettingsWindow { id: window; settingsController: owner; Component.onCompleted: openWindow() }
    Process {
        id: importer
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code) => {
            if (code !== 0) { console.error("IMPORT OPEN FAIL", stderr.text); Qt.quit(); return; }
            window.refreshAfterApply(true);
            window.bundleProvider.importedCard = {id: phase === 1 || phase === 3 ? "incoming" : "deferred"};
            window.bundleProvider.completeBundleImport();
            phase++;
        }
    }
    function check(value, message) { if (!value) throw new Error(message); }
    function importSource(id, accent) {
        importer.command = ["python3", Quickshell.env("BLOX_TEST_REPO") + "/tests/fixtures/settings-ui/import-open-helper.py", id, accent];
        importer.running = true;
    }
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: {
            try {
                attempts++;
                check(attempts < 400, "Timeout phase " + phase);
                const editor = window.themeEditorController;
                if (phase === 0) {
                    if (!owner.settings || owner.busy || editor.busy || SettingsApplyController.busy) return;
                    if (!requested) { requested = true; editor.requestSelection("midnight", false); return; }
                    if (!editor.candidate || editor.selectedId !== "midnight") return;
                    savedBar = JSON.stringify(owner.settings.bar);
                    phase = 1; importSource("incoming", "#abcdef");
                } else if (phase === 2 || phase === 4) {
                    const expected = phase === 2 ? "#abcdef" : "#fedcba";
                    if (editor.busy || editor.selectedId !== "incoming" || editor.candidate.colours.accent !== expected) return;
                    check(window.libraryProvider.selectedThemeId === "incoming", "Card/editor mismatch");
                    check(JSON.parse(editor.baselineJson).colours.accent === expected, "Stale baseline");
                    check(SettingsApplyController.selectedThemeId === "incoming", "Stale Apply source");
                    check(JSON.stringify(owner.settings.bar) === savedBar, "Appearance-only import changed saved bar");
                    check(Object.keys(window.draftSettingsWrites).length === 0, "Import staged unrelated Settings " + JSON.stringify({keys:Object.keys(window.draftSettingsWrites), staged:window.stagedThemeTargetsId, editor:editor.selectedId}));
                    if (phase === 2) { phase = 3; importSource("incoming", "#fedcba"); }
                    else {
                        window.writeSettingsValue("bar.style.edgeInset", 27);
                        check(!editor.dirty && window.draftUserEdited, "Settings-only draft test unexpectedly edited source");
                        phase = 5; importSource("deferred", "#aabbcc");
                    }
                } else if (phase === 6) {
                    if (window.libraryProvider.status === "loading" || editor.busy) return;
                    check(!editor.dirty && window.draftUserEdited && editor.selectedId === "incoming", "Import discarded Settings-only edits");
                    check(window.draftSettingsWrites["bar.style.edgeInset"] === 27, "Import erased unselected draft path");
                    check(window.libraryProvider.selectedThemeId === "incoming", "Dirty import changed card");
                    check(window.bundleProvider.pendingImportedThemeId === "deferred", "Missing deferred import");
                    window.discardAndClose(); phase = 7;
                } else if (phase === 7) {
                    if (editor.busy) return;
                    check(window.bundleProvider.pendingImportedThemeId === "", "Close retained callback");
                    window.openWindow(); phase = 8;
                } else if (phase === 8 && attempts > 40) {
                    if (editor.busy) return;
                    check(editor.selectedId !== "deferred" && window.libraryProvider.selectedThemeId !== "deferred", "Reopen selected deferred import");
                    console.log("IMPORT OPEN PASS: real async library/editor/Apply selection, same-ID reload, partial Settings preservation and close cancellation");
                    window.discardAndClose(); Qt.quit();
                }
            } catch (error) { console.error("IMPORT OPEN FAIL", String(error)); Qt.quit(); }
        }
    }
}
