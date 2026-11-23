import QtQuick
import QtQuick.Controls
import QtTest
import Blox.Widgets 1.0
import "../fixtures" as Fixtures

TestCase {
    id: test
    name: "CommandOutput"
    when: windowShown
    visible: true
    width: 1200
    height: 800

    WidgetTheme { id: widgetTheme; fontFamily: "Sans Serif"; fontSize: 32 }
    Fixtures.TerminalFixtureDecoder { id: terminalDecoder }
    QtObject {
        id: provider
        property var subscriptions: []
        property var cancellations: []
        property var actions: []
        signal snapshotReady(string consumerId, var envelope)
        signal connectionError(string message)
        signal reconnected()
        function subscribe(id, kind, options, generation) {
            subscriptions = subscriptions.concat([{id: id, kind: kind,
                options: JSON.parse(JSON.stringify(options)), generation: generation}]);
        }
        function dispatchAction(id, action, payload, generation) {
            actions = actions.concat([{id:id, action:action, payload:payload, generation:generation}]);
        }
        function unsubscribe(id) { cancellations = cancellations.concat([id]); terminalDecoder.release(id); }
    }
    Component { id: hostComponent; WidgetHost {} }
    property var host: null

    function profile() {
        return {id: "public-fixture", kind: "command", name: "Command output", enabled: true,
            placement: {anchor: "top-left", x: 20, y: 30, width: 300, height: 200, sizing: "content"},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.25, scrollbars: "show"},
            fullscreen: {enabled: true, mode: "native"},
            settings: {command: ["printf", "Public fixture"], workingDirectory: "", environment: {},
                intervalSeconds: 60, timeoutSeconds: 15, fontFamily: "", fontSize: 15, padding: 24, actions: {left: null, right: null}}};
    }
    function init() {
        failOnWarning(/.*/);
        terminalDecoder.reset();
        provider.subscriptions = [];
        provider.cancellations = [];
        provider.actions = [];
        widgetTheme.fontFamily = "Sans Serif";
        widgetTheme.densityScale = 1;
        host = hostComponent.createObject(test, {widget: profile(), provider: provider, theme: widgetTheme,
            placementBounds: Qt.rect(10, 15, 900, 600)});
        verify(host !== null);
        tryCompare(host, "phase", "preparing");
        compare(provider.subscriptions.length, 1);
    }
    function cleanup() { host.destroy(); host = null; wait(0); }
    function publish(text, revision, error, generation) {
        provider.snapshotReady(host.consumerId, {generation: generation === undefined ? host.revealGeneration : generation,
            revision: revision || 1, observedMonotonicMs: 12, state: "ready",
            value: {text: text, error: error || "", exitCode: error ? 7 : 0}, error: error || ""});
    }
    function changeProfile(change) {
        const item = JSON.parse(JSON.stringify(host.widget));
        change(item);
        host.widget = item;
    }
    function test_plainTextHistoricalDefaultsAndNaturalSize() {
        const text = "<b>Public fixture</b>\n    indented é界";
        publish(text);
        tryCompare(host, "phase", "visible");
        const output = findChild(host, "commandText");
        compare(output.text, text);
        compare(output.textFormat, Text.PlainText);
        compare(output.wrapMode, Text.NoWrap);
        compare(output.font.family, widgetTheme.fontFamily);
        compare(output.font.pixelSize, 15);
        compare(host.view.contentPadding, 24);
        compare(host.contentWidth, output.implicitWidth + 48);
        compare(host.contentHeight, output.implicitHeight + 48);
        compare(host.normalWidth, Math.ceil(host.contentWidth));
        compare(host.normalHeight, Math.ceil(host.contentHeight));
        verify(waitForRendering(host));
    }
    function test_fontAndPaddingUpdateWithoutRestartingCommand() {
        publish("Public fixture");
        const generation = host.revealGeneration;
        const view = host.view;
        const previousWidth = host.contentWidth;
        changeProfile(item => { item.settings.fontSize = 24; item.settings.padding = 0; });
        compare(host.view, view);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions.length, 1);
        compare(findChild(host, "commandText").font.pixelSize, 24);
        compare(host.view.contentPadding, 0);
        verify(host.contentWidth !== previousWidth);
        widgetTheme.fontFamily = "monospace";
        compare(findChild(host, "commandText").font.family, "monospace");
        changeProfile(item => { item.settings.fontFamily = "Serif"; });
        compare(findChild(host, "commandText").font.family, "Serif");
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions.length, 1);
    }
    function test_densityUpdatesDimensionsWithoutResubscribing_data() {
        return [{tag: "0.75", scale: 0.75}, {tag: "1", scale: 1}, {tag: "1.5", scale: 1.5}];
    }
    function test_densityUpdatesDimensionsWithoutResubscribing(row) {
        publish("Public fixture\nsecond line");
        tryCompare(host, "phase", "visible");
        const generation = host.revealGeneration, view = host.view;
        const output = findChild(host, "commandText");
        widgetTheme.densityScale = row.scale;
        compare(output.font.pixelSize, 15);
        compare(view.contentPadding, 24 * row.scale);
        compare(host.contentWidth, output.implicitWidth + 48 * row.scale);
        compare(host.contentHeight, output.implicitHeight + 48 * row.scale);
        changeProfile(item => { item.settings.fontSize = 20; item.settings.padding = 10; });
        compare(output.font.pixelSize, 20);
        compare(view.contentPadding, 10 * row.scale);
        widgetTheme.densityScale = 1;
        compare(output.font.pixelSize, 20);
        compare(view.contentPadding, 10);
        compare(host.view, view);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions.length, 1);
        compare(provider.cancellations.length, 0);
    }
    function test_fixedSizingKeepsNaturalMeasurementIndependentOfViewport() {
        changeProfile(item => { delete item.placement.sizing; });
        publish("Public fixture ".repeat(100) + "\nsecond line");
        tryCompare(host, "phase", "visible");
        const naturalWidth = host.contentWidth;
        const naturalHeight = host.contentHeight;
        compare(host.normalWidth, 300);
        compare(host.normalHeight, 200);
        changeProfile(item => { item.placement.width = 200; item.placement.height = 150; });
        compare(host.contentWidth, naturalWidth);
        compare(host.contentHeight, naturalHeight);
        compare(host.width, 200);
        compare(host.height, 150);
        compare(provider.subscriptions.length, 1);
    }
    function test_contentClampsWithinOutputBounds_data() {
        const rows = [];
        for (const anchor of ["top-left", "top-right", "bottom-left", "bottom-right", "centre"])
            for (const offset of [-2000, -20, 20, 2000])
                rows.push({tag: anchor + "/" + offset, anchor: anchor, offset: offset});
        return rows;
    }
    function test_contentClampsWithinOutputBounds(row) {
        changeProfile(item => {
            item.placement.anchor = row.anchor;
            item.placement.x = row.offset;
            item.placement.y = row.offset;
        });
        publish(("Public fixture ".repeat(100) + "\n").repeat(50));
        tryCompare(host, "phase", "visible");
        verify(host.contentWidth > host.width);
        verify(host.contentHeight > host.height);
        verify(host.x >= host.placementBounds.x);
        verify(host.y >= host.placementBounds.y);
        verify(host.x + host.width <= host.placementBounds.x + host.placementBounds.width);
        verify(host.y + host.height <= host.placementBounds.y + host.placementBounds.height);
        compare(host.width, host.normalWidth);
        compare(host.height, host.normalHeight);
        const viewport = findChild(host, "commandViewport");
        compare(viewport.contentWidth, findChild(host, "commandText").implicitWidth);
        compare(viewport.contentHeight, findChild(host, "commandText").implicitHeight);
    }
    function test_fullscreenUsesSeparateAreaAndHidesScrollbars() {
        publish("Public fixture ".repeat(100) + "\n".repeat(100));
        tryCompare(host, "phase", "visible");
        const generation = host.revealGeneration;
        const view = host.view;
        const normalWidth = host.normalWidth, normalHeight = host.normalHeight;
        const contentWidth = host.contentWidth, contentHeight = host.contentHeight;
        const placement = JSON.stringify(host.widget.placement);
        host.fullscreenBounds = Qt.rect(0, 0, 1200, 800);
        host.fullscreen = true;
        compare(host.x, 0); compare(host.y, 0);
        compare(host.width, 1200); compare(host.height, 800);
        compare(view.width, 1200); compare(view.height, 800);
        compare(host.contentWidth, contentWidth); compare(host.contentHeight, contentHeight);
        compare(host.normalWidth, normalWidth); compare(host.normalHeight, normalHeight);
        const viewport = findChild(host, "commandViewport");
        compare(viewport.ScrollBar.horizontal.policy, ScrollBar.AlwaysOff);
        compare(viewport.ScrollBar.vertical.policy, ScrollBar.AlwaysOff);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions.length, 1);
        host.fullscreen = false;
        compare(host.width, normalWidth); compare(host.height, normalHeight);
        compare(viewport.ScrollBar.horizontal.policy, ScrollBar.AlwaysOn);
        compare(viewport.ScrollBar.vertical.policy, ScrollBar.AlwaysOn);
        compare(JSON.stringify(host.widget.placement), placement);
        compare(host.view, view);
        verify(waitForRendering(host));
    }
    function test_fullscreenBoundsDefaultToPlacementBounds() {
        publish("Public fixture");
        host.fullscreen = true;
        compare(host.fullscreenBounds, host.placementBounds);
        compare(host.x, 10); compare(host.y, 15);
        compare(host.width, 900); compare(host.height, 600);
        host.placementBounds = Qt.rect(5, 7, 700, 500);
        compare(host.fullscreenBounds, host.placementBounds);
        compare(host.width, 700); compare(host.height, 500);
    }
    function test_zeroBoundsCancelAndRestoredAreaRequiresFreshResult() {
        publish("Previous public fixture");
        const generation = host.revealGeneration;
        host.placementBounds = Qt.rect(10, 15, 0, 0);
        compare(host.phase, "hidden");
        compare(provider.cancellations.length, 1);
        host.placementBounds = Qt.rect(10, 15, 900, 600);
        tryCompare(host, "phase", "preparing");
        compare(provider.subscriptions.length, 2);
        verify(host.revealGeneration > generation);
        compare(findChild(host, "commandText").text, "");
        publish("Fresh public fixture");
        tryCompare(host, "phase", "visible");
    }
    function test_failureKeepsSameGenerationOutputAndShowsError() {
        publish("Previous public fixture");
        tryCompare(host, "phase", "visible");
        publish("Previous public fixture", 2, "Command exited with code 7");
        compare(host.phase, "visible");
        compare(findChild(host, "commandText").text, "Previous public fixture");
        const label = findChild(host, "commandError");
        compare(label.visible, true);
        compare(label.text, "Command exited with code 7");
        const viewport = findChild(host, "commandViewport");
        verify(viewport.y + viewport.height <= label.y);
        publish("Fresh public fixture", 3);
        compare(label.visible, false);
        compare(host.error, "");
        compare(findChild(host, "commandText").text, "Fresh public fixture");
    }
    function test_firstFailureHasRoomForErrorAndEmptySuccessClears() {
        publish("", 1, "Command output exceeds 1 MiB");
        tryCompare(host, "phase", "visible");
        const label = findChild(host, "commandError");
        verify(host.width >= label.implicitWidth + 48);
        verify(label.height > 0);
        verify(label.y >= 24);
        publish("Public fixture", 2);
        publish("", 3);
        compare(host.phase, "visible");
        compare(findChild(host, "commandText").text, "");
        compare(label.visible, false);
    }
    function test_wrappedErrorFitsNarrowBounds_data() {
        const rows = [];
        for (const retained of [false, true])
            for (const height of [600, 70, 20])
                rows.push({tag: retained + "/" + height, retained: retained, height: height});
        return rows;
    }
    function test_wrappedErrorFitsNarrowBounds(row) {
        host.placementBounds = Qt.rect(10, 15, 100, row.height);
        changeProfile(item => { item.placement.x = 0; item.placement.y = 0; });
        const text = row.retained ? "Retained fixture" : "";
        if (row.retained) publish(text);
        publish(text, 2, "Command output exceeds 1 MiB");
        tryCompare(host, "phase", "visible");
        verify(waitForRendering(host));
        const label = findChild(host, "commandError");
        const viewport = findChild(host, "commandViewport");
        compare(label.visible, true);
        compare(findChild(host, "commandText").text, text);
        compare(label.wrapMode, Text.Wrap);
        verify(label.implicitHeight > label.font.pixelSize);
        verify(label.y >= 0);
        verify(label.height >= 0);
        verify(label.y + label.height <= host.height);
        verify(viewport.width >= 0);
        verify(viewport.height >= 0);
        verify(viewport.y + viewport.height <= label.y);
        verify(host.width <= 100);
        verify(host.height <= row.height);
        verify(host.contentHeight >= label.implicitHeight + 48);
        if (row.height === 600) {
            compare(label.height, label.implicitHeight);
            verify(label.y >= 24);
            compare(viewport.height, findChild(host, "commandText").implicitHeight);
            const naturalHeight = host.contentHeight;
            host.fullscreenBounds = Qt.rect(0, 0, 1200, 800);
            host.fullscreen = true;
            compare(host.contentHeight, naturalHeight);
            compare(viewport.height, 800 - 48 - label.implicitHeight - 8);
            verify(viewport.height > 600);
            host.fullscreen = false;
            compare(host.contentHeight, naturalHeight);
        }
        compare(provider.subscriptions.length, 1);
    }
    function test_hiddenUnsubscribesAndRevealWaitsForFreshGeneration() {
        publish("Previous public fixture");
        const old = host.revealGeneration;
        host.visible = false;
        compare(host.phase, "hidden");
        compare(host.snapshot, null);
        compare(provider.cancellations.length, 1);
        host.visible = true;
        tryCompare(host, "phase", "preparing");
        compare(provider.subscriptions.length, 2);
        verify(host.revealGeneration > old);
        compare(findChild(host, "commandText").text, "");
        publish("Old public fixture", 99, "Old error", old);
        compare(host.phase, "preparing");
        compare(findChild(host, "commandText").text, "");
        publish("Fresh public fixture");
        tryCompare(host, "phase", "visible");
        compare(findChild(host, "commandText").text, "Fresh public fixture");
    }
    function test_dataChangeStartsFreshGenerationAndRejectsOldFailure() {
        publish("Previous public fixture");
        const old = host.revealGeneration;
        changeProfile(item => { item.settings.command = ["printf", "Fresh public fixture"]; });
        tryCompare(host, "phase", "preparing");
        verify(host.revealGeneration > old);
        compare(provider.subscriptions.length, 2);
        compare(provider.cancellations.length, 1);
        publish("Previous public fixture", 99, "Command timed out", old);
        compare(host.phase, "preparing");
        publish("", 1, "Command exited with code 7");
        tryCompare(host, "phase", "visible");
        compare(findChild(host, "commandText").text, "");
    }
    SignalSpy { id: launchSpy; signalName: "applicationActionRequested" }
    SignalSpy { id: releaseSpy; signalName: "focusReleaseRequested" }
    function interactive() {
        changeProfile(item => {
            item.settings.actions = {left: {kind: "run", command: ["fixture-run"], workingDirectory: "", environment: {}, timeoutSeconds: 5},
                right: {kind: "run", command: ["fixture-right"], workingDirectory: "", environment: {}, timeoutSeconds: 5}};
            item.placement.sizing = "fixed";
            item.placement.width = 300; item.placement.height = 200;
        });
        tryCompare(host, "phase", "preparing");
        publish(("Wide public fixture ".repeat(20) + "\n").repeat(80));
        tryCompare(host, "phase", "visible");
        verify(waitForRendering(host));
    }
    function test_tapsAndKeyboardBindings() {
        interactive();
        verify(!host.view.activeFocus);
        mousePress(host.view, 60, 60, Qt.LeftButton);
        compare(provider.actions.length, 0);
        mouseRelease(host.view, 60, 60, Qt.LeftButton);
        compare(provider.actions.length, 1);
        compare(provider.actions[0].payload.button, "left");
        mouseClick(host.view, 8, 8, Qt.RightButton);
        compare(provider.actions.length, 2);
        compare(provider.actions[1].payload.button, "right");
        verify(!host.view.activeFocus);
        host.view.forceActiveFocus();
        for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space, Qt.Key_Menu]) keyClick(key);
        keyClick(Qt.Key_F10, Qt.ShiftModifier);
        compare(provider.actions.length, 7);
        compare(provider.actions.slice(2).map(item => item.payload.button).join(","), "left,left,left,right,right");
        releaseSpy.target = host; releaseSpy.clear();
        keyClick(Qt.Key_Escape);
        compare(releaseSpy.count, 1);
        verify(!host.view.activeFocus);
    }
    function test_scrollDragFullscreenAndOutsideDoNotActivate() {
        interactive();
        const viewport = findChild(host, "commandViewport");
        mouseDrag(viewport, 120, 100, -60, -60, Qt.LeftButton);
        tryVerify(() => viewport.contentY > 0);
        compare(provider.actions.length, 0);
        const beforeWheel = viewport.contentY;
        mouseWheel(viewport, 80, 80, 0, -120);
        tryVerify(() => viewport.contentY > beforeWheel);
        compare(provider.actions.length, 0);
        for (const bar of [viewport.ScrollBar.horizontal, viewport.ScrollBar.vertical]) {
            const previous = bar.position;
            mouseClick(bar, bar.width/2, bar.height/2);
            tryVerify(() => bar.position !== previous);
            mouseDrag(bar, bar.width/2, bar.height/2, bar.orientation === Qt.Horizontal ? 30 : 0,
                bar.orientation === Qt.Vertical ? 30 : 0, Qt.LeftButton);
        }
        compare(provider.actions.length, 0);
        host.view.forceActiveFocus();
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Up); keyClick(Qt.Key_Right); keyClick(Qt.Key_Left);
        keyClick(Qt.Key_PageDown); keyClick(Qt.Key_PageUp);
        compare(provider.actions.length, 0);
        const fullscreen = findChild(host, "widgetFullscreenAction");
        mouseMove(host.view, host.width - 12, 12);
        mouseClick(fullscreen, fullscreen.width/2, fullscreen.height/2);
        compare(provider.actions.length, 0);
        mouseClick(test, 1100, 750);
        compare(provider.actions.length, 0);
    }
    function test_launchOnlyAppOwnerAndCallbackInvalidation() {
        interactive();
        changeProfile(item => { item.settings.actions.right = {kind: "launch", command: ["fixture-app", "literal;arg"]}; });
        tryCompare(host, "phase", "preparing"); publish("public"); tryCompare(host, "phase", "visible");
        launchSpy.target = host; launchSpy.clear();
        host.trustedLaunchContext = {outputName:"fake-output", workspace:{id:"special:notes"}};
        host.view.actionRequested("activate", {button:"right"});
        compare(launchSpy.count, 1); compare(provider.actions.length, 0);
        compare(Object.keys(launchSpy.signalArguments[0][1]).sort().join(","), "button,consumerId,generation,widgetId");
        compare(launchSpy.signalArguments[0][2].workspace.id, "special:notes");
        host.view.actionRequested("activate", {button:"left", command:["evil"]});
        compare(provider.actions.length, 0);
        const callback = function(action, payload) { if (action === "activate") host.visible = false; };
        host.actionRequested.connect(callback);
        host.view.actionRequested("activate", {button:"left"});
        host.actionRequested.disconnect(callback);
        compare(provider.actions.length, 0);
        compare(host.phase, "hidden");
    }
    function test_callbackCannotChangeBindingOrPayloadAndEditingRejects() {
        interactive();
        const mutatePayload = function(action, payload) { payload.button = "right"; };
        host.actionRequested.connect(mutatePayload);
        host.view.actionRequested("activate", {button:"left"});
        host.actionRequested.disconnect(mutatePayload);
        compare(provider.actions.length, 1);
        compare(provider.actions[0].payload.button, "left");
        const mutateBinding = function(action, payload) { host.widget.settings.actions.left.command = ["changed"]; };
        host.actionRequested.connect(mutateBinding);
        host.view.actionRequested("activate", {button:"left"});
        host.actionRequested.disconnect(mutateBinding);
        compare(provider.actions.length, 1);
        tryCompare(host, "phase", "preparing");
        publish("Fresh public fixture");
        tryCompare(host, "phase", "visible");
        host.editing = true;
        host.view.actionRequested("activate", {button:"left"});
        compare(provider.actions.length, 1);
    }

    function test_nullBindingAndHorizontalScrollRemainIndependent() {
        interactive();
        changeProfile(item => { item.settings.actions.right = null; item.fullscreen.enabled = false; });
        tryCompare(host, "phase", "preparing");
        publish("long line ".repeat(100)); tryCompare(host, "phase", "visible");
        mouseClick(host.view, 60, 60, Qt.RightButton);
        compare(provider.actions.length, 0);
        const viewport = findChild(host, "commandViewport");
        mouseWheel(viewport, 80, 60, -120, 0);
        tryVerify(() => viewport.contentX > 0);
        compare(provider.actions.length, 0);
    }
    function test_callbackIdentity_data() {
        return ["hide", "configuration", "refresh", "disconnect", "provider"].map(change => ({tag:change,change:change}));
    }
    function test_callbackIdentity(row) {
        interactive();
        const callback = function(action, payload) {
            if (row.change === "hide") host.visible = false;
            else if (row.change === "configuration") changeProfile(item => { item.settings.actions.left.command = ["new"]; });
            else if (row.change === "refresh") host.refresh();
            else if (row.change === "disconnect") provider.connectionError("synthetic disconnect");
            else host.provider = null;
        };
        host.actionRequested.connect(callback);
        host.view.actionRequested("activate", {button:"left"});
        host.actionRequested.disconnect(callback);
        compare(provider.actions.length, 0);
    }

    function test_mutatedBindingNeedsNewSubscription_data() {
        return [{tag: "callback", callback: true}, {tag: "before-activation", callback: false}];
    }
    function test_mutatedBindingNeedsNewSubscription(row) {
        interactive();
        const generation = host.revealGeneration;
        const staleContext = host.view.context;
        const previous = provider.subscriptions.length;
        const mutate = function() { host.widget.settings.actions.left.command = ["changed"]; };
        if (row.callback) host.actionRequested.connect(mutate);
        else mutate();
        host.view.actionRequested("activate", {button:"left"});
        if (row.callback) host.actionRequested.disconnect(mutate);
        compare(provider.actions.length, 0);
        verify(host.revealGeneration > generation);
        compare(provider.cancellations.length, previous);
        // A second activation through the old view context cannot use the old binding.
        staleContext.requestAction("activate", {button:"left"});
        compare(provider.actions.length, 0);
        tryCompare(host, "phase", "preparing");
        compare(provider.subscriptions.length, previous + 1);
        compare(provider.subscriptions[previous - 1].options.actions.left.command[0], "fixture-run");
        compare(provider.subscriptions[previous].options.actions.left.command[0], "changed");
        publish("stale", 99, "", generation);
        compare(host.phase, "preparing");
        publish("fresh");
        tryCompare(host, "phase", "visible");
        host.view.actionRequested("activate", {button:"left"});
        compare(provider.actions.length, 1);
        compare(provider.actions[0].generation, host.revealGeneration);
    }

    function test_currentEligibilityNeedsFreshDecision_data() {
        const rows = [];
        for (const state of ["disabled", "selectors", "visibility", "ids", "range", "workspace-id", "workspace-empty"])
            for (const callback of [false, true])
                rows.push({tag: state + (callback ? "/callback" : "/before"), state: state, callback: callback});
        return rows;
    }

    function test_subscriptionGuardBeforeKindRouting_data() {
        const states = ["clock", "music", "system", "network", "calendar", "notes", "files",
            "shortcuts", "weather", "terminal", "qml", "unknown", "", null];
        const rows = [];
        for (const kind of states)
            for (const callback of [false, true])
                rows.push({tag: "kind-" + String(kind) + (callback ? "/callback" : "/before"),
                    state: "kind", kind: kind, callback: callback});
        for (const state of ["removed", "id", "settings", "argv", "environment", "timeout", "adapter",
                "named-workspace", "special-workspace"])
            for (const callback of [false, true])
                rows.push({tag: state + (callback ? "/callback" : "/before"), state: state, callback: callback});
        return rows;
    }

    function test_everyKindUsesSubscriptionGuard_data() {
        const kinds = ["clock", "music", "system", "network", "calendar", "notes", "files",
            "shortcuts", "weather", "terminal", "command", "qml"];
        const rows = [];
        for (const origin of kinds)
            for (const target of kinds.filter(kind => kind !== origin))
                for (const callback of [false, true])
                    rows.push({tag: origin + "/" + target + (callback ? "/callback" : "/before"),
                        origin: origin, target: target, callback: callback});
        return rows;
    }
    function test_everyKindUsesSubscriptionGuard(row) {
        const item = profile();
        item.kind = row.origin;
        item.placement.sizing = "fixed";
        item.settings.actions.left = {kind:"run", command:["fixture"], workingDirectory:"", environment:{}, timeoutSeconds:5};
        if (row.origin === "qml") {
            item.settings = {manifest:"managed", layouts:["native"], providers:["command"],
                settings:{requests:[{name:"command", options:{command:["fixture"]}}]}};
            host.qmlRegistry = {managed:{source:Qt.resolvedUrl("fixtures/ManagedView.qml"),
                layouts:["native"], providers:["command"]}};
        }
        host.widget = item;
        tryVerify(() => host.view !== null);
        const value = {text:"fixture", epochMs:0, hour:12, minute:0, second:0, temperatureC:15, events:[], entries:[],
            rows:[], columns:80, rowCount:24};
        const envelope = {generation:host.revealGeneration, revision:1, observedMonotonicMs:0,
            state:"ready", value:value, error:""};
        provider.snapshotReady(host.consumerId, row.origin === "terminal" ? terminalDecoder.adapt(host.consumerId, envelope) : envelope);
        if (row.origin === "qml") provider.snapshotReady(provider.subscriptions.slice(-1)[0].id, envelope);
        tryCompare(host, "phase", "visible");
        provider.actions = [];
        const generation = host.revealGeneration;
        const context = host.view.context;
        const cancellations = provider.cancellations.length;
        const owned = ["notes", "shortcuts"].indexOf(row.origin) >= 0 ? 0 : 1;
        let observations = 0;
        const callback = function() { observations++; if (row.callback) host.widget.kind = row.target; };
        host.actionRequested.connect(callback);
        if (!row.callback) host.widget.kind = row.target;
        context.requestAction("activate", {button:"left"});
        host.actionRequested.disconnect(callback);
        compare(provider.actions.length, 0);
        verify(host.revealGeneration > generation);
        compare(provider.cancellations.length, cancellations + owned);
        compare(host.phase, "hidden");
        compare(host.view, null);
        compare(host.snapshot, null);
        compare(observations, row.callback ? 1 : 0);
        context.requestAction("activate", {button:"left"});
        host._action("activate", {button:"left"});
        compare(provider.actions.length, 0);
    }
    function test_subscriptionGuardBeforeKindRouting(row) {
        interactive();
        if (row.state === "named-workspace" || row.state === "special-workspace") {
            host.widget.workspaces = {mode: "include", ids: [row.state === "named-workspace" ? "named" : "special:scratch"], ranges: []};
            host.workspace = {id: -1, name: row.state === "named-workspace" ? "named" : "scratch",
                special: row.state === "special-workspace", empty: true};
        }
        const originalWidget = JSON.parse(JSON.stringify(host.widget));
        const originalWorkspace = JSON.parse(JSON.stringify(host.workspace));
        const generation = host.revealGeneration;
        const context = host.view.context;
        const subscriptions = provider.subscriptions.length;
        const cancellations = provider.cancellations.length;
        let observations = 0;
        const mutate = function() {
            if (row.state === "kind") host.widget.kind = row.kind;
            else if (row.state === "removed") host.widget = null;
            else if (row.state === "id") host.widget.id = "replacement";
            else if (row.state === "settings") host.widget.settings = Object.assign({}, host.widget.settings, {command:["replacement"]});
            else if (row.state === "argv") host.widget.settings.actions.left.command[0] = "replacement";
            else if (row.state === "environment") host.widget.settings.actions.left.environment.CHANGED = "yes";
            else if (row.state === "timeout") host.widget.settings.actions.left.timeoutSeconds = 4;
            else if (row.state === "adapter") host.provider = null;
            else host.workspace.name = "other";
        };
        const callback = function() {
            observations++;
            if (row.callback) {
                // Re-entry must encounter the same guard before it can route the retained consumer.
                host.actionRequested.disconnect(callback);
                mutate();
                context.requestAction("activate", {button:"left"});
            }
        };
        host.actionRequested.connect(callback);
        if (!row.callback) mutate();
        context.requestAction("activate", {button:"left"});
        if (!row.callback) host.actionRequested.disconnect(callback);
        compare(provider.actions.length, 0);
        verify(host.revealGeneration > generation, "Every stale subscription must invalidate synchronously");
        compare(provider.cancellations.length, cancellations + 1);
        compare(host.phase, "hidden");
        compare(host.view, null);
        compare(host.snapshot, null);
        compare(observations, row.callback ? 1 : 0, "Reject stale state before notifying action observers");
        context.requestAction("activate", {button:"left"});
        host._action("activate", {button:"left"});
        publish("stale", 999, "", generation);
        compare(host.snapshot, null);
        compare(provider.actions.length, 0);
        compare(provider.subscriptions.length, subscriptions);

        host.widget = originalWidget;
        host.workspace = originalWorkspace;
        host.provider = provider;
        host.refresh();
        tryCompare(host, "phase", "preparing");
        compare(provider.subscriptions.length, subscriptions + 1);
        context.requestAction("activate", {button:"left"});
        host._action("activate", {button:"left"});
        compare(provider.actions.length, 0, "New configuration needs fresh subscription content");
        publish("fresh");
        tryCompare(host, "phase", "visible");
        context.requestAction("activate", {button:"left"});
        compare(provider.actions.length, 0);
        host.view.context.requestAction("activate", {button:"left"});
        compare(provider.actions.length, 1);
        compare(provider.actions[0].generation, host.revealGeneration);
    }
    function test_currentEligibilityNeedsFreshDecision(row) {
        interactive();
        host.workspace = {id: 1, name: "1", special: false, empty: row.state !== "visibility"};
        changeProfile(item => {
            if (row.state === "ids" || row.state === "workspace-id")
                item.workspaces = {mode: "include", ids: [1], ranges: []};
            if (row.state === "range") item.workspaces = {mode: "include", ids: [], ranges: [[1, 1]]};
            if (row.state === "workspace-empty") item.visibility = "empty-workspace";
        });
        const originalWidget = JSON.parse(JSON.stringify(host.widget));
        const originalWorkspace = JSON.parse(JSON.stringify(host.workspace));
        const generation = host.revealGeneration;
        const context = host.view.context;
        const subscriptions = provider.subscriptions.length;
        const cancellations = provider.cancellations.length;
        const mutate = function() {
            if (row.state === "disabled") host.widget.enabled = false;
            else if (row.state === "selectors") host.widget.workspaces = {mode: "include", ids: [2], ranges: []};
            else if (row.state === "visibility") host.widget.visibility = "empty-workspace";
            else if (row.state === "ids") host.widget.workspaces.ids[0] = 2;
            else if (row.state === "range") host.widget.workspaces.ranges[0][0] = 2;
            else if (row.state === "workspace-id") host.workspace.id = 2;
            else host.workspace.empty = false;
        };
        if (row.callback) host.actionRequested.connect(mutate);
        else mutate();
        context.requestAction("activate", {button: "left"});
        if (row.callback) host.actionRequested.disconnect(mutate);
        compare(provider.actions.length, 0, "First ineligible activation must not dispatch");
        // The second request exposed the callback defect even when the first was rejected.
        context.requestAction("activate", {button: "left"});
        host._action("activate", {button: "left"});
        compare(provider.actions.length, 0, "Later activation must not dispatch the old subscription");
        verify(host.revealGeneration > generation);
        compare(provider.cancellations.length, cancellations + 1);
        compare(host.phase, "hidden");
        compare(host.view, null);
        wait(0);
        compare(provider.subscriptions.length, subscriptions, "Deferred preparation must reread eligibility too");
        compare(host.phase, "hidden");
        publish("stale", 99, "", generation);
        compare(host.snapshot, null);

        host.widget = originalWidget;
        host.workspace = originalWorkspace;
        host.refresh();
        tryCompare(host, "phase", "preparing");
        context.requestAction("activate", {button: "left"});
        host._action("activate", {button: "left"});
        compare(provider.actions.length, 0);
        publish("fresh");
        tryCompare(host, "phase", "visible");
        context.requestAction("activate", {button: "left"});
        compare(provider.actions.length, 0);
        host.view.context.requestAction("activate", {button: "left"});
        compare(provider.actions.length, 1);
        compare(provider.actions[0].generation, host.revealGeneration);
        compare(provider.subscriptions.length, subscriptions + 1);
    }

    function test_launchAndControlsUseCurrentEligibility_data() {
        const rows = [];
        for (const action of ["launch", "fullscreen", "releaseFocus"])
            for (const callback of [false, true])
                rows.push({tag: action + (callback ? "/callback" : "/before"), action: action, callback: callback});
        return rows;
    }
    function test_launchAndControlsUseCurrentEligibility(row) {
        interactive();
        changeProfile(item => { item.settings.actions.right = {kind: "launch", command: ["fixture-app"]}; });
        tryCompare(host, "phase", "preparing");
        publish("fresh");
        tryCompare(host, "phase", "visible");
        launchSpy.target = host; launchSpy.clear();
        releaseSpy.target = host; releaseSpy.clear();
        const context = host.view.context;
        const generation = host.revealGeneration;
        const cancellations = provider.cancellations.length;
        const subscriptions = provider.subscriptions.length;
        const disable = function() { host.widget.enabled = false; };
        if (row.callback) host.actionRequested.connect(disable);
        else disable();
        context.requestAction(row.action === "launch" ? "activate" : row.action, {button: "right"});
        if (row.callback) host.actionRequested.disconnect(disable);
        context.requestAction("activate", {button: "left"});
        compare(provider.actions.length, 0);
        compare(launchSpy.count, 0);
        compare(releaseSpy.count, 0);
        verify(host.revealGeneration > generation);
        compare(provider.cancellations.length, cancellations + 1);
        compare(host.phase, "hidden");
        wait(0);
        compare(provider.subscriptions.length, subscriptions);
    }

    function test_currentAllowedEditsKeepSubscription() {
        interactive();
        const context = host.view.context;
        const generation = host.revealGeneration;
        const subscriptions = provider.subscriptions.length;
        const cancellations = provider.cancellations.length;
        host.widget.workspaces = {mode: "include", ids: [1], ranges: []};
        host.widget.visibility = "empty-workspace";
        host.widget.settings.padding = 10;
        host.widget.settings.fontSize = 20;
        host.widget.settings.fontFamily = "Serif";
        host.widget.appearance.backgroundOpacity = 0.8;
        host.widget.placement.x = 45;
        context.requestAction("activate", {button: "left"});
        compare(provider.actions.length, 1);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions.length, subscriptions);
        compare(provider.cancellations.length, cancellations);
    }

    function test_editingChecksCurrentStateBeforeAndAfterCallbacks_data() {
        return [{tag: "before", callback: false}, {tag: "callback", callback: true}];
    }
    function test_editingChecksCurrentStateBeforeAndAfterCallbacks(row) {
        interactive();
        const context = host.view.context;
        const generation = host.revealGeneration;
        const subscriptions = provider.subscriptions.length;
        const edit = function() { host.editing = true; };
        if (row.callback) host.actionRequested.connect(edit);
        else edit();
        context.requestAction("activate", {button: "left"});
        if (row.callback) host.actionRequested.disconnect(edit);
        context.requestAction("activate", {button: "left"});
        compare(provider.actions.length, 0);
        host.editing = false;
        context.requestAction("activate", {button: "left"});
        compare(provider.actions.length, 1);
        compare(host.revealGeneration, generation);
        compare(provider.subscriptions.length, subscriptions);
    }

    function test_homeAndEndScrollWithoutActivation_data() {
        return [{tag:"Home-overflow", key:Qt.Key_Home, end:false, overflow:true},
            {tag:"End-overflow", key:Qt.Key_End, end:true, overflow:true},
            {tag:"Home-short", key:Qt.Key_Home, end:false, overflow:false},
            {tag:"End-short", key:Qt.Key_End, end:true, overflow:false}];
    }
    function test_homeAndEndScrollWithoutActivation(row) {
        interactive();
        changeProfile(item => { item.fullscreen.enabled = false; });
        if (!row.overflow) publish("short", 2);
        const viewport = findChild(host, "commandViewport");
        host.view.forceActiveFocus();
        viewport.contentY = row.overflow ? 200 : 0;
        keyClick(row.key);
        compare(viewport.contentY, row.end ? Math.max(0, viewport.contentHeight - viewport.height) : 0);
        compare(provider.actions.length, 0);
    }

    Component {
        id: nestedControl
        FocusScope {
            width: 40; height: 40
            Button { objectName: "nestedButton"; anchors.fill: parent; text: "Test" }
        }
    }
    function test_escapeReleasesSubtreeFocus_data() {
        return ["view", "fullscreen", "scrollbar", "nested"].map(target => ({tag:target, target:target}));
    }
    function test_escapeReleasesSubtreeFocus(row) {
        interactive();
        host.view.forceActiveFocus();
        let control = host.view;
        let scope = null;
        if (row.target === "fullscreen") control = findChild(host, "widgetFullscreenAction");
        else if (row.target === "scrollbar") control = findChild(host, "commandViewport").ScrollBar.vertical;
        else if (row.target === "nested") {
            scope = createTemporaryObject(nestedControl, host.view);
            control = findChild(scope, "nestedButton");
        }
        control.forceActiveFocus();
        verify(control.activeFocus);
        releaseSpy.target = host; releaseSpy.clear();
        keyClick(Qt.Key_Escape);
        compare(releaseSpy.count, 1);
        verify(!control.activeFocus, "Escape must release the active descendant");
        verify(!control.focus);
        verify(!host.view.activeFocus);
        if (scope) verify(!scope.focus);
        keyClick(Qt.Key_Space);
        compare(provider.actions.length, 0);
    }

}
