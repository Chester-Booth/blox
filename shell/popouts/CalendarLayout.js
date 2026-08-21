.pragma library

function snap(value) { return Math.round(value * 4) / 4; }
function timeToY(value, start, end, height) { return (value - start) * height / (end - start); }
function yToTime(value, start, end, height) { return snap(start + value * (end - start) / height); }

function adaptiveBounds(items) {
    var earliest = 24, latest = 0;
    for (var i = 0; i < items.length; ++i) {
        earliest = Math.min(earliest, items[i].start);
        latest = Math.max(latest, items[i].end);
    }
    return { start: earliest < 10 ? Math.max(0, Math.floor(earliest - 1)) : 9,
             end: latest > 18 ? Math.min(24, Math.ceil(latest + 1)) : 19 };
}

function segment(event, dayStart, dayEnd) {
    if (event.time.kind === "all_day") {
        var day = Qt.formatDate(new Date(dayStart), "yyyy-MM-dd");
        return day >= event.time.start_date && day < event.time.end_date_exclusive ? { allDay: true, event: event } : null;
    }
    var start = Math.max(dayStart, event.time.start_ms);
    var end = Math.min(dayEnd, event.time.end_ms);
    if (start >= end) return null;
    if (start === dayStart && end === dayEnd) return { allDay: true, timedContinuation: true, event: event };
    return { event: event, allDay: false, start: (start - dayStart) / 3600000,
             end: (end - dayStart) / 3600000, continuesBefore: event.time.start_ms < dayStart,
             continuesAfter: event.time.end_ms > dayEnd };
}

function lanes(items, pixelsPerHour) {
    var sorted = items.slice().sort(function(a, b) {
        return a.start - b.start || b.end - a.end || String(a.key).localeCompare(String(b.key));
    });
    var result = {}, cluster = [], clusterEnd = -1;
    function finish() {
        var ends = [];
        for (var i = 0; i < cluster.length; ++i) {
            var item = cluster[i], effectiveEnd = Math.max(item.end, item.start + 16 / pixelsPerHour), lane = 0;
            while (lane < ends.length && ends[lane] > item.start) ++lane;
            if (lane === ends.length) ends.push(effectiveEnd); else ends[lane] = effectiveEnd;
            item._lane = lane;
        }
        for (var j = 0; j < cluster.length; ++j) result[cluster[j].key] = { lane: cluster[j]._lane, lanes: ends.length };
    }
    for (var k = 0; k < sorted.length; ++k) {
        var effective = Math.max(sorted[k].end, sorted[k].start + 16 / pixelsPerHour);
        if (cluster.length && sorted[k].start >= clusterEnd) { finish(); cluster = []; clusterEnd = -1; }
        cluster.push(sorted[k]); clusterEnd = Math.max(clusterEnd, effective);
    }
    if (cluster.length) finish();
    return result;
}
