.pragma library

var serial = 0;
function consumerId() { return "widget-host-" + (++serial); }

// Numeric IDs remain distinct from named workspaces, including numeric names.
function matches(selectors, workspace) {
    if (!selectors || !workspace) return false;
    if (selectors.mode === "all") return true;
    if (selectors.mode !== "include") return false;
    var ids = selectors.ids || [];
    for (var i = 0; i < ids.length; ++i) {
        var id = ids[i];
        if (typeof id === "number" && typeof workspace.id === "number" && id === workspace.id)
            return true;
        if (typeof id === "string") {
            if (typeof workspace.id === "string" && id === workspace.id) return true;
            if (typeof workspace.name === "string" && id === workspace.name) return true;
            // Hosts may expose a special identity as a string or a named special flag.
            if (typeof workspace.special === "string" && id === workspace.special) return true;
            if (workspace.special && typeof workspace.name === "string"
                    && id === "special:" + workspace.name.replace(/^special:/, "")) return true;
        }
    }
    if (typeof workspace.id !== "number" || workspace.special) return false;
    var ranges = selectors.ranges || [];
    for (var j = 0; j < ranges.length; ++j) {
        if (workspace.id >= ranges[j][0] && workspace.id <= ranges[j][1]) return true;
    }
    return false;
}

function geometry(placement, bounds, fullscreen, content, fullscreenBounds) {
    if (fullscreen) {
        var full = fullscreenBounds || bounds;
        return {x: full.x, y: full.y, width: full.width, height: full.height};
    }
    var p = placement || {};
    var w = p.width || 1, h = p.height || 1;
    var x = p.x || 0, y = p.y || 0;
    if (p.sizing === "content" && content) {
        // Natural sizes never depend on this measured viewport. Offsets reserve
        // space at the anchored edge, or equally at both sides for centre.
        var availableWidth = Math.max(1, bounds.width - (p.anchor === "centre" ? 2 * Math.abs(x) : Math.max(0, x)));
        var availableHeight = Math.max(1, bounds.height - (p.anchor === "centre" ? 2 * Math.abs(y) : Math.max(0, y)));
        if (content.width > 0) w = Math.min(availableWidth, Math.ceil(content.width));
        if (content.height > 0) h = Math.min(availableHeight, Math.ceil(content.height));
    }
    if (p.anchor === "top-right" || p.anchor === "bottom-right") x = bounds.width - w - x;
    if (p.anchor === "bottom-left" || p.anchor === "bottom-right") y = bounds.height - h - y;
    if (p.anchor === "centre") { x += (bounds.width - w) / 2; y += (bounds.height - h) / 2; }
    if (p.sizing === "content") {
        // Signed or excessive offsets must not push measured output offscreen.
        w = Math.min(w, Math.max(0, bounds.width));
        h = Math.min(h, Math.max(0, bounds.height));
        x = Math.max(0, Math.min(x, bounds.width - w));
        y = Math.max(0, Math.min(y, bounds.height - h));
    }
    return {x: bounds.x + x, y: bounds.y + y, width: w, height: h};
}
