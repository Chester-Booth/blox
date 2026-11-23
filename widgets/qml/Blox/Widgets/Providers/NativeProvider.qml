import QtQuick

// Host opt-in adapter. Merely importing the SDK never imports native services.
Item {
    id: root
    property bool enabled: false
    property bool enableNativeMusic: false
    property var brokerCommand: []
    property var brokerEnvironment: ({})
    property var consumers: ({})
    property int musicConsumerCount: 0
    property int nativeConsumerCount: 0
    property bool brokerActivated: false
    property bool _hasBeenEnabled: false
    signal snapshotReady(string consumerId, var envelope)
    signal connectionError(string message)
    signal reconnected()
    signal actionResult(string consumerId, int generation, var result)
    signal consumerStopped(string consumerId, int generation, bool ok)
    signal hostActionRequested(string consumerId, string action, var payload)

    function unavailable(id, generation, message) {
        snapshotReady(id, {generation: generation, revision: 0, observedMonotonicMs: 0,
            state: "unavailable", value: {}, error: message})
    }
    function subscribe(id, provider, options, generation) {
        unsubscribe(id)
        if (Object.keys(consumers).length >= 128) {
            unavailable(id, generation, "Consumer limit reached")
            return
        }
        consumers[id] = {provider: provider, options: options, generation: generation}
        if (provider === "music") musicConsumerCount++
        else if (provider !== "notes" && provider !== "shortcuts") {
            nativeConsumerCount++
            brokerActivated = true
        }
        if (provider === "notes" || provider === "shortcuts") {
            const entry = consumers[id]
            Qt.callLater(function() {
                if (root.consumers[id] === entry)
                    root.snapshotReady(id, {generation: generation, revision: 1,
                        observedMonotonicMs: 0, state: "ready", value: {}, error: ""})
            })
        } else if (provider === "music") {
            if (enabled && enableNativeMusic && musicLoader.item)
                musicLoader.item.subscribe(id, options, generation)
            else unavailable(id, generation, "Native music is not enabled")
        } else if (enabled && brokerLoader.item) {
            brokerLoader.item.subscribe(id, provider, options, generation)
        } else unavailable(id, generation, "Native broker is not enabled")
    }
    function unsubscribe(id) {
        const entry = consumers[id]
        if (!entry) return
        if (entry.provider === "music" && musicLoader.item) musicLoader.item.unsubscribe(id)
        else if (brokerLoader.item) brokerLoader.item.unsubscribe(id)
        delete consumers[id]
        if (entry.provider === "music") musicConsumerCount--
        else if (entry.provider !== "notes" && entry.provider !== "shortcuts") nativeConsumerCount--
    }
    function unsubscribeAndWait(id, generation) {
        const entry = consumers[id]
        if (!entry || entry.provider !== "command" || entry.generation !== generation
                || !enabled || !brokerLoader.item) return false
        delete consumers[id]
        nativeConsumerCount--
        const accepted = brokerLoader.item.unsubscribeAndWait(id, generation)
        if (!accepted) brokerLoader.item.unsubscribe(id)
        return accepted
    }
    function dispatchAction(id, action, payload, generation, hostContext) {
        const entry = consumers[id]
        if (!entry || entry.generation !== generation) return
        if (entry.provider === "music" && musicLoader.item)
            musicLoader.item.dispatchAction(id, action, payload)
        else if (["terminal", "command"].indexOf(entry.provider) >= 0) {
            if (brokerLoader.item) brokerLoader.item.dispatchAction(id, action, payload, generation, hostContext)
        }
        else hostActionRequested(id, action, payload)
    }
    Loader {
        id: brokerLoader
        // Retain one idle broker after first use. It does no polling with no consumers.
        active: root.enabled && root.brokerActivated && root.brokerCommand.length > 0
        source: "QuickshellBroker.qml"
        onLoaded: {
            item.environment = Qt.binding(function() { return root.brokerEnvironment })
            item.snapshotReady.connect(root.snapshotReady)
            item.connectionError.connect(root.connectionError)
            item.reconnected.connect(root.reconnected)
            item.actionResult.connect(root.actionResult)
            item.consumerStopped.connect(root.consumerStopped)
            for (const id of Object.keys(root.consumers)) {
                const entry = root.consumers[id]
                if (["music", "notes", "shortcuts"].indexOf(entry.provider) < 0)
                    item.subscribe(id, entry.provider, entry.options, entry.generation)
            }
            // A non-empty command starts Process, so configure its environment and demand first.
            item.command = Qt.binding(function() { return root.brokerCommand })
        }
    }
    Loader {
        id: musicLoader
        active: root.enabled && root.enableNativeMusic && root.musicConsumerCount > 0
        source: "MprisAdapter.qml"
        onLoaded: {
            item.snapshotReady.connect(root.snapshotReady)
            for (const id of Object.keys(root.consumers)) {
                const entry = root.consumers[id]
                if (entry.provider === "music") item.subscribe(id, entry.options, entry.generation)
            }
        }
    }
    onEnabledChanged: {
        if (!enabled) connectionError("Native providers disabled")
        else {
            if (_hasBeenEnabled) reconnected()
            _hasBeenEnabled = true
        }
    }
}
