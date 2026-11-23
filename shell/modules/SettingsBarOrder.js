.pragma library

function trayOpensForward(items) {
        const tray = items.find((item) => {
            return item.id === "tray";
        });
        if (!tray || tray.region === "end")
            return false;

        if (tray.region === "start")
            return true;

        if (tray.region !== "centre")
            return false;

        const centre = items.filter((item) => {
            return item.region === "centre";
        }).sort((left, right) => {
            return left.order - right.order;
        });
        return centre.length > 0 && centre[centre.length - 1].id === "tray";
    }

function applicationTrayAtStart(items) {
        return !trayOpensForward(items);
    }

// Keep the expansion control at the edge of its region and its application tray hidden.
function normaliseOrders(items) {
        const regions = ["start", "centre", "end", "hidden"];
        const tray = items.find((item) => {
            return item.id === "tray";
        });
        if (tray && tray.region === "hidden")
            tray.region = "end";

        const applicationTray = items.find((item) => {
            return item.id === "application-tray";
        });
        if (applicationTray)
            applicationTray.region = "hidden";

        const ordered = [];
        for (const region of regions) {
            const members = items.filter((item) => {
                return item.region === region;
            }).sort((left, right) => {
                return left.order - right.order;
            });
            const trayIndex = members.findIndex((item) => {
                return item.id === "tray";
            });
            if (trayIndex >= 0) {
                const trayItem = members.splice(trayIndex, 1)[0];
                if (region === "start")
                    members.push(trayItem);
                else if (region === "end")
                    members.unshift(trayItem);
                else if (region === "centre" && trayIndex < (members.length + 1) / 2)
                    members.unshift(trayItem);
                else
                    members.push(trayItem);
            }
            const applicationTrayIndex = members.findIndex((item) => {
                return item.id === "application-tray";
            });
            if (applicationTrayIndex >= 0) {
                const trayItem = members.splice(applicationTrayIndex, 1)[0];
                if (applicationTrayAtStart(items))
                    members.unshift(trayItem);
                else
                    members.push(trayItem);
            }
            for (let index = 0; index < members.length; ++index) {
                members[index].order = index;
                ordered.push(members[index]);
            }
        }
        return ordered;
    }


function dropAllowed(items, id, region, index) {
    if (["start", "centre", "end", "hidden"].indexOf(region) < 0) return false;
    const count = items.filter(item => item.region === region).length;
    if (index < 0 || index > count) return false;
    if (id === "application-tray")
        return region === "hidden" && (applicationTrayAtStart(items) ? index === 0 : index === count);
    if (id !== "tray") return true;
    if (region === "start") return index === count;
    if (region === "end") return index === 0;
    return region === "centre" && (index === 0 || index === count);
}

// Drop indices refer to the original list, including the row being dragged.
function moveTo(items, id, region, destinationIndex) {
    const next = normaliseOrders(JSON.parse(JSON.stringify(items)));
    const selected = next.find(item => item.id === id);
    if (!selected || !dropAllowed(next, id, region, destinationIndex)) return null;
    const source = next.filter(item => item.region === selected.region).findIndex(item => item.id === id);
    if (selected.region === region && destinationIndex > source) destinationIndex--;
    const groups = {start: [], centre: [], end: [], hidden: []};
    next.filter(item => item.id !== id).forEach(item => groups[item.region].push(item));
    selected.region = region;
    groups[region].splice(Math.max(0, Math.min(groups[region].length, destinationIndex)), 0, selected);
    const reordered = [];
    ["start", "centre", "end", "hidden"].forEach(group => groups[group].forEach((item, index) => {
        item.order = index;
        reordered.push(item);
    }));
    return normaliseOrders(reordered);
}
