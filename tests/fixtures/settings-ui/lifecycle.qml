import QtQuick
import QtTest
import Quickshell
import qs.modules
import qs.services
import qs.shared

// Real controllers and controls; every file owner runs below the fixture's temporary XDG roots.
Scope {
    id: harness
    property int phase: 0
    property bool selectionRequested: false
    property int attempts: 0
    property int beforeRevision: -1
    property string savedBytes: ""
    property var baseline: null
    property int osdPreviews: 0
    property int notificationPreviews: 0
    property string firstPosition: ""
    SettingsController { id: owner; enableColdRecovery: false }
    SettingsWindow {
        id: window
        settingsController: owner
        implicitWidth: 1320
        implicitHeight: 860
        Component.onCompleted: { openWindow(); navigateTo("bar", "landing", ""); }
    }
    TestCase { id: input; parent: window.contentItem; when: false }
    Connections {
        target: Theme
        function onOsdPositionPreviewRequested() { harness.osdPreviews++; }
        function onNotificationPositionPreviewRequested() { harness.notificationPreviews++; }
    }

    function require(value, message) {
        if (!value) throw new Error(message);
    }
    function findItem(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = findItem(child, name);
            if (found) return found;
        }
        return null;
    }
    function findText(item, text, visited) {
        const seen = visited || [];
        if (!item || seen.indexOf(item) >= 0) return null;
        seen.push(item);
        if (item.text !== undefined && item.text === text && item.clicked !== undefined) return item;
        for (const child of item.children || []) {
            const found = findText(child, text, seen);
            if (found) return found;
        }
        if (item.contentItem && item.contentItem !== item) {
            const found = findText(item.contentItem, text, seen);
            if (found) return found;
        }
        for (const child of item.data || []) {
            const found = findText(child, text, seen);
            if (found) return found;
        }
        return null;
    }
    function fileBytes() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", "file://" + Quickshell.env("XDG_CONFIG_HOME") + "/blox/settings.json", false);
        xhr.send();
        return xhr.responseText;
    }
    function liveState() {
        return {themeId: Theme.themeId, radius: Theme.radiusScale, density: Theme.densityScale,
            background: String(Theme.background), accent: String(Theme.accent), wallpaper: Theme.wallpaperSource,
            position: Theme.barPosition, separate: Theme.barSeparateGroups, border: Theme.barBorder,
            inset: Theme.barEdgeInset, barRadius: Theme.barRadiusScale, barDensity: Theme.barDensityScale,
            items: JSON.parse(JSON.stringify(Theme.barItems)), osd: Theme.osdPosition, osdX: Theme.osdOffsetX,
            osdY: Theme.osdOffsetY, notification: Theme.notificationPosition,
            notificationX: Theme.notificationOffsetX, notificationY: Theme.notificationOffsetY};
    }
    function clickCombo(name, value) {
        const control = findItem(window.captureItem, name);
        require(control !== null, "Missing control " + name);
        control.activated(control.model.indexOf(value), value);
    }
    function moveSlider(name, value) {
        const control = findItem(window.captureItem, name);
        require(control !== null, "Missing slider " + name);
        control.moved(value);
    }
    function finish() {
        console.log("LIFECYCLE PASS: draft controls preview without writes; discard restores shell; Apply preparation saves one atomic revision");
        console.log("LIFECYCLE RESULT " + JSON.stringify({draftRevision: beforeRevision, savedRevision: owner.revision,
            osdPreviews: osdPreviews, notificationPreviews: notificationPreviews,
            savedPosition: owner.settings.bar.layout.position, savedInset: owner.settings.bar.style.edgeInset,
            savedOsd: owner.settings.osd.position, savedNotification: owner.settings.notifications.position}));
        window.discardAndClose();
        Qt.quit();
    }
    Timer {
        id: steps
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            try {
                harness.attempts++;
                harness.require(harness.attempts < 300, "Timed out waiting for integration phase " + harness.phase + " state " + JSON.stringify({ready:Theme.ready, settings:!!owner.settings, ownerBusy:owner.busy, pending:window.settingsMutationPending, candidate:!!window.themeEditorController.candidate, editorBusy:window.themeEditorController.busy, applyBusy:SettingsApplyController.busy}));
                const editor = window.themeEditorController;
                if (harness.phase === 0) {
                    if (owner.settings && !owner.busy && !editor.busy && !harness.selectionRequested) {
                        harness.selectionRequested = true;
                        editor.requestSelection("midnight", false);
                    }
                    if (!Theme.ready || !owner.settings || owner.busy || window.settingsMutationPending
                            || !editor.candidate || editor.busy || SettingsApplyController.busy) return;
                    Theme.cancelPreview();
                    harness.baseline = harness.liveState();
                    harness.savedBytes = harness.fileBytes();
                    harness.beforeRevision = owner.revision;
                    window.navigateTo("bar", "landing", "");
                    editor.setShapeValue("radius_scale", 1.9);
                    editor.setShapeValue("density_scale", 1.3);
                    harness.phase = 6;
                } else if (harness.phase === 6) {
                    if (editor.busy || Math.abs(Theme.radiusScale - 1.9) > 0.001 || Math.abs(Theme.densityScale - 1.3) > 0.001) return;
                    harness.require(Theme.barRadiusAutomatic && Theme.barDensityAutomatic
                            && Math.abs(Theme.barRadiusScale - 1.9) < 0.001 && Math.abs(Theme.barDensityScale - 1.3) < 0.001,
                        "General shape preview did not update automatic live bar shape");
                    harness.phase = 1;
                } else if (harness.phase === 1) {
                    if (!harness.findItem(window.captureItem, "bar-position")) return;
                    harness.firstPosition = harness.baseline.position === "bottom" ? "top" : "bottom";
                    harness.clickCombo("bar-position", harness.firstPosition);
                    harness.moveSlider("bar-edge-inset", 11);
                    const radiusAutomatic = harness.findItem(window.captureItem, "bar-roundness-automatic");
                    const densityAutomatic = harness.findItem(window.captureItem, "bar-density-automatic");
                    harness.require(radiusAutomatic && densityAutomatic, "Automatic bar controls missing");
                    radiusAutomatic.toggled(false); densityAutomatic.toggled(false);
                    harness.moveSlider("bar-roundness", 1.7);
                    harness.moveSlider("bar-density", 1.2);
                    harness.clickCombo("osd-position", "top-left");
                    harness.clickCombo("notification-position", "bottom-left");
                    window.writeSettingsValue("osd.offsetX", 17);
                    window.writeSettingsValue("notifications.offsetY", 23);
                    harness.require(Theme.barPosition === harness.firstPosition && Theme.barEdgeInset === 11,
                        "Bar position/inset did not reach live Theme");
                    harness.require(Math.abs(Theme.barRadiusScale - 1.7) < 0.001 && Math.abs(Theme.barDensityScale - 1.2) < 0.001,
                        "Bar radius/density did not reach live Theme");
                    harness.require(Theme.osdPosition === "top-left" && Theme.osdOffsetX === 17,
                        "OSD position/offset did not reach live Theme");
                    harness.require(Theme.notificationPosition === "bottom-left" && Theme.notificationOffsetY === 23,
                        "Notification position/offset did not reach live Theme");
                    harness.require(harness.osdPreviews >= 2 && harness.notificationPreviews >= 2,
                        "OSD/notification edits did not request visible previews");
                    harness.require(Theme.previewActive && window.hasUnappliedChanges, "Draft preview not marked unapplied");
                    window.navigateTo("bar-items", "landing", "");
                    harness.phase = 2;
                } else if (harness.phase === 2) {
                    const row = harness.findItem(window.captureItem, "bar-item-clock");
                    if (!row) return;
                    const page = row.page;
                    page.beginBarDrag(row, "clock");
                    harness.require(page.barDragProxyItem.visible, "Floating drag row is missing");
                    page.moveBarDragProxy(15, 60);
                    page.setBarDropTarget("start", 0, "start:start");
                    harness.phase = 7;
                    page.barDragProxyItem.grabToImage(result => {
                        const capture = Quickshell.env("BLOX_TEST_DRAG_CAPTURE");
                        if (capture) result.saveToFile(capture);
                        harness.phase = 8;
                    });
                } else if (harness.phase === 8) {
                    const row = harness.findItem(window.captureItem, "bar-item-clock");
                    row.page.finishBarDrag();
                    const clock = Theme.barItems.find(item => item.id === "clock");
                    harness.require(clock.region === "start" && clock.order === 0, "Drag did not update live bar order");
                    harness.require(harness.fileBytes() === harness.savedBytes && owner.revision === harness.beforeRevision,
                        "Draft controls wrote persisted Settings before Apply");
                    harness.require(window.closeWindow() === "confirmation-required" && window.windowOpen,
                        "Closing draft edits bypassed confirmation");
                    harness.phase = 9;
                } else if (harness.phase === 9) {
                    const discard = harness.findText(window.captureItem, "Discard and close");
                    if (!discard) return;
                    discard.clicked();
                    harness.require(!window.windowOpen && !window.hasUnappliedChanges && !Theme.previewActive,
                        "Discard did not clear preview and draft flags");
                    harness.phase = 3;
                } else if (harness.phase === 3) {
                    harness.require(JSON.stringify(harness.liveState()) === JSON.stringify(harness.baseline),
                        "Discard did not restore the original live shell values");
                    harness.require(harness.fileBytes() === harness.savedBytes, "Discard changed saved bytes");
                    window.openWindow();
                    harness.phase = 4;
                } else if (harness.phase === 4) {
                    if (owner.busy || window.settingsMutationPending || !editor.candidate || editor.busy || SettingsApplyController.busy) return;
                    window.writeSettingsValue("bar.layout.position", harness.firstPosition);
                    window.writeSettingsValue("bar.style.edgeInset", 11);
                    window.writeSettingsValue("osd.position", "top-left");
                    window.writeSettingsValue("notifications.position", "bottom-left");
                    // This checks the Settings commit boundary, without generating/applying theme targets.
                    SettingsApplyController.selectedThemeId = "";
                    harness.require(window.prepareSettingsForApply() === false && window.applyingSettingsDraft,
                        "Apply preparation did not start an atomic Settings transaction");
                    harness.phase = 5;
                } else if (harness.phase === 5) {
                    if (owner.busy || window.applyingSettingsDraft || window.settingsMutationPending) return;
                    harness.require(owner.revision === harness.beforeRevision + 1,
                        "Apply preparation did not commit exactly one revision " + JSON.stringify({before:harness.beforeRevision, after:owner.revision,feedback:window.settingsFeedback,result:owner.typedResult}));
                    const saved = JSON.parse(harness.fileBytes());
                    harness.require(saved.bar.layout.position === harness.firstPosition && saved.bar.style.edgeInset === 11
                            && saved.osd.position === "top-left" && saved.notifications.position === "bottom-left",
                        "Apply preparation omitted edited Settings sections");
                    harness.require(Object.keys(window.draftSettingsWrites).length === 0 && !window.draftUserEdited,
                        "Apply preparation left stale draft edits");
                    steps.stop(); harness.finish();
                }
            } catch (error) {
                console.error("LIFECYCLE FAIL: " + error.message);
                steps.stop(); window.discardAndClose(); Qt.quit();
            }
        }
    }
}
