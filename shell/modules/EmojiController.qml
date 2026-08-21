import QtQml.WorkerScript
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string query: ""
    property var allItems: []
    property var emojiItems: []
    property var nerdFontItems: []
    property var baseItems: []
    property var items: []
    property var browseItems: []
    property var browsePinned: ({
    })
    property bool virtualBrowse: false
    property int selectedIndex: 0
    property string category: "Search"
    property var toneMap: ({
    })
    property var variantMap: ({
    })
    property var multiToneGroups: ({
    })
    property var searchRecords: []
    property bool searchWorkerInitialised: false
    property int searchRequest: 0
    property bool emojiLoaded: false
    property bool nerdFontsLoaded: false
    property string nerdFontSource: "all"
    property var nerdFontSources: [{
        "key": "all",
        "title": "All sources",
        "count": 0
    }]
    property var nerdFontPurposes: []
    readonly property bool copyBusy: copy.running
    readonly property int itemCount: virtualBrowse ? browseItems.length : items.length
    readonly property var categories: ["Search", "Recent", "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Activities", "Travel & Places", "Objects", "Flags", "Symbols", "Nerd Fonts"]
    readonly property var toneNames: ["", "light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone"]
    readonly property var toneCharacters: ["", "🏻", "🏼", "🏽", "🏾", "🏿"]

    signal closeRequested()
    signal pasteRequested()

    function itemKey(item) {
        return root.baseEmoji(item.baseValue || item.value || "");
    }

    function baseEmoji(value) {
        let base = String(value || "");
        for (let index = 1; index < root.toneCharacters.length; index++) base = base.split(root.toneCharacters[index]).join("")
        return base;
    }

    function toneKey(value) {
        return root.baseEmoji(value).split("\ufe0f").join("").split("\ufe0e").join("");
    }

    function toneIndex(value) {
        let result = 0;
        const text = String(value || "");
        for (let index = 1; index < root.toneCharacters.length; index++) {
            if (text.indexOf(root.toneCharacters[index]) < 0)
                continue;

            if (result !== 0)
                return -1;

            result = index;
        }
        return result;
    }

    function tonePair(value) {
        const pair = [];
        const text = String(value || "");
        for (const character of text) {
            const tone = root.toneCharacters.indexOf(character);
            if (tone > 0)
                pair.push(tone);

        }
        return pair;
    }

    function variantGroupName(name) {
        let group = String(name || "");
        let changed = true;
        while (changed) {
            changed = false;
            for (let index = 1; index < root.toneNames.length; index++) {
                const commaSuffix = ", " + root.toneNames[index];
                const colonSuffix = ": " + root.toneNames[index];
                if (group.endsWith(commaSuffix)) {
                    group = group.slice(0, -commaSuffix.length);
                    changed = true;
                } else if (group.endsWith(colonSuffix)) {
                    group = group.slice(0, -colonSuffix.length);
                    changed = true;
                }
            }
        }
        if (group === "couple with heart: person, person")
            return "couple with heart";

        if (group === "kiss: person, person")
            return "kiss";

        return group;
    }

    function variantGroup(item) {
        if (!item)
            return "";

        return root.variantGroupName(item.variantGroup || item.name || "");
    }

    function variantValue(item, firstTone, secondTone) {
        const variants = root.variantMap[root.variantGroup(item)] || ({
        });
        return variants[firstTone + ":" + secondTone] || "";
    }

    function preferredTonePair(item) {
        if (!item)
            return [0, 0];

        const preferred = LauncherState.emojiVariants[root.variantGroup(item)] || "";
        let pair = root.tonePair(preferred || item.value);
        if (pair.length === 1)
            pair = [pair[0], pair[0]];

        if (pair.length >= 2)
            return [pair[0], pair[1]];

        if (preferred || LauncherState.emojiTone === 0)
            return [0, 0];

        return [LauncherState.emojiTone, LauncherState.emojiTone];
    }

    function prefersDefaultVariant(item) {
        if (!item)
            return true;

        const preferred = LauncherState.emojiVariants[root.variantGroup(item)] || "";
        if (preferred)
            return root.tonePair(preferred).length === 0;

        return LauncherState.emojiTone === 0;
    }

    function displayItem(item, pinned) {
        const group = root.variantGroup(item);
        const variants = root.variantMap[group] || ({
        });
        const preferred = LauncherState.emojiVariants[group] || "";
        const globalTone = LauncherState.emojiTone;
        const toned = globalTone > 0 ? variants[globalTone + ":" + globalTone] || variants[String(globalTone)] || root.toneMap[root.toneKey(item.value) + ":" + globalTone] : "";
        const displayValue = root.category === "Recent" && item.baseValue ? item.value : preferred || toned || item.value;
        return {
            "value": displayValue,
            "name": item.name,
            "keywords": item.keywords,
            "category": item.category,
            "subcategory": item.subcategory || "",
            "identifier": item.identifier || "",
            "source": item.source || "",
            "fontFamily": item.fontFamily || "Twemoji",
            "kind": item.kind || "emoji",
            "baseValue": root.itemKey(item),
            "variantGroup": group,
            "hasMixedTones": Boolean(root.multiToneGroups[group]),
            "pinned": pinned
        };
    }

    function itemAt(index) {
        if (!root.virtualBrowse)
            return root.items[index] || null;

        const item = root.browseItems[index];
        return item ? root.displayItem(item, Boolean(root.browsePinned[root.itemKey(item)])) : null;
    }

    function nerdFontSourceMatches(item) {
        if (root.nerdFontSource === "all")
            return true;

        for (const source of root.nerdFontSources) {
            if (source.key === root.nerdFontSource)
                return (source.keys || [source.key]).indexOf(item.source) >= 0;

        }
        return true;
    }

    function filterSync() {
        const source = root.category === "Recent" ? LauncherState.recentEmoji : root.baseItems;
        if (root.category === "Search" && !root.query.trim().length) {
            const pins = LauncherState.pinnedEmoji;
            const pinSet = {
            };
            for (const key of pins) pinSet[key] = true
            const pinned = [];
            const unpinned = [];
            for (const item of source) {
                const key = root.itemKey(item);
                if (pinSet[key])
                    pinned.push(item);
                else
                    unpinned.push(item);
            }
            root.browsePinned = pinSet;
            root.browseItems = pinned.concat(unpinned);
            root.virtualBrowse = true;
            root.items = [];
            selectedIndex = 0;
            return ;
        }
        root.virtualBrowse = false;
        root.browseItems = [];
        root.browsePinned = ({
        });
        const matches = source.filter((item) => {
            const isRecent = root.category === "Recent";
            const categoryMatch = root.category === "Search" || isRecent || item.category === root.category;
            const sourceMatch = root.category !== "Nerd Fonts" || root.nerdFontSourceMatches(item);
            return categoryMatch && sourceMatch;
        }).map((item, order) => {
            const key = root.itemKey(item);
            const usage = LauncherState.emojiUsage[key] || ({
            });
            return {
                "item": item,
                "pinned": LauncherState.pinnedEmoji.indexOf(key) >= 0,
                "lastUsed": Number(usage.lastUsed || 0),
                "order": order
            };
        });
        matches.sort((a, b) => {
            if (a.pinned !== b.pinned)
                return a.pinned ? -1 : 1;

            if (root.category === "Recent")
                return b.lastUsed - a.lastUsed;

            return a.order - b.order;
        });
        items = matches.map((candidate) => {
            return root.displayItem(candidate.item, candidate.pinned);
        });
        selectedIndex = 0;
    }

    function requestSearch() {
        const needle = query.trim().toLowerCase();
        if (root.category !== "Search" || !needle.length)
            return ;

        if (!root.searchWorkerInitialised) {
            root.initialiseSearchWorker();
            return ;
        }
        const request = ++root.searchRequest;
        searchWorker.sendMessage({
            "type": "search",
            "request": request,
            "query": needle,
            "pins": LauncherState.pinnedEmoji
        });
    }

    function initialiseSearchWorker() {
        if (!searchWorker.ready || root.searchWorkerInitialised || !root.searchRecords.length)
            return ;

        searchWorker.sendMessage({
            "type": "initialise",
            "records": root.searchRecords
        });
        root.searchWorkerInitialised = true;
        root.searchRecords = [];
        if (root.category === "Search" && query.trim().length)
            root.requestSearch();

    }

    function refresh(debounce) {
        if (root.category === "Search" && query.trim().length) {
            if (debounce) {
                searchTimer.restart();
            } else {
                searchTimer.stop();
                root.requestSearch();
            }
            return ;
        }
        searchTimer.stop();
        root.searchRequest++;
        root.filterSync();
    }

    function activateValue(index, value, remember) {
        const item = root.itemAt(index);
        if (copy.running || !item)
            return ;

        const used = Object.assign({
        }, item, {
            "value": value || item.value
        });
        if (remember && item.hasMixedTones) {
            const variants = Object.assign({
            }, LauncherState.emojiVariants);
            variants[item.variantGroup] = used.value;
            LauncherState.emojiVariants = variants;
        }
        copy.command = ["wl-copy", used.value];
        copy.running = true;
        const recent = LauncherState.recentEmoji.filter((item) => {
            return root.itemKey(item) !== root.itemKey(used);
        });
        recent.unshift(used);
        LauncherState.recentEmoji = recent.slice(0, 50);
        const usage = Object.assign({
        }, LauncherState.emojiUsage);
        const key = root.itemKey(used);
        const previous = usage[key] || ({
        });
        usage[key] = {
            "count": Number(previous.count || 0) + 1,
            "lastUsed": Date.now()
        };
        LauncherState.emojiUsage = usage;
        root.refresh(false);
    }

    function activate() {
        root.activateValue(selectedIndex, "", false);
    }

    function activateToneVariant(index, firstTone, secondTone) {
        const item = root.itemAt(index);
        if (!item)
            return ;

        const value = root.variantValue(item, firstTone, secondTone);
        if (value)
            root.activateValue(index, value, true);

    }

    function activateDefaultVariant(index) {
        const item = root.itemAt(index);
        if (item)
            root.activateValue(index, item.baseValue, true);

    }

    function togglePin(index) {
        const item = root.itemAt(index);
        if (!item)
            return ;

        const pins = LauncherState.pinnedEmoji.slice();
        const key = root.itemKey(item);
        const existing = pins.indexOf(key);
        if (existing >= 0)
            pins.splice(existing, 1);
        else
            pins.push(key);
        LauncherState.pinnedEmoji = pins;
        refresh(false);
    }

    function migrateLegacyState() {
        const values = ({
        });
        const names = ({
        });
        for (const item of allItems) {
            values[item.value] = true;
            if (names[item.name] === undefined)
                names[item.name] = item.value;

        }
        let changed = false;
        const pins = LauncherState.pinnedEmoji.map((key) => {
            if (!values[key] && names[key] !== undefined) {
                changed = true;
                return names[key];
            }
            return key;
        });
        const usage = Object.assign({
        }, LauncherState.emojiUsage);
        for (const key of Object.keys(usage)) {
            if (!values[key] && names[key] !== undefined) {
                const target = names[key];
                const previous = usage[target] || ({
                    "count": 0,
                    "lastUsed": 0
                });
                usage[target] = {
                    "count": Number(previous.count || 0) + Number(usage[key].count || 0),
                    "lastUsed": Math.max(Number(previous.lastUsed || 0), Number(usage[key].lastUsed || 0))
                };
                delete usage[key];
                changed = true;
            }
        }
        const seenRecent = ({
        });
        const recent = [];
        for (const item of LauncherState.recentEmoji) {
            const hasTone = ["🏻", "🏼", "🏽", "🏾", "🏿"].some((tone) => {
                return String(item.value || "").indexOf(tone) >= 0;
            });
            const baseValue = item.baseValue || (hasTone ? names[item.name] : "") || (values[item.value] ? item.value : "") || names[item.name] || item.value;
            if (!baseValue || seenRecent[baseValue]) {
                changed = true;
                continue;
            }
            seenRecent[baseValue] = true;
            if (item.baseValue !== baseValue)
                changed = true;

            recent.push(Object.assign({
            }, item, {
                "baseValue": baseValue
            }));
        }
        if (changed) {
            LauncherState.pinnedEmoji = pins;
            LauncherState.emojiUsage = usage;
            LauncherState.recentEmoji = recent;
        }
    }

    function rebuildDataset() {
        if (!root.emojiLoaded || !root.nerdFontsLoaded)
            return ;

        root.allItems = root.emojiItems.concat(root.nerdFontItems);
        root.migrateLegacyState();
        const tones = {
        };
        const variants = {
        };
        const multiTone = {
        };
        const baseItems = [];
        const records = [];
        for (let index = 0; index < root.allItems.length; index++) {
            const item = root.allItems[index];
            const tone = root.toneIndex(item.value);
            const pair = root.tonePair(item.value);
            const group = root.variantGroup(item);
            if (pair.length) {
                if (!variants[group])
                    variants[group] = ({
                });

                variants[group][pair.join(":")] = item.value;
                if (pair.length === 1)
                    variants[group][pair[0] + ":" + pair[0]] = item.value;

                if (pair.length > 1)
                    multiTone[group] = true;

            }
            if (tone > 0)
                tones[root.toneKey(item.value) + ":" + tone] = item.value;

            if (tone !== 0)
                continue;

            baseItems.push(item);
            records.push({
                "index": index,
                "key": root.itemKey(item),
                "searchText": (item.name + " " + item.keywords).toLowerCase(),
                "isEmoji": item.kind !== "nerd-font" && !String(item.subcategory || "").startsWith("text-"),
                "order": index
            });
        }
        root.toneMap = tones;
        root.variantMap = variants;
        root.multiToneGroups = multiTone;
        root.baseItems = baseItems;
        root.searchRecords = records;
        root.searchWorkerInitialised = false;
        root.initialiseSearchWorker();
        root.refresh(false);
    }

    onQueryChanged: refresh(true)
    onCategoryChanged: {
        if (category !== "Search" && query.length)
            query = "";

        refresh(false);
    }
    onNerdFontSourceChanged: refresh(false)

    Connections {
        function onEmojiToneChanged() {
            root.refresh(false);
        }

        target: LauncherState
    }

    FileView {
        path: Qt.resolvedUrl("../assets/emoji.json")
        preload: true
        blockLoading: true
        onLoaded: {
            try {
                root.emojiItems = JSON.parse(text()).items || [];
            } catch (error) {
                root.emojiItems = [];
            }
            root.emojiLoaded = true;
            root.rebuildDataset();
        }
    }

    FileView {
        path: Qt.resolvedUrl("../assets/nerd-fonts.json")
        preload: true
        blockLoading: true
        onLoaded: {
            try {
                const document = JSON.parse(text());
                root.nerdFontItems = document.items || [];
                root.nerdFontPurposes = document.purposes || [];
                root.nerdFontSources = [{
                    "key": "all",
                    "title": "All sources",
                    "count": root.nerdFontItems.length
                }].concat(document.source_filters || document.sources || []);
            } catch (error) {
                root.nerdFontItems = [];
                root.nerdFontPurposes = [];
            }
            root.nerdFontsLoaded = true;
            root.rebuildDataset();
        }
    }

    Timer {
        id: searchTimer

        interval: 45
        repeat: false
        onTriggered: root.requestSearch()
    }

    WorkerScript {
        id: searchWorker

        source: "EmojiSearchWorker.mjs"
        onReadyChanged: root.initialiseSearchWorker()
        onMessage: (message) => {
            if (message.type !== "results" || message.request !== root.searchRequest || root.category !== "Search" || message.query !== root.query.trim().toLowerCase())
                return ;

            const pins = LauncherState.pinnedEmoji;
            root.virtualBrowse = false;
            root.browseItems = [];
            root.browsePinned = ({
            });
            root.items = message.indices.map((index) => {
                const item = root.allItems[index];
                return root.displayItem(item, pins.indexOf(root.itemKey(item)) >= 0);
            });
            root.selectedIndex = 0;
        }
    }

    Process {
        id: copy

        onExited: (exitCode) => {
            if (exitCode === 0)
                root.pasteRequested();
            else
                Quickshell.execDetached(["notify-send", "--app-name", "Blox emoji picker", "--expire-time", "2500", "Emoji error", "The selected emoji could not be copied."]);
        }
    }

}
