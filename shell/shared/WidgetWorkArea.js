.pragma library

// Hyprland reports logical-pixel reservations in left, top, right, bottom order.
function bounds(width, height, externalReservations, occupiedBar) {
    // External space comes from an observation with Blox's known request removed.
    // Never read compositor totals here: they can still contain the old bar edge.
    const edges = externalReservations && externalReservations.length === 4 ? Array.from(externalReservations) : [0, 0, 0, 0];
    const barEdge = occupiedBar ? ["left", "top", "right", "bottom"].indexOf(occupiedBar.position) : -1;
    if (barEdge >= 0) edges[barEdge] += occupiedBar.extent;
    function edge(index, maximum) {
        const value = Number(edges[index]);
        return Number.isFinite(value) ? Math.max(0, Math.min(maximum, value)) : 0;
    }
    const left = edge(0, width), top = edge(1, height);
    const right = edge(2, width - left), bottom = edge(3, height - top);
    return Qt.rect(left, top, width - left - right, height - top - bottom);
}

// Only subtract the contribution recorded for this particular observation.
function externalReservations(monitors, outputs, ownReservation) {
    if (!Array.isArray(monitors)) return null;
    const edge = ["left", "top", "right", "bottom"].indexOf(ownReservation.position);
    if (edge < 0) return null;
    const result = {};
    for (const output of outputs) {
        const monitor = monitors.find(item => item.name === output);
        if (!monitor || !Array.isArray(monitor.reserved) || monitor.reserved.length !== 4
                || !monitor.reserved.every(value => typeof value === "number" && Number.isFinite(value) && value >= 0)) return null;
        const edges = monitor.reserved.slice();
        // A missing contribution means the compositor has not caught up yet.
        if (edges[edge] < ownReservation.extent) return null;
        edges[edge] -= ownReservation.extent;
        result[output] = edges;
    }
    return result;
}
