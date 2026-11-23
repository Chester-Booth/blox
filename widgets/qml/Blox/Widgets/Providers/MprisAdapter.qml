import QtQuick
import Quickshell
import Quickshell.Services.Mpris

// Loaded only when a real host opts in and has a visible music consumer.
Item {
    id: root
    property var consumers: ({})
    property int consumerCount: 0
    property int revision: 0
    signal snapshotReady(string consumerId, var envelope)
    ElapsedTimer { id: monotonic }
    Component.onCompleted: monotonic.restart()

    function selectPlayer(options) {
        const players = Mpris.players.values
        const wanted = options.player || ""
        if (wanted.length > 0) {
            for (const player of players)
                if (player.dbusName === wanted || player.identity === wanted) return player
            return null
        }
        for (const player of players) if (player.isPlaying) return player
        return players.length > 0 ? players[0] : null
    }
    function subscribe(id, options, generation) {
        if (!consumers[id] && consumerCount >= 128) return
        if (!consumers[id]) consumerCount++
        consumers[id] = {options: options, generation: generation}
        sample(id)
    }
    function unsubscribe(id) {
        if (consumers[id]) { delete consumers[id]; consumerCount-- }
    }
    function sample(id) {
        const entry = consumers[id]
        if (!entry) return
        const player = selectPlayer(entry.options)
        let value = {}
        if (player) {
            value = {title: String(player.trackTitle).slice(0, 4096),
                artist: String(player.trackArtist).slice(0, 4096),
                album: String(player.trackAlbum).slice(0, 4096),
                artUrl: entry.options.showArtwork === false ? "" : String(player.trackArtUrl).slice(0, 4096),
                positionSeconds: player.positionSupported ? player.position : null,
                lengthSeconds: player.lengthSupported ? player.length : null,
                playbackState: player.playbackState === MprisPlaybackState.Playing ? "Playing"
                    : player.playbackState === MprisPlaybackState.Paused ? "Paused" : "Stopped",
                canPlay: player.canPlay, canPause: player.canPause,
                canGoNext: player.canGoNext, canGoPrevious: player.canGoPrevious}
        }
        snapshotReady(id, {generation: entry.generation, revision: ++revision,
            observedMonotonicMs: monotonic.elapsed() * 1000,
            state: player ? "ready" : "unavailable", value: value,
            error: player ? "" : "No matching media player"})
    }
    function sampleAll() {
        for (const id of Object.keys(consumers)) sample(id)
    }
    function dispatchAction(id, action, payload) {
        const entry = consumers[id]
        const player = entry ? selectPlayer(entry.options) : null
        if (!player) return
        if (action === "playPause" && player.canTogglePlaying) player.togglePlaying()
        else if (action === "next" && player.canGoNext) player.next()
        else if (action === "previous" && player.canGoPrevious) player.previous()
        else return
        sampleAll()
    }
    Timer { interval: 1000; repeat: true; running: root.consumerCount > 0; onTriggered: root.sampleAll() }
    Connections { target: Mpris.players; function onValuesChanged() { root.sampleAll() } }
}
