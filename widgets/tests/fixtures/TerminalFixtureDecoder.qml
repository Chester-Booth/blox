import QtQuick
import Blox.Widgets.Terminal 1.0

// Tests build complete protocol grids here. Production views accept only
// validated native tokens, never ad-hoc JS cell arrays.
TerminalDecoder {
    id: root
    property var generations: ({})
    property var lastEnvelope: null
    onMessageReady: message => root.lastEnvelope = message.snapshot
    function prepare(id, generation) {
        if (generations[id] === generation) return;
        if (!subscribe(id, "terminal", generation)) throw new Error("Fixture subscription failed");
        generations[id] = generation;
    }
    function release(id) { delete generations[id]; unsubscribe(id); }
    function reset() { clear(); generations = ({}); lastEnvelope = null; }
    function adapt(id, raw) {
        const envelope = JSON.parse(JSON.stringify(raw));
        const value = envelope.value;
        envelope.generation = envelope.generation === undefined ? value.generation : envelope.generation;
        value.generation = value.generation === undefined ? envelope.generation : value.generation;
        value.sequence = value.sequence === undefined ? envelope.revision : value.sequence;
        envelope.observedMonotonicMs = envelope.observedMonotonicMs || 0;
        envelope.error = envelope.error || "";
        value.attempt = value.attempt || 1;
        const rows = [];
        for (let r = 0; r < value.rowCount; ++r) {
            const original = value.rows && value.rows[r] ? value.rows[r].runs : [];
            const runs = [];
            let column = 0;
            for (const run of original) {
                if (run.column < column) throw new Error("Fixture runs overlap");
                if (run.column > column) runs.push({column:column,cells:Array(run.column-column).fill(" ")});
                runs.push(run);
                column = run.column + run.cells.length;
            }
            if (column < value.columns) runs.push({column:column,cells:Array(value.columns-column).fill(" ")});
            rows.push({runs:runs});
        }
        value.rows = rows;
        value.rowFormat = "full-v1";
        delete value.changedRuns;
        prepare(id, envelope.generation);
        lastEnvelope = null;
        readChunk(JSON.stringify({consumerId:id,snapshot:envelope})+"\n");
        if (!lastEnvelope) throw new Error("Fixture frame was rejected");
        return lastEnvelope;
    }
}
