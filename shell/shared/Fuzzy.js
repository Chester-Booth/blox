.pragma library

function score(query, candidate, insensitive) {
    const fold = insensitive === undefined ? true : insensitive;
    const needle = fold ? String(query || "").trim().toLowerCase() : String(query || "").trim();
    const haystack = fold ? String(candidate || "").toLowerCase() : String(candidate || "");
    if (!needle.length)
        return -1;
    const exact = haystack.indexOf(needle);
    if (exact >= 0)
        return 10000 - exact * 10 - haystack.length;
    let position = -1;
    let total = 0;
    for (let index = 0; index < needle.length; index++) {
        const next = haystack.indexOf(needle[index], position + 1);
        if (next < 0)
            return -1;
        total += next === position + 1 ? 12 : 4;
        if (next === 0 || " -_/.".indexOf(haystack[next - 1]) >= 0)
            total += 9;
        total -= Math.max(0, next - position - 1);
        position = next;
    }
    return total - haystack.length * 0.02;
}
