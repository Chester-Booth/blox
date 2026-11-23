let records = [];
const maximumResults = 512;

function score(query, candidate) {
    const exact = candidate.indexOf(query);
    if (exact >= 0)
        return 10000 - exact * 10 - candidate.length;

    let position = -1;
    let total = 0;
    for (let index = 0; index < query.length; index++) {
        const next = candidate.indexOf(query[index], position + 1);
        if (next < 0)
            return -1;
        total += next === position + 1 ? 12 : 4;
        if (next === 0 || " -_/.".indexOf(candidate[next - 1]) >= 0)
            total += 9;
        total -= Math.max(0, next - position - 1);
        position = next;
    }
    return total - candidate.length * 0.02;
}

WorkerScript.onMessage = function(message) {
    if (message.type === "initialise") {
        records = message.records || [];
        return;
    }
    if (message.type !== "search")
        return;

    const pinned = {};
    for (const key of message.pins || [])
        pinned[key] = true;

    const matches = [];
    for (const record of records) {
        const matchScore = score(message.query, record.searchText);
        if (matchScore < 0)
            continue;
        matches.push({
            "index": record.index,
            "pinned": pinned[record.key] === true,
            "score": matchScore + (record.isEmoji ? 200 : 0),
            "order": record.order
        });
    }
    matches.sort((left, right) => {
        if (left.pinned !== right.pinned)
            return left.pinned ? -1 : 1;
        if (left.score !== right.score)
            return right.score - left.score;
        return left.order - right.order;
    });
    WorkerScript.sendMessage({
        "type": "results",
        "request": message.request,
        "query": message.query,
        "indices": matches.slice(0, maximumResults).map((match) => match.index)
    });
};
