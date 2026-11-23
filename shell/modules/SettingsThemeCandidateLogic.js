.pragma library

// Pure theme-candidate read and mutation helpers extracted from SettingsThemeEditorController.
function shellDefaults() {
    return {
        bar: { position: "left", separate_groups: false, border: false, edge_inset: 0 },
        osd: { position: "top-left", offset_x: 0, offset_y: 0 },
        notifications: { position: "bottom-right", offset_x: 0, offset_y: 0 }
    };
}

function shellValue(candidate, section, key) {
    const defaults = shellDefaults();
    const shell = candidate && candidate.shell ? candidate.shell : defaults;
    const sectionDefaults = defaults[section] || {};
    const values = shell[section] || sectionDefaults;
    return values[key] === undefined ? sectionDefaults[key] : values[key];
}

function hyprlandValue(candidate, key, fallback) {
    return candidate && candidate.hyprland && candidate.hyprland[key] !== undefined
        ? candidate.hyprland[key]
        : fallback;
}

function shapeValue(candidate, key, fallback) {
    return candidate && candidate.shape && candidate.shape[key] !== undefined
        ? candidate.shape[key]
        : fallback;
}

function cursorValue(candidate, key, fallback) {
    return candidate && candidate.cursor && candidate.cursor[key] !== undefined
        ? candidate.cursor[key]
        : fallback;
}

function cursorGenerated(candidate) {
    return cursorValue(candidate, "mode", "generated") === "generated";
}

function cursorFollowsThemeRoundness(candidate) {
    return cursorValue(candidate, "shape_source", "theme") === "theme";
}

function cursorEffectiveBase(candidate) {
    return shapeValue(candidate, "radius_scale", 1.25) === 0
        ? "Bibata-Original-Classic"
        : "Bibata-Modern-Classic";
}

function cursorShapeIndex(candidate) {
    const base = cursorFollowsThemeRoundness(candidate)
        ? cursorEffectiveBase(candidate)
        : cursorValue(candidate, "base", "Bibata-Modern-Classic");
    return ["Bibata-Original-Classic", "Bibata-Modern-Classic"].indexOf(base);
}

function cursorDirectionIndex(candidate) {
    return ["right", "left"].indexOf(cursorValue(candidate, "handedness", "right"));
}

function cursorSize(candidate) {
    const sizes = cursorValue(candidate, "sizes", [26]);
    if (!Array.isArray(sizes) || sizes.length === 0 || !Number.isInteger(sizes[0]))
        return 26;
    return sizes[0];
}

function barOverrideSpec(axis) {
    return axis === "radius"
        ? { automatic: "radius_automatic", value: "radius_scale", shape: "radius_scale", fallback: 1.25 }
        : { automatic: "density_automatic", value: "density_scale", shape: "density_scale", fallback: 1.0 };
}

function barOverrideAutomatic(candidate, axis) {
    const spec = barOverrideSpec(axis);
    const value = shellValue(candidate, "bar", spec.automatic);
    return value === undefined ? true : value;
}

function barOverrideValue(candidate, axis) {
    const spec = barOverrideSpec(axis);
    const inherited = shapeValue(candidate, spec.shape, spec.fallback);
    if (barOverrideAutomatic(candidate, axis))
        return inherited;
    const value = shellValue(candidate, "bar", spec.value);
    return value === undefined ? inherited : value;
}

function applyOverride(next, target, key, value) {
    if (!next.overrides)
        next.overrides = {};
    if (!next.overrides[target])
        next.overrides[target] = {};
    const trimmed = String(value || "").trim();
    if (trimmed.length === 0)
        delete next.overrides[target][key];
    else
        next.overrides[target][key] = trimmed;
    if (Object.keys(next.overrides[target]).length === 0)
        delete next.overrides[target];
    if (Object.keys(next.overrides).length === 0)
        delete next.overrides;
    if (target === "ansi")
        next.terminal.ansi_source = "override";
    return next;
}
