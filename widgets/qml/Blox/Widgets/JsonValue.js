.pragma library

// JSON object field order carries no meaning. Array order remains significant.
function canonical(value) {
    if (Array.isArray(value)) return value.map(canonical);
    if (value !== null && typeof value === "object") {
        var ordered = Object.create(null);
        var keys = Object.keys(value).sort();
        for (var i = 0; i < keys.length; ++i) ordered[keys[i]] = canonical(value[keys[i]]);
        return ordered;
    }
    return value;
}

function stringify(value) {
    // Round-trip QVariant-backed input into plain JSON arrays and objects first.
    return JSON.stringify(canonical(JSON.parse(JSON.stringify(value))));
}
