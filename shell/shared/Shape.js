.pragma library

var HYPRLAND_RADIUS_BASE = 12;
var GTK_RADIUS_BASE = 12;
var AUTOMATIC_GAP_BASE = 20;
var MINIMUM_DENSITY_SCALE = 0.75;

function roundScaled(base, scale) {
    return Math.round(base * scale);
}

function automaticWindowGap(densityScale) {
    return Math.max(0, Math.round(AUTOMATIC_GAP_BASE * (densityScale - MINIMUM_DENSITY_SCALE)));
}

function effectiveWindowGap(shape) {
    return shape.window_gap === undefined || shape.window_gap === null
        ? automaticWindowGap(shape.density_scale)
        : shape.window_gap;
}
