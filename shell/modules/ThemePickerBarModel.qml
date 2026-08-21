import "../shared"
import QtQuick

QtObject {
    required property var host

    function items() {
        const overrides = host.candidate && host.candidate.shell && host.candidate.shell.bar && host.candidate.shell.bar.items ? host.candidate.shell.bar.items : [];
        const position = host.candidate && host.candidate.shell && host.candidate.shell.bar ? host.candidate.shell.bar.position : Theme.barPosition;
        return Theme.resolvedBarItems(overrides, position);
    }

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

    function label(id) {
        const labels = {
            "active-window-title": "Active window title",
            "application-tray": "Application tray",
            "bt": "Bluetooth",
            "notifications": "Notifications",
            "wifi": "Wi-Fi"
        };
        return labels[id] || id.charAt(0).toUpperCase() + id.slice(1);
    }

    function previewIcon(id) {
        const icons = {
            "active-window-title": "cursor-text",
            "power": "power",
            "notes": "notebook",
            "workspaces": "squares-four",
            "clock": "clock",
            "battery": "battery-full",
            "tray": "app-window",
            "notifications": "bell",
            "wifi": "wifi-high",
            "sound": "speaker-high",
            "touchpad": "cursor-click",
            "privacy": "shield",
            "awake": "coffee",
            "display": "sun",
            "bt": "bluetooth",
            "updates": "arrows-clockwise",
            "application-tray": "app-window"
        };
        return icons[id] || "app-window";
    }

    function setItems(items) {
        const next = host.cloneCandidate();
        if (!next.shell)
            next.shell = host.shellDefaults();

        if (!next.shell.bar)
            next.shell.bar = host.shellDefaults().bar;

        next.shell.bar.items = normaliseOrders(items);
        host.markCandidate(next);
        Theme.loadShell(next.shell);
    }

    function setEnabled(id, enabled) {
        const current = items();
        for (let index = 0; index < current.length; ++index) {
            if (current[index].id === id) {
                current[index].enabled = enabled;
                break;
            }
        }
        setItems(current);
    }

    function setDisplay(id, display) {
        const current = items();
        for (let index = 0; index < current.length; ++index) {
            if (current[index].id === id) {
                current[index].display = display;
                break;
            }
        }
        setItems(current);
    }

    function setVisibility(id, visibility) {
        const current = items();
        for (let index = 0; index < current.length; ++index) {
            if (current[index].id === id) {
                current[index].visibility = visibility;
                break;
            }
        }
        setItems(current);
    }

    function setOrientation(id, orientation) {
        const current = items();
        for (let index = 0; index < current.length; ++index) {
            if (current[index].id === id) {
                current[index].orientation = orientation;
                break;
            }
        }
        setItems(current);
    }

    function setTitleLength(id, titleLength) {
        const current = items();
        for (let index = 0; index < current.length; ++index) {
            if (current[index].id === id) {
                current[index].titleLength = titleLength;
                break;
            }
        }
        setItems(current);
    }

    function setRegion(id, region) {
        const current = items();
        if (id === "application-tray")
            region = "hidden";

        const nextOrder = current.filter((item) => {
            return item.region === region;
        }).length;
        for (let index = 0; index < current.length; ++index) {
            if (current[index].id === id) {
                current[index].region = region;
                current[index].order = nextOrder;
                break;
            }
        }
        setItems(current);
    }

    function move(id, direction) {
        const current = normaliseOrders(items());
        const selected = current.find((item) => {
            return item.id === id;
        });
        if (!selected || id === "application-tray")
            return ;

        if (id === "tray") {
            if (selected.region !== "centre")
                return ;

            const members = current.filter((item) => {
                return item.region === "centre";
            });
            selected.order = selected.order === 0 ? members.length : -1;
            setItems(current);
            return ;
        }
        const neighbour = current.find((item) => {
            return item.region === selected.region && item.order === selected.order + direction;
        });
        if (!neighbour)
            return ;

        const previousOrder = selected.order;
        selected.order = neighbour.order;
        neighbour.order = previousOrder;
        setItems(current);
    }

    function moveTo(id, region, destinationIndex) {
        const current = normaliseOrders(items());
        const selected = current.find((item) => {
            return item.id === id;
        });
        if (!selected)
            return ;

        if (id === "application-tray") {
            region = "hidden";
            destinationIndex = applicationTrayAtStart(current) ? 0 : current.filter((item) => {
                return item.region === "hidden";
            }).length;
        }
        const sourceRegion = selected.region;
        const sourceIndex = current.filter((item) => {
            return item.region === sourceRegion;
        }).findIndex((item) => {
            return item.id === id;
        });
        const groups = {
            "start": [],
            "centre": [],
            "end": [],
            "hidden": []
        };
        for (const item of current) {
            if (item.id !== id)
                groups[item.region].push(item);

        }
        selected.region = region;
        const destination = groups[region];
        if (region === sourceRegion && destinationIndex > sourceIndex)
            destinationIndex -= 1;

        destination.splice(Math.max(0, Math.min(destination.length, destinationIndex)), 0, selected);
        const next = [];
        for (const group of ["start", "centre", "end", "hidden"]) {
            for (let index = 0; index < groups[group].length; ++index) {
                groups[group][index].order = index;
                next.push(groups[group][index]);
            }
        }
        setItems(next);
    }

    function previewItems(region) {
        host.candidateRevision;
        return items().filter((item) => {
            return item.enabled && item.region === region;
        }).sort((left, right) => {
            return left.order - right.order;
        });
    }

}
