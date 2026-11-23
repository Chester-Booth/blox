import QtQuick
import Quickshell.Io
import Blox.Widgets.Terminal 1.0

Item {
    id: root
    property var command: []
    property var environment: ({})
    property var subscriptions: ({})
    property var actionRequests: ({})
    property var stopRequests: ({})
    property int requestSequence: 0
    property int consumerCount: 0
    property bool hasStarted: false
    property bool transportStarted: false
    signal snapshotReady(string consumerId, var envelope)
    signal connectionError(string message)
    signal reconnected()
    signal actionResult(string consumerId, int generation, var result)
    signal consumerStopped(string consumerId, int generation, bool ok)
    onConnectionError: {
        decoder.clear()
        actionRequests = ({})
        const pending = stopRequests
        stopRequests = ({})
        for (const key of Object.keys(pending)) consumerStopped(pending[key].consumerId, pending[key].generation, false)
    }

    function send(request, stopped) {
        request.requestId = ++requestSequence
        const line = JSON.stringify(request)
        if (line.length > 65536 || encodeURIComponent(line).replace(/%[0-9A-F]{2}/g, "x").length > 65536) {
            if (request.op === "action") actionResult(request.consumerId, request.generation,
                {code: "invalid_request", error: "Broker action exceeds limit"})
            else connectionError("Broker request exceeds limit")
            return false
        }
        if (transportStarted && broker.running) {
            if (request.op === "action") actionRequests[request.requestId] = {consumerId: request.consumerId, generation: request.generation}
            if (stopped) stopRequests[request.requestId] = stopped
            broker.write(line + "\n")
            return true
        }
        return false
    }
    function subscribe(id, provider, options, generation) {
        const signature = JSON.stringify(options)
        const previous = subscriptions[id]
        if (previous && previous.provider === provider && previous.signature === signature && previous.generation === generation) return
        if (!previous && Object.keys(subscriptions).length >= 128) return
        if (!decoder.subscribe(id, provider, generation)) return
        if (!previous) consumerCount++
        subscriptions[id] = {provider: provider, options: options, generation: generation, revision: -1, signature: signature}
        if (transportStarted && broker.running) send({op: "subscribe", consumerId: id, provider: provider,
            options: options, generation: generation})
        else if (command.length > 0) retry.restart()
    }
    function unsubscribe(id) {
        if (!subscriptions[id]) return
        decoder.unsubscribe(id)
        for (const key of Object.keys(actionRequests))
            if (actionRequests[key].consumerId === id) delete actionRequests[key]
        delete subscriptions[id]
        consumerCount--
        send({op: "unsubscribe", consumerId: id})
    }
    // The broker's acknowledgement follows provider.close(), including reaping.
    // Local subscription deletion alone cannot authorise a mutating workflow.
    function unsubscribeAndWait(id, generation) {
        const entry = subscriptions[id]
        if (!entry || entry.generation !== generation || !transportStarted || !broker.running
                || Object.keys(stopRequests).length >= 128) return false
        for (const key of Object.keys(actionRequests))
            if (actionRequests[key].consumerId === id) delete actionRequests[key]
        decoder.unsubscribe(id)
        delete subscriptions[id]
        consumerCount--
        return send({op: "unsubscribe", consumerId: id}, {consumerId: id, generation: generation})
    }
    function dispatchAction(id, action, payload, generation, hostContext) {
        const entry = subscriptions[id]
        if (!entry || entry.generation !== generation || !transportStarted || !broker.running) return
        if (Object.keys(actionRequests).length >= 128) {
            actionResult(id, entry.generation, {code: "busy"})
            return
        }
        const request = {op: "action", consumerId: id, generation: entry.generation, action: action, payload: payload}
        if (entry.provider === "command" && hostContext !== undefined && hostContext !== null)
            request.hostContext = hostContext
        send(request)
    }
    function readChunk(chunk) {
        decoder.readChunk(chunk)
    }
    function acceptMessage(message) {
        try {
            const entry = subscriptions[message.consumerId]
            const pending = actionRequests[message.requestId]
            const stopped = stopRequests[message.requestId]
            if (stopped) {
                delete stopRequests[message.requestId]
                consumerStopped(stopped.consumerId, stopped.generation, message.ok === true && !message.error)
            } else if (pending) {
                delete actionRequests[message.requestId]
                if (entry && pending.consumerId === message.consumerId && pending.generation === entry.generation
                        && message.generation === entry.generation)
                    actionResult(message.consumerId, entry.generation, message.error
                        ? {code: message.error.code === "unavailable" ? "unavailable" : "invalid_request",
                           error: String(message.error.message)} : message.result)
            } else if (message.op === "action") {
                // Cancelled or disconnected action responses never affect content.
            } else if (entry && message.snapshot && message.snapshot.generation === entry.generation) {
                entry.revision = Math.max(entry.revision, message.snapshot.revision)
                snapshotReady(message.consumerId, message.snapshot)
            } else if (message.error && entry && (message.generation === undefined || message.generation === entry.generation)) {
                snapshotReady(message.consumerId, {generation: entry.generation,
                    revision: ++entry.revision, observedMonotonicMs: 0,
                    state: "unavailable", value: {}, error: String(message.error.message || "Broker request failed")})
            } else if (message.error && !message.consumerId)
                connectionError(String(message.error.message || "Broker request failed"))
        } catch (error) { connectionError("Malformed broker response") }
    }
    TerminalDecoder {
        id: decoder
        objectName: "terminalDecoder"
        onMessageReady: message => root.acceptMessage(message)
        onProtocolError: message => {
            broker.running = false
            root.connectionError(message)
        }
    }
    Process {
        id: broker
        command: root.command
        environment: root.environment
        stdinEnabled: true
        running: command.length > 0
        // Terminal cell arrays stay in C++; only small metadata reaches QML.
        stdout: SplitParser { splitMarker: ""; onRead: chunk => root.readChunk(chunk) }
        stderr: SplitParser { splitMarker: ""; onRead: chunk => { /* Drain without retaining arbitrary diagnostics. */ } }
        onStarted: {
            decoder.clear()
            if (root.hasStarted) root.reconnected()
            root.hasStarted = true
            root.transportStarted = true
            for (const id of Object.keys(root.subscriptions)) {
                const entry = root.subscriptions[id]
                decoder.subscribe(id, entry.provider, entry.generation)
                root.send({op: "subscribe", consumerId: id, provider: entry.provider,
                    options: entry.options, generation: entry.generation})
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.transportStarted = false
            root.actionRequests = ({})
            root.connectionError("Widget broker exited")
            if (root.consumerCount > 0) retry.restart()
        }
    }
    Timer { id: retry; interval: 2000; onTriggered: if (root.consumerCount > 0) broker.running = true }
    Component.onDestruction: if (broker.running) send({op: "shutdown"})
}
