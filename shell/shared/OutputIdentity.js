.pragma library

// Stable logical output identity and sparse per-output override resolution.
// Uses EDID make/model/serial when valid, falls back to description, and uses
// connector name as a volatile fallback for virtual or headless outputs.

const PLACEHOLDER_SERIALS = {
    "": true,
    "0": true,
    "00000000": true,
    "unknown": true,
    "default": true,
    "none": true,
    "n/a": true
};

function normalisePart(value) {
    return String(value === undefined || value === null ? "" : value)
        .trim()
        .replace(/\s+/g, " ")
        .toLowerCase();
}

function isUsableSerial(serial) {
    const clean = normalisePart(serial);
    if (!clean || PLACEHOLDER_SERIALS[clean])
        return false;
    return !/^0+$/.test(clean);
}

// Deterministic 64-bit hex fingerprint (dual FNV-1a) so logical IDs stay compact
// and never expose raw monitor serial numbers in state keys or diagnostics.
function fingerprint(text) {
    const input = String(text || "");
    let h1 = 0x811c9dc5;
    let h2 = 0x9e3779b9;
    for (let i = 0; i < input.length; i++) {
        const code = input.charCodeAt(i);
        h1 ^= code;
        h1 = Math.imul(h1, 0x01000193) >>> 0;
        h2 ^= (code + i) & 0xff;
        h2 = Math.imul(h2, 0x01000193) >>> 0;
    }
    return h1.toString(16).padStart(8, "0") + h2.toString(16).padStart(8, "0");
}

function logicalIdentity(monitor) {
    const m = monitor || {};
    const connector = String(m.name || "").trim();
    const make = normalisePart(m.make);
    const model = normalisePart(m.model);
    const serial = normalisePart(m.serial);
    const description = normalisePart(m.description);
    const isHeadless = connector.indexOf("HEADLESS-") === 0;

    let identityKind = "connector";
    let logicalId = "connector:" + (connector || "unknown");
    let volatile = true;

    if (!isHeadless && isUsableSerial(serial)) {
        identityKind = "edid";
        logicalId = "edid:" + fingerprint(make + "|" + model + "|" + serial);
        volatile = false;
    } else if (!isHeadless && (make || model || (description && description !== normalisePart(connector)))) {
        identityKind = "description";
        logicalId = "desc:" + fingerprint(make + "|" + model + "|" + description);
        volatile = false;
    }

    const displayName = [String(m.make || "").trim(), String(m.model || "").trim()]
        .filter(Boolean)
        .join(" ")
        || String(m.description || "").trim()
        || connector
        || "Unknown display";

    return {
        logicalId: logicalId,
        identityKind: identityKind,
        connector: connector,
        label: displayName,
        volatile: volatile
    };
}

// Resolve connected outputs against saved per-output overrides, flagging
// duplicate non-connector identities as ambiguous and retaining absent entries.
function resolveOutputs(monitors, savedOverrides) {
    const list = Array.isArray(monitors) ? monitors : [];
    const overrides = savedOverrides && typeof savedOverrides === "object" ? savedOverrides : {};
    const rawEntries = list.map(monitor => ({
        monitor: monitor,
        identity: logicalIdentity(monitor)
    }));

    const counts = {};
    for (let i = 0; i < rawEntries.length; i++) {
        const id = rawEntries[i].identity.logicalId;
        counts[id] = (counts[id] || 0) + 1;
    }

    const connected = [];
    const seenIds = {};
    for (let i = 0; i < rawEntries.length; i++) {
        const entry = rawEntries[i];
        const id = entry.identity.logicalId;
        const ambiguous = entry.identity.identityKind !== "connector" && counts[id] > 1;
        const effectiveId = ambiguous ? ("connector:" + entry.identity.connector) : id;
        seenIds[id] = true;
        seenIds[effectiveId] = true;
        connected.push({
            logicalId: id,
            effectiveId: effectiveId,
            identityKind: entry.identity.identityKind,
            connector: entry.identity.connector,
            label: entry.identity.label,
            volatile: entry.identity.volatile,
            ambiguous: ambiguous,
            present: true,
            hasOverride: Object.prototype.hasOwnProperty.call(overrides, effectiveId)
                || (!ambiguous && Object.prototype.hasOwnProperty.call(overrides, id)),
            monitor: entry.monitor
        });
    }

    const absent = [];
    const savedKeys = Object.keys(overrides).sort();
    for (let i = 0; i < savedKeys.length; i++) {
        const key = savedKeys[i];
        if (!seenIds[key]) {
            const saved = overrides[key] || {};
            absent.push({
                logicalId: key,
                effectiveId: key,
                connector: String(saved.lastConnector || ""),
                label: String(saved.label || key),
                present: false,
                ambiguous: false,
                hasOverride: true
            });
        }
    }

    return {
        connected: connected,
        absent: absent
    };
}

function resolveOutputConfig(globalConfig, overridesByOutput, logicalId, connectorName) {
    const base = globalConfig && typeof globalConfig === "object" ? globalConfig : {};
    const overrides = overridesByOutput && typeof overridesByOutput === "object" ? overridesByOutput : {};
    const direct = (logicalId && overrides[logicalId])
        || (connectorName && overrides["connector:" + connectorName])
        || (connectorName && overrides[connectorName])
        || ({});

    const baseBar = base.bar && typeof base.bar === "object" ? base.bar : {};
    const overBar = direct.bar && typeof direct.bar === "object" ? direct.bar : {};
    const baseNotif = base.notifications && typeof base.notifications === "object" ? base.notifications : {};
    const overNotif = direct.notifications && typeof direct.notifications === "object" ? direct.notifications : {};
    const baseOsd = base.osd && typeof base.osd === "object" ? base.osd : {};
    const overOsd = direct.osd && typeof direct.osd === "object" ? direct.osd : {};
    const baseWall = base.wallpaper && typeof base.wallpaper === "object" ? base.wallpaper : {};
    const overWall = direct.wallpaper && typeof direct.wallpaper === "object" ? direct.wallpaper : {};

    return {
        bar: {
            visible: overBar.visible !== undefined ? !!overBar.visible : (baseBar.visible !== undefined ? !!baseBar.visible : true),
            position: overBar.position || baseBar.position || "left",
            workspaceFilter: overBar.workspaceFilter || baseBar.workspaceFilter || "this-display",
            showEmptyWorkspaces: overBar.showEmptyWorkspaces !== undefined
                ? !!overBar.showEmptyWorkspaces
                : (baseBar.showEmptyWorkspaces !== undefined ? !!baseBar.showEmptyWorkspaces : true),
            items: Array.isArray(overBar.items) ? overBar.items : (Array.isArray(baseBar.items) ? baseBar.items : null)
        },
        wallpaper: {
            path: overWall.path || baseWall.path || "",
            fit: overWall.fit || baseWall.fit || "cover"
        },
        notifications: {
            enabled: overNotif.enabled !== undefined ? !!overNotif.enabled : (baseNotif.enabled !== undefined ? !!baseNotif.enabled : true),
            position: overNotif.position || baseNotif.position || "top-right"
        },
        osd: {
            enabled: overOsd.enabled !== undefined ? !!overOsd.enabled : (baseOsd.enabled !== undefined ? !!baseOsd.enabled : true)
        }
    };
}
