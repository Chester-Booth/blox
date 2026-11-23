import QtQuick
import QtTest
import Blox.Widgets 1.0
import "../fixtures" as Fixtures

TestCase {
    id: test
    name: "WidgetHost"
    when: windowShown
    visible: true
    width: 1000
    height: 700
    Fixtures.TerminalFixtureDecoder { id: terminalDecoder }

    QtObject {
        id: fakeProvider
        property var subscriptions: []
        property int cancellations: 0
        property var cancelledIds: []
        property var actions: []
        property int nextFakePid: 1000
        signal snapshotReady(string consumerId, var envelope)
        signal connectionError(string message)
        signal reconnected()
        function subscribe(id, kind, options, generation) {
            subscriptions = subscriptions.concat([{id: id, kind: kind, options: options, generation: generation,
                fakePid: kind === "terminal" ? ++nextFakePid : 0}]);
        }
        function unsubscribe(id) { cancellations++; cancelledIds = cancelledIds.concat([id]); terminalDecoder.release(id); }
        function dispatchAction(id, action, payload) { actions = actions.concat([{id: id, action: action, payload: payload}]); }
    }
    Component { id: hostComponent; WidgetHost {} }
    property var host: null
    property var secondHost: null

    function profile(kind) {
        return {id: "test-widget", kind: kind || "qml", name: "Test", enabled: true,
            placement: {anchor: "top-left", x: 20, y: 30, width: 300, height: 200},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 0.25, scrollbars: "show"},
            fullscreen: {enabled: true, mode: "native"},
            settings: {manifest: "fixture", layouts: ["native"], providers: [], settings: {}}};
    }
    function init() {
        terminalDecoder.reset();
        fakeProvider.subscriptions = [];
        fakeProvider.cancellations = 0;
        fakeProvider.cancelledIds = [];
        fakeProvider.actions = [];
        fakeProvider.nextFakePid = 1000;
        host = hostComponent.createObject(test, {widget: profile(), provider: fakeProvider,
            qmlRegistry: {fixture: {source: Qt.resolvedUrl("fixtures/TestView.qml"), layouts: ["native"], providers: []}},
            placementBounds: Qt.rect(10, 15, 900, 600)});
        verify(host !== null);
        tryCompare(host, "phase", "preparing");
        verify(host.view !== null);
    }
    function cleanup() {
        if (secondHost) { secondHost.destroy(); secondHost = null; }
        host.destroy(); host = null; wait(0);
    }
    function deliver(generation, revision, ready, state) {
        fakeProvider.snapshotReady(host.consumerId, {generation: generation, revision: revision,
            observedMonotonicMs: 12, state: state || "ready", value: {resourceReady: ready}, error: ""});
    }
    function test_constructorAndResourceGate() {
        compare(host.view.completedGeneration, host.revealGeneration);
        compare(host.phase, "preparing");
        deliver(host.revealGeneration, 1, true);
        compare(host.phase, "visible");
        compare(host.view.opacity, 1);
        compare(findChild(host, "widgetBackground").opacity, 0.25);
        deliver(host.revealGeneration, 2, false);
        compare(host.phase, "preparing");
    }
    function test_readyUpdatesDoNotHideVisibleView() {
        deliver(host.revealGeneration, 1, true);
        compare(host.phase, "visible");
        let transitions = [];
        const changed = function() { transitions.push(host.phase); };
        host.phaseChanged.connect(changed);
        for (let revision = 2; revision < 20; ++revision) deliver(host.revealGeneration, revision, true);
        host.phaseChanged.disconnect(changed);
        compare(transitions.length, 0);
        compare(host.phase, "visible");
        deliver(host.revealGeneration, 20, false);
        compare(host.phase, "preparing");
        deliver(host.revealGeneration, 21, true);
        compare(host.phase, "visible");
    }
    function test_presentationDoesNotRestartProvider() {
        const item = profile("network");
        item.settings = {interfaces: [], intervalSeconds: 2, historySize: 60};
        host.widget = item;
        tryVerify(() => fakeProvider.subscriptions.length === 1);
        deliver(host.revealGeneration, 1, true);
        tryCompare(host, "phase", "visible");
        const generation = host.revealGeneration;
        const view = host.view;
        const next = JSON.parse(JSON.stringify(item));
        next.appearance.presentation = "compact";
        next.appearance.backgroundOpacity = 0;
        host.widget = next;
        compare(host.view, view);
        compare(host.revealGeneration, generation);
        compare(fakeProvider.subscriptions.length, 1);
        compare(host.view.compactPresentation, true);
        compare(host.view.context.fullscreenEnabled, true);
        host.view.actionRequested("fullscreen", {});
        compare(fakeProvider.actions.length, 0);
        compare(findChild(host, "widgetBackground").opacity, 0);
        host.theme.radiusScale = 2;
        compare(findChild(host, "widgetBackground").radius, 24);
        host.theme.radiusScale = 0;
        compare(findChild(host, "widgetBackground").radius, 0);
    }
    function test_softwareArtworkHostRevealsOnlyCurrentPaint() {
        failOnWarning(/.*/);
        const red = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="160" height="80"><rect width="160" height="80" fill="red"/></svg>');
        const blue = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="80" height="160"><rect width="80" height="160" fill="blue"/></svg>');
        const item = profile("music");
        item.settings = {style: "compact", showArtwork: true, player: ""};
        item.appearance.presentation = "compact";
        item.appearance.backgroundOpacity = 0;
        host.theme.radiusScale = 2;
        host.widget = item;
        tryVerify(() => fakeProvider.subscriptions.length === 1);
        function publish(url, revision) {
            fakeProvider.snapshotReady(host.consumerId, {generation: host.revealGeneration, revision: revision,
                observedMonotonicMs: revision, state: "ready", value: {artUrl: url, title: "Fixture", artist: "Artist"}, error: ""});
        }
        function firstPaint(channel) {
            tryCompare(host, "phase", "visible");
            const canvas = findChild(host.view, "softwareArtwork");
            verify(canvas.ready);
            compare(String(findChild(host.view, "musicArtworkImage").source), "");
            const centre = canvas.mapToItem(host, canvas.width / 2, canvas.height / 2);
            const first = grabImage(host);
            const pixel = first.pixel(Math.floor(centre.x), Math.floor(centre.y));
            verify(channel === "red" ? pixel.r > 0.9 && pixel.b < 0.1 : pixel.b > 0.9 && pixel.r < 0.1);
            wait(20);
            verify(first.equals(grabImage(host)), "The first accepted artwork frame must match the stable frame");
            return canvas;
        }
        publish(red, 1);
        compare(host.phase, "preparing");
        compare(host.view.visible, false);
        firstPaint("red");
        publish(blue, 2);
        compare(host.phase, "preparing");
        compare(host.view.visible, false);
        const canvas = firstPaint("blue");
        const oldWidth = canvas.sourceSize.width;
        const resized = JSON.parse(JSON.stringify(item));
        resized.placement.height = 260;
        host.widget = resized;
        compare(host.phase, "preparing");
        firstPaint("blue");
        verify(canvas.sourceSize.width !== oldWidth);
        const small = JSON.parse(JSON.stringify(resized));
        small.placement.height = 48;
        host.widget = small;
        tryCompare(host.view, "artworkHasArea", false);
        tryCompare(host, "phase", "visible");
        tryVerify(() => findChild(host.view, "softwareArtwork") === null);
        compare(fakeProvider.subscriptions.length, 1);
    }
    function test_hideThenRevealRejectsOldGeneration() {
        var old = host.revealGeneration;
        deliver(old, 1, true);
        compare(host.phase, "visible");
        host.visible = false;
        compare(host.phase, "hidden");
        compare(host.snapshot, null);
        host.visible = true;
        tryCompare(host, "phase", "preparing");
        verify(host.revealGeneration > old);
        deliver(old, 100, true);
        compare(host.phase, "preparing");
        deliver(host.revealGeneration, 1, true);
        compare(host.phase, "visible");
        deliver(host.revealGeneration, 0, false);
        compare(host.phase, "visible");
    }
    function test_workspaceBoundariesAndIdentity() {
        var p = profile();
        p.workspaces = {mode: "include", ids: ["special:scratch", "named"], ranges: [[3, 5]]};
        host.widget = p;
        host.workspace = {id: 2, name: "2", special: false, empty: true};
        compare(host.phase, "hidden");
        host.workspace = {id: 3, name: "3", special: false, empty: true};
        tryCompare(host, "phase", "preparing");
        host.workspace = {id: 5, name: "5", special: false, empty: true};
        tryCompare(host, "phase", "preparing");
        host.workspace = {id: 6, name: "6", special: false, empty: true};
        compare(host.phase, "hidden");
        host.workspace = {id: -99, name: "scratch", special: true, empty: true};
        tryCompare(host, "phase", "preparing");
        host.workspace = {id: "named", name: "named", special: false, empty: true};
        tryCompare(host, "phase", "preparing");
        p = profile(); p.workspaces = {mode: "include", ids: [3], ranges: []}; host.widget = p;
        host.workspace = {id: "3", name: "3", special: false, empty: true};
        compare(host.phase, "hidden");
    }
    function test_emptySelectorsAndWorkspaceVisibility() {
        var p = profile(); p.workspaces = {mode: "include", ids: [], ranges: []}; host.widget = p;
        compare(host.phase, "hidden");
        host.editing = true;
        tryCompare(host, "phase", "preparing");
        host.editing = false;
        compare(host.phase, "hidden");
        p = profile(); p.visibility = "empty-workspace"; host.widget = p;
        host.workspace = {id: 1, name: "1", special: false, empty: false};
        compare(host.phase, "hidden");
        host.workspace = {id: 1, name: "1", special: false, empty: true};
        tryCompare(host, "phase", "preparing");
    }
    function test_fullscreenAndAnchor() {
        var p = profile(); p.placement.anchor = "bottom-right"; host.widget = p;
        compare(host.x, 590); compare(host.y, 385);
        host.fullscreen = true;
        compare(host.x, 10); compare(host.y, 15);
        compare(host.width, 900); compare(host.height, 600);
        tryCompare(host, "phase", "preparing");
        compare(host.view.context.scrollbars, "hide");
        host.fullscreen = false;
        compare(host.x, 590); compare(host.y, 385);
        tryCompare(host, "phase", "preparing");
        compare(host.view.context.scrollbars, "show");
    }
    function test_unavailableRecoversAndReconnectsFresh() {
        deliver(host.revealGeneration, 1, false, "unavailable");
        compare(host.phase, "unavailable");
        deliver(host.revealGeneration, 2, true);
        compare(host.phase, "visible");
        var old = host.revealGeneration;
        fakeProvider.connectionError("disconnected");
        compare(host.phase, "unavailable");
        deliver(old, 3, true);
        compare(host.phase, "unavailable");
        fakeProvider.reconnected();
        tryCompare(host, "phase", "preparing");
        verify(host.revealGeneration > old);
    }
    function test_providerCancellationAndFreshSubscription() {
        var p = profile("clock");
        p.settings = {style: "digital", format: "24h", showSeconds: false};
        host.widget = p;
        tryVerify(function() { return fakeProvider.subscriptions.length === 1; });
        var first = fakeProvider.subscriptions[0];
        compare(first.kind, "clock");
        compare(first.generation, host.revealGeneration);
        fakeProvider.snapshotReady(host.consumerId, {generation: first.generation, revision: 0,
            observedMonotonicMs: 15, state: "ready", value: {epochMs: 1000, hour: 1, minute: 2, second: 3}, error: ""});
        compare(host.phase, "visible");
        host.visible = false;
        compare(fakeProvider.cancellations, 1);
        compare(host.phase, "hidden");
        host.visible = true;
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        var second = fakeProvider.subscriptions[1];
        verify(second.generation > first.generation);
        fakeProvider.snapshotReady(host.consumerId, {generation: first.generation, revision: 99,
            observedMonotonicMs: 20, state: "ready", value: {epochMs: 2000, hour: 1}, error: ""});
        compare(host.phase, "preparing");
        compare(host.snapshot, null);
        fakeProvider.snapshotReady(host.consumerId, {generation: second.generation, revision: 0,
            observedMonotonicMs: 21, state: "ready", value: {epochMs: 3000, hour: 2, minute: 3, second: 4}, error: ""});
        compare(host.phase, "visible");
    }
    function test_eligibleTerminalSurvivesLayoutAndWorkspaceChanges() {
        var p = profile("terminal");
        p.settings = {workingDirectory: "", environment: {}, columns: 80, rows: 24,
            restartPolicy: "never", maxRuntimeSeconds: 0, command: ["printf", "example"]};
        p.fullscreen.mode = "resize";
        host.widget = p;
        tryVerify(function() { return fakeProvider.subscriptions.length === 1; });
        var request = fakeProvider.subscriptions[0];
        var view = host.view;
        fakeProvider.snapshotReady(request.id, terminalDecoder.adapt(request.id, {generation: request.generation, revision: 0,
            observedMonotonicMs: 15, state: "ready", value: {columns: 80, rowCount: 24, rows: []}, error: ""}));
        tryCompare(host, "phase", "visible");
        host.workspace = {id: 2, name: "2", special: false, empty: false};
        host.placementBounds = Qt.rect(0, 0, 950, 650);
        host.fullscreen = true;
        wait(30);
        compare(host.view, view);
        compare(host.revealGeneration, request.generation);
        compare(fakeProvider.subscriptions.length, 1);
        compare(fakeProvider.cancellations, 0);
        compare(fakeProvider.subscriptions[0].fakePid, request.fakePid);
        host.fullscreen = false;
        p = JSON.parse(JSON.stringify(p)); p.placement.x = 40; p.placement.width = 320; host.widget = p;
        wait(30);
        compare(host.view, view);
        compare(host.revealGeneration, request.generation);
        compare(fakeProvider.subscriptions.length, 1);
        compare(fakeProvider.cancellations, 0);
        host.visible = false;
        compare(fakeProvider.cancellations, 1);
        host.visible = true;
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        verify(fakeProvider.subscriptions[1].fakePid !== request.fakePid);
        verify(fakeProvider.subscriptions[1].generation > request.generation);
    }
    function test_nativeStyleKeepsObservation_data() {
        return [
            {tag: "system", kind: "system", settings: {style: "rings", intervalSeconds: 2, historySize: 60},
                style: "chart", viewProperty: "chart", expected: true, option: "historySize", changed: 120},
            {tag: "clock", kind: "clock", settings: {style: "digital", timezone: "local", format: "24h", showSeconds: false},
                style: "analogue", viewProperty: "analogue", expected: true, option: "timezone", changed: "UTC"},
            {tag: "calendar", kind: "calendar", settings: {style: "month", path: "/fixture/calendar.sqlite3", daysAhead: 30, maxEvents: 128},
                style: "agenda", viewProperty: "showMonth", expected: false, option: "daysAhead", changed: 60},
            {tag: "music", kind: "music", settings: {style: "card", player: "", showArtwork: false},
                style: "compact", viewProperty: "compact", expected: true, option: "showArtwork", changed: true}
        ];
    }
    function test_nativeStyleKeepsObservation(data) {
        var p = profile(data.kind); p.settings = data.settings; host.widget = p;
        tryVerify(function() { return fakeProvider.subscriptions.length === 1; });
        const generation = host.revealGeneration;
        const history = [{cpuPercent: null}, {cpuPercent: 24}];
        fakeProvider.snapshotReady(host.consumerId, {generation: generation, revision: 1, observedMonotonicMs: 1,
            state: "ready", value: {epochMs: 1000, hour: 1, minute: 2, second: 3, events: [],
                cpuPercent: 24, memoryPercent: 50, memoryUsedBytes: 1024, history: history,
                title: "Fixture", positionSeconds: 10, lengthSeconds: 60}, error: ""});
        tryCompare(host, "phase", "visible");
        const view = host.view, snapshot = host.snapshot;
        p = JSON.parse(JSON.stringify(p)); p.settings.style = data.style; host.widget = p;
        wait(0);
        compare(host.view, view); compare(host.view[data.viewProperty], data.expected);
        compare(host.phase, "visible"); compare(host.revealGeneration, generation);
        verify(host.snapshot === snapshot);
        compare(host.view.observation.history, history);
        compare(fakeProvider.subscriptions.length, 1); compare(fakeProvider.cancellations, 0);
        // A real observation option still replaces the old subscription.
        p = JSON.parse(JSON.stringify(p)); p.settings[data.option] = data.changed; host.widget = p;
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        compare(fakeProvider.cancellations, 1);
        verify(host.revealGeneration > generation); compare(host.snapshot, null);
        compare(fakeProvider.subscriptions[1].options[data.option], data.changed);
    }
    function test_managedEquivalentOptionsReuseHandle() {
        host.qmlRegistry = managedRegistry(); host.widget = managedProfile();
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        const handle = host.view.context.requestData("system", {style: "rings", historySize: 60, intervalSeconds: 2});
        compare(fakeProvider.subscriptions.length, 3);
        const equivalent = host.view.context.requestData("system", {intervalSeconds: 2, historySize: 60, style: "rings"});
        compare(equivalent, handle);
        compare(fakeProvider.subscriptions.length, 3); compare(fakeProvider.cancellations, 0);
    }
    function test_disconnectRetainsDemandAndHiddenStopsRetry() {
        var p = profile("clock"); p.settings = {style: "digital", format: "24h", showSeconds: false};
        host.widget = p;
        tryVerify(function() { return fakeProvider.subscriptions.length === 1; });
        var first = fakeProvider.subscriptions[0];
        fakeProvider.snapshotReady(first.id, {generation: first.generation, revision: 0,
            observedMonotonicMs: 15, state: "ready", value: {epochMs: 1000, hour: 1, minute: 2, second: 3}, error: ""});
        compare(host.phase, "visible");
        fakeProvider.connectionError("broker exited");
        compare(host.phase, "unavailable");
        compare(host.view, null);
        compare(fakeProvider.cancellations, 0);
        verify(host.revealGeneration > first.generation);
        fakeProvider.snapshotReady(first.id, {generation: first.generation, revision: 10,
            observedMonotonicMs: 20, state: "ready", value: {epochMs: 2000, hour: 2}, error: ""});
        compare(host.phase, "unavailable");
        fakeProvider.reconnected();
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        compare(fakeProvider.cancellations, 1);
        var second = fakeProvider.subscriptions[1];
        verify(second.generation > first.generation);
        fakeProvider.snapshotReady(second.id, {generation: second.generation, revision: 0,
            observedMonotonicMs: 25, state: "ready", value: {epochMs: 2000, hour: 2, minute: 3, second: 4}, error: ""});
        compare(host.phase, "visible");
        fakeProvider.connectionError("broker exited again");
        compare(fakeProvider.cancellations, 1);
        host.visible = false;
        compare(fakeProvider.cancellations, 2);
        fakeProvider.reconnected();
        wait(0);
        compare(fakeProvider.subscriptions.length, 2);
        compare(host.phase, "hidden");
    }
    function managedProfile() {
        var p = profile();
        p.settings = {manifest: "managed", layouts: ["native"], providers: ["clock", "music", "system"],
            settings: {requests: [{name: "clock", options: {zone: "UTC"}}, {name: "music", options: {}}]}};
        return p;
    }
    function managedRegistry() {
        return {managed: {source: Qt.resolvedUrl("fixtures/ManagedView.qml"), layouts: ["native"],
            providers: ["clock", "music", "system"]}};
    }
    function handleSnapshot(request, revision, state) {
        fakeProvider.snapshotReady(request.id, {generation: request.generation, revision: revision,
            observedMonotonicMs: 100 + revision, state: state || "ready", value: {label: request.kind}, error: ""});
    }
    function test_managedProvidersOutOfOrderAndCancellation() {
        host.qmlRegistry = managedRegistry(); host.widget = managedProfile();
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        compare(host.view.context.provider, undefined);
        var clock = fakeProvider.subscriptions[0], music = fakeProvider.subscriptions[1];
        handleSnapshot(music, 1);
        compare(host.phase, "preparing");
        handleSnapshot(clock, 1);
        compare(host.phase, "visible");
        handleSnapshot(clock, 0, "unavailable");
        compare(host.phase, "visible");
        compare(host.view.context.data.clock.revision, 1);
        compare(host.view.context.data.clock.generation, host.revealGeneration);
        compare(host.view.context.requestData("clock", {zone: "UTC"}), clock.id);
        compare(fakeProvider.subscriptions.length, 2);
        var replacement = host.view.context.requestData("clock", {zone: "Europe/London"});
        verify(replacement !== clock.id);
        verify(fakeProvider.cancelledIds.indexOf(clock.id) >= 0);
        compare(host.phase, "preparing");
        handleSnapshot(clock, 100);
        compare(host.view.context.data.clock.state, "preparing");
        handleSnapshot(fakeProvider.subscriptions[2], 1);
        compare(host.phase, "visible");
        var oldGeneration = host.revealGeneration;
        var staleRequestData = host.view.context.requestData;
        host.visible = false;
        compare(host.phase, "hidden");
        verify(fakeProvider.cancelledIds.indexOf(music.id) >= 0);
        verify(fakeProvider.cancelledIds.indexOf(replacement) >= 0);
        compare(staleRequestData("system", {}), "");
        host.visible = true;
        tryVerify(function() { return fakeProvider.subscriptions.length === 5; });
        verify(host.revealGeneration > oldGeneration);
        handleSnapshot(fakeProvider.subscriptions[2], 100);
        compare(host.phase, "preparing");
        handleSnapshot(fakeProvider.subscriptions[4], 0);
        compare(host.phase, "preparing");
        handleSnapshot(fakeProvider.subscriptions[3], 0);
        compare(host.phase, "visible");
    }
    function test_managedRequestsBelongToEachWidget() {
        host.qmlRegistry = managedRegistry(); host.widget = managedProfile();
        secondHost = hostComponent.createObject(test, {widget: managedProfile(), provider: fakeProvider,
            qmlRegistry: managedRegistry(), placementBounds: Qt.rect(0, 0, 900, 600)});
        verify(secondHost !== null);
        tryVerify(function() { return fakeProvider.subscriptions.length === 4; });
        var firstRequests = [], secondRequests = [];
        for (var i = 0; i < fakeProvider.subscriptions.length; ++i) {
            var request = fakeProvider.subscriptions[i];
            if (request.id.indexOf(host.consumerId + "-data-") === 0) firstRequests.push(request);
            else secondRequests.push(request);
            handleSnapshot(request, 0);
        }
        compare(firstRequests.length, 2); compare(secondRequests.length, 2);
        compare(host.phase, "visible"); compare(secondHost.phase, "visible");
        secondHost.view.context.requestAction("playPause", {}, "music");
        compare(fakeProvider.actions.length, 1);
        var secondMusic;
        for (var k = 0; k < secondRequests.length; ++k)
            if (secondRequests[k].kind === "music") secondMusic = secondRequests[k];
        compare(fakeProvider.actions[0].id, secondMusic.id);
        host.visible = false;
        compare(fakeProvider.cancelledIds.length, 2);
        compare(secondHost.phase, "visible");
        for (var j = 0; j < secondRequests.length; ++j) {
            verify(fakeProvider.cancelledIds.indexOf(secondRequests[j].id) < 0);
            handleSnapshot(secondRequests[j], 1);
        }
        compare(secondHost.view.context.data.clock.revision, 1);
    }
    function test_optionalProvidersDoNotBlockRequiredData() {
        var p = managedProfile();
        p.settings.settings.requests[1].required = false;
        host.qmlRegistry = managedRegistry(); host.widget = p;
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        handleSnapshot(fakeProvider.subscriptions[0], 0);
        compare(host.phase, "visible");
        handleSnapshot(fakeProvider.subscriptions[1], 0, "unavailable");
        compare(host.phase, "visible");
        compare(host.view.context.data.music.state, "unavailable");
        host.view.context.requestData("system", {});
        compare(host.phase, "preparing");
        handleSnapshot(fakeProvider.subscriptions[2], 0, "unavailable");
        compare(host.phase, "unavailable");
        handleSnapshot(fakeProvider.subscriptions[2], 1);
        compare(host.phase, "visible");
    }
    function test_undeclaredProviderIsRejected() {
        host.qmlRegistry = managedRegistry(); host.widget = managedProfile();
        tryVerify(function() { return fakeProvider.subscriptions.length === 2; });
        compare(host.view.context.requestData("files", {}), "");
        compare(host.phase, "unavailable");
        compare(fakeProvider.subscriptions.length, 2);
        compare(fakeProvider.cancelledIds.length, 2);
    }
    function test_unregisteredSourceRejected() {
        var p = profile(); p.settings.manifest = "unknown"; host.widget = p;
        tryCompare(host, "phase", "unavailable");
        compare(host.view, null);
    }
}
