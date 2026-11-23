.pragma library

// Classify capability and freshness before dispatching an owner action.
function blockedCode(status, canChange) {
    const capability = status && status.capability ? status.capability : {};
    if (capability.permission === "denied" || capability.reason === "permission-denied" || capability.reason === "denied")
        return "permission-denied";
    if (status && status.busy === true)
        return "busy";
    if (capability.available === false)
        return "unavailable";
    if (status && status.stale === true)
        return "stale";
    if (canChange !== true)
        return "unavailable";
    return "";
}

function result(ok, code, message, data) {
    return {version: 1, ok: ok, code: code, message: message || "", data: data === undefined ? null : data};
}

// Acceptance is not hardware read-back. A provider's busy revision is not completion.
function accepted(operation, value, status, beforeRevision) {
    return result(true, "ok", "", {operation: operation, value: value,
        beforeRevision: beforeRevision, afterRevision: Number(status.providerRevision || 0),
        observedAtMs: Number(status.observedAtMs || 0), pending: true});
}
