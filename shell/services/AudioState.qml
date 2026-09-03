import QtQuick

// Pure state and action model for the PipeWire provider. Keeping it free of
// plugin imports makes service-loss cases deterministic in QML tests.
Item {
    id: root

    property bool providerReady: false
    property var sink: null
    property var source: null
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool sinkReady: root.sink !== null && root.sink.ready === true && root.sink.audio !== null
    readonly property bool sourceReady: root.source !== null && root.source.ready === true && root.source.audio !== null
    readonly property bool canChange: root.providerReady && root.sinkReady
    readonly property var json: root.buildStatus()

    function volumePercent() {
        if (!root.sink || root.sink.ready !== true || !root.sink.audio)
            return 0;

        return Math.max(0, Math.round(Number(root.sink.audio.volume) * 100));
    }

    function sinkMuted() {
        return root.sink && root.sink.ready === true && root.sink.audio ? root.sink.audio.muted === true : true;
    }

    function sourceMuted() {
        return root.source && root.source.ready === true && root.source.audio ? root.source.audio.muted === true : true;
    }

    function audioIcon(volume, muted) {
        if (muted)
            return "󰝟";
        if (volume > 100)
            return "󰝝";
        if (volume < 35)
            return "󰕿";
        if (volume < 70)
            return "󰖀";
        return "󰕾";
    }

    function capability() {
        let reason = null;
        const ready = root.providerReady;
        const canChange = root.canChange;
        const permission = ready ? "not-required" : "unknown";
        if (!ready)
            reason = "provider-not-ready";
        else if (!root.sink)
            reason = "no-default-sink";
        else if (!root.sinkReady)
            reason = "device-not-ready";
        return {
            "available": true,
            "ready": ready,
            "canChange": canChange,
            "permission": permission,
            "reason": reason
        };
    }

    function buildStatus() {
        const volume = root.volumePercent();
        const muted = root.sinkMuted();
        const micMuted = root.sourceMuted();
        const capability = root.capability();
        let tooltip = "Audio provider loading";
        if (capability.ready) {
            if (root.sink && root.sink.ready === true && root.sink.audio)
                tooltip = "Volume: " + volume + "%\n" + (root.sink.description || root.sink.name || "Default sink") + "\nMic muted: " + (micMuted ? "yes" : "no");
            else
                tooltip = "Audio output unavailable";
        }
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": false,
            "errorCode": capability.reason,
            "icon": root.audioIcon(volume, muted),
            "micIcon": micMuted ? "󰍭" : "󰍬",
            "volume": volume,
            "muted": muted,
            "micMuted": micMuted,
            "micCanChange": root.providerReady && root.sourceReady,
            "tooltip": tooltip,
            "capability": capability
        };
    }

    function markChanged() {
        root.revision += 1;
        root.observedAtMs = Date.now();
    }

    function setVolume(value) {
        if (!root.canChange)
            return false;

        const next = Math.max(0, Math.min(1.5, Number(value) / 100));
        if (root.sink.audio.volume === next)
            return true;
        root.sink.audio.volume = next;
        return true;
    }

    function toggleMute() {
        if (!root.canChange)
            return false;

        root.sink.audio.muted = !root.sink.audio.muted;
        return true;
    }

    function setMicMuted(value) {
        if (!root.providerReady || !root.sourceReady)
            return false;

        const next = value === true;
        if (root.source.audio.muted === next)
            return true;
        root.source.audio.muted = next;
        return true;
    }

    onProviderReadyChanged: root.markChanged()
    onSinkChanged: root.markChanged()
    onSourceChanged: root.markChanged()
    Component.onCompleted: root.markChanged()

    Connections {
        target: root.sink
        ignoreUnknownSignals: true

        function onReadyChanged() {
            root.markChanged();
        }
    }

    Connections {
        target: root.source
        ignoreUnknownSignals: true

        function onReadyChanged() {
            root.markChanged();
        }
    }

    Connections {
        target: root.sink && root.sink.audio ? root.sink.audio : null
        ignoreUnknownSignals: true

        function onMutedChanged() {
            root.markChanged();
        }

        function onVolumeChanged() {
            root.markChanged();
        }

        function onVolumesChanged() {
            root.markChanged();
        }
    }

    Connections {
        target: root.source && root.source.audio ? root.source.audio : null
        ignoreUnknownSignals: true

        function onMutedChanged() {
            root.markChanged();
        }

        function onVolumeChanged() {
            root.markChanged();
        }

        function onVolumesChanged() {
            root.markChanged();
        }
    }
}
