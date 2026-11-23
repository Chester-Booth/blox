import QtQuick
import Quickshell
import Quickshell.Io
import Blox.Widgets 1.0
import Blox.Widgets.Providers 1.0

Scope {
    id: root
    property int stage: 0
    property int ticks: 0
    property int firstGeneration: 0
    property bool controlFinished: false
    property bool failed: false
    function fail(message) {
        if (failed) return;
        failed = true;
        console.log("MPRIS-FIXTURE-FAILED " + message);
        Qt.quit();
    }
    function control(operation) {
        controlFinished = false;
        controlProcess.command = ["python3", Quickshell.env("BLOX_MPRIS_FIXTURE"), "control", operation];
        controlProcess.running = true;
    }
    NativeProvider { id: provider; enabled: true; enableNativeMusic: true }
    Item {
        width: 640; height: 360
        WidgetHost {
            id: host
            widget: ({id: "fixture-music", kind: "music", name: "Fixture music", enabled: true,
                placement: {anchor: "top-left", x: 0, y: 0, width: 640, height: 360},
                workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
                appearance: {backgroundOpacity: 0.8, scrollbars: "auto"}, fullscreen: {enabled: true, mode: "native"},
                settings: {style: "card", player: "org.mpris.MediaPlayer2.blox_fixture", showArtwork: true}})
            provider: provider
            onSnapshotChanged: {
                if (root.stage === 0 && snapshot && snapshot.state === "ready"
                        && snapshot.value.title !== "Fixture first track")
                    root.fail("Initial readiness preceded fixture metadata: " + JSON.stringify(snapshot));
                if (root.stage === 7 && snapshot && snapshot.state === "ready"
                        && snapshot.value.title !== "Fixture hidden track")
                    root.fail("Reveal accepted old metadata: " + snapshot.value.title);
            }
        }
    }
    Process {
        id: controlProcess
        onExited: (code, status) => {
            if (code !== 0 || status !== 0) root.fail("Private fixture control failed");
            root.controlFinished = true;
        }
    }
    Timer {
        interval: 50; running: !root.failed; repeat: true
        onTriggered: {
            if (++root.ticks > 300) { root.fail("Timeout at stage " + root.stage + " phase=" + host.phase + " error=" + host.error + " snapshot=" + JSON.stringify(host.snapshot)); return; }
            const value = host.snapshot ? host.snapshot.value : {};
            if (root.stage === 0 && host.phase === "visible" && value.title === "Fixture first track"
                    && typeof value.positionSeconds === "number" && typeof value.lengthSeconds === "number") {
                if (value.artist !== "Fixture artist" || value.album !== "Fixture album" || value.playbackState !== "Paused"
                        || value.artUrl !== Quickshell.env("BLOX_MPRIS_ART_ONE") || Math.abs(value.positionSeconds - 12.5) > 0.1
                        || value.lengthSeconds !== 120 || !host.view.contentReady) { root.fail("Initial observation mismatch " + JSON.stringify(value)); return; }
                root.firstGeneration = host.revealGeneration;
                console.log("MPRIS-FIXTURE-INITIAL " + JSON.stringify(host.snapshot));
                provider.dispatchAction(host.consumerId, "playPause", {}, host.revealGeneration);
                root.stage = 1;
            } else if (root.stage === 1 && value.playbackState === "Playing") {
                provider.dispatchAction(host.consumerId, "playPause", {}, host.revealGeneration);
                root.stage = 2;
            } else if (root.stage === 2 && value.playbackState === "Paused") {
                provider.dispatchAction(host.consumerId, "next", {}, host.revealGeneration);
                root.stage = 3;
            } else if (root.stage === 3 && host.phase === "visible" && value.title === "Fixture next track"
                    && value.artUrl === Quickshell.env("BLOX_MPRIS_ART_TWO") && host.view.contentReady) {
                root.control("seek");
                root.stage = 4;
            } else if (root.stage === 4 && root.controlFinished && Math.abs(value.positionSeconds - 42) < 0.1) {
                provider.dispatchAction(host.consumerId, "previous", {}, host.revealGeneration);
                root.stage = 5;
            } else if (root.stage === 5 && host.phase === "visible" && value.title === "Fixture previous track"
                    && value.artUrl === Quickshell.env("BLOX_MPRIS_ART_ONE") && host.view.contentReady) {
                host.visible = false;
                if (host.phase !== "hidden" || host.snapshot !== null || provider.musicConsumerCount !== 0) { root.fail("Hide did not cancel music"); return; }
                root.control("hidden");
                root.stage = 6;
            } else if (root.stage === 6 && root.controlFinished) {
                if (host.snapshot !== null || provider.musicConsumerCount !== 0) { root.fail("Hidden subscription remained active"); return; }
                root.stage = 7;
                host.visible = true;
            } else if (root.stage === 7 && host.phase === "visible" && value.title === "Fixture hidden track"
                    && value.artUrl === Quickshell.env("BLOX_MPRIS_ART_TWO") && host.view.contentReady) {
                if (host.revealGeneration <= root.firstGeneration || Math.abs(value.positionSeconds - 7) > 0.1) { root.fail("Reveal was not fresh " + JSON.stringify(host.snapshot)); return; }
                console.log("MPRIS-FIXTURE-PASSED " + JSON.stringify(host.snapshot));
                Qt.quit();
            }
        }
    }
}
