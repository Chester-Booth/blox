import qs.shared
import Blox.Services 1.0
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string query: ""
    readonly property int emojiCount: nativeIndex.emojiCount
    readonly property int nerdFontCount: nativeIndex.nerdFontCount
    property var items: []
    property var categoryIndices: []
    property bool nativeCategoryBrowse: false
    property bool nativeSearchBrowse: false
    property int searchCount: 0
    property bool sectionedBrowse: false
    property int sectionedCount: 0
    property int gridColumns: 5
    property int browseRevision: 0
    property var browsePinned: ({
    })
    property bool virtualBrowse: false
    property int selectedIndex: 0
    property string category: "Search"
    property bool emojiLoaded: false
    property bool nerdFontsLoaded: false
    property string emojiDataError: ""
    property string nerdFontDataError: ""
    property string nerdFontSource: "all"
    property var nerdFontSources: [{
        "key": "all",
        "title": "All sources",
        "count": 0
    }]
    property var nerdFontPurposes: []
    readonly property var symbolSections: [
        {key: "emoji", title: "Emoji signs"},
        {key: "common", title: "Common marks & games"},
        {key: "shape", title: "Shapes"},
        {key: "arrow", title: "Arrows"},
        {key: "maths", title: "Maths & logic"},
        {key: "currency", title: "Currency"},
        {key: "technical", title: "Technical notation"}
    ]
    readonly property bool copyBusy: copy.running
    readonly property int itemCount: virtualBrowse ? nativeIndex.count
        : sectionedBrowse ? sectionedCount
        : nativeSearchBrowse ? searchCount
        : nativeCategoryBrowse ? categoryIndices.length
        : items.length
    readonly property int gridCount: sectionedBrowse ? nativeIndex.gridCount : itemCount
    readonly property var categories: ["Search", "Recent", "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Activities", "Travel & Places", "Objects", "Flags", "Symbols", "Nerd Fonts"]
    readonly property var toneNames: ["", "light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone"]
    readonly property var toneCharacters: ["", "🏻", "🏼", "🏽", "🏾", "🏿"]
    readonly property string emptyStateText: {
        if (!root.emojiLoaded || !root.nerdFontsLoaded || root.itemCount > 0 || root.category === "Recent")
            return "";

        if (root.category === "Nerd Fonts") {
            if (root.nerdFontDataError.length)
                return root.nerdFontDataError;

            if (root.query.trim().length)
                return "";

            return root.nerdFontCount ? "" : "No Nerd Fonts available.";
        }

        if (root.category === "Search") {
            if (root.emojiDataError.length)
                return root.emojiDataError;

            if (root.nerdFontDataError.length)
                return root.nerdFontDataError;

            if (root.query.trim().length)
                return "";

            return nativeIndex.sourceCount ? "" : "No emoji available.";
        }

        if (root.emojiDataError.length)
            return root.emojiDataError;

        if (root.query.trim().length)
            return "";

        return root.emojiCount ? "" : "No emoji available.";
    }
    readonly property bool emptyStateIsError: {
        if (!root.emptyStateText.length)
            return false;

        if (root.category === "Nerd Fonts")
            return root.nerdFontDataError.length > 0;

        if (root.category === "Search")
            return root.emojiDataError.length > 0 || root.nerdFontDataError.length > 0;

        return root.emojiDataError.length > 0;
    }
    readonly property string partialDataErrorText: {
        if (!root.emojiLoaded || !root.nerdFontsLoaded || root.itemCount === 0 || root.category === "Recent")
            return "";

        if (root.category === "Nerd Fonts")
            return root.nerdFontDataError;

        if (root.category === "Search")
            return root.emojiDataError || root.nerdFontDataError;

        return root.emojiDataError;
    }

    signal closeRequested()
    signal dismissRequested()
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
        const variants = nativeIndex.variantsForGroup(root.variantGroup(item));
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
        const variants = nativeIndex.variantsForGroup(group);
        const preferred = LauncherState.emojiVariants[group] || "";
        const globalTone = LauncherState.emojiTone;
        const toned = globalTone > 0 ? variants[globalTone + ":" + globalTone] || variants[String(globalTone)] || nativeIndex.toneValue(root.toneKey(item.value) + ":" + globalTone) : "";
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
            "hasMixedTones": nativeIndex.hasMixedTones(group),
            "pinned": pinned
        };
    }

    function setGridColumns(columns) {
        const clamped = Math.max(1, columns);
        if (clamped === root.gridColumns) return;
        root.gridColumns = clamped;
        if (root.sectionedBrowse) {
            nativeIndex.relayoutSectionedGrid(clamped);
            root.browseRevision++;
        }
    }

    function gridRowKind(row) { return nativeIndex.gridRowKind(row); }
    function gridRowItemIndex(row) { return nativeIndex.gridRowItemIndex(row); }
    function gridRowTitle(row) { return nativeIndex.gridRowTitle(row); }
    function gridIndexForItem(itemIndex) {
        const rev = root.browseRevision;
        return nativeIndex.gridIndexForItem(itemIndex);
    }
    function gridHeadingRow(sectionKey) { return nativeIndex.gridHeadingRow(sectionKey); }
    function activeSectionForRow(firstRow, fallback) { return nativeIndex.activeSectionForRow(firstRow, fallback); }

    function itemAt(index) {
        // Cells must refresh after a reorder, search, or tone change even when count is unchanged.
        const revision = root.browseRevision;
        if (index < 0) return null;
        if (root.virtualBrowse) {
            if (index >= nativeIndex.count) return null;
            const sourceIndex = nativeIndex.sourceIndexAt(index);
            const item = nativeIndex.item(sourceIndex);
            return root.displayItem(item, Boolean(root.browsePinned[root.itemKey(item)]));
        }
        if (root.sectionedBrowse) {
            if (index >= root.sectionedCount) return null;
            const sourceIndex = nativeIndex.sectionedSourceIndexAt(index);
            const item = nativeIndex.item(sourceIndex);
            return root.displayItem(item, Boolean(root.browsePinned[root.itemKey(item)]));
        }
        if (root.nativeSearchBrowse) {
            if (index >= root.searchCount) return null;
            const sourceIndex = nativeIndex.searchSourceIndexAt(index);
            const item = nativeIndex.item(sourceIndex);
            return root.displayItem(item, Boolean(root.browsePinned[root.itemKey(item)]));
        }
        if (root.nativeCategoryBrowse) {
            if (index >= root.categoryIndices.length) return null;
            const sourceIndex = root.categoryIndices[index];
            const item = nativeIndex.item(sourceIndex);
            return root.displayItem(item, Boolean(root.browsePinned[root.itemKey(item)]));
        }
        return root.items[index] || null;
    }

    function filterSync() {
        const pins = LauncherState.pinnedEmoji;
        const pinSet = {};
        for (const key of pins) pinSet[key] = true;
        root.browsePinned = pinSet;
        if (root.category === "Search" && !root.query.trim().length) {
            nativeIndex.setPins(pins);
            nativeIndex.clearSectionedGrid();
            root.virtualBrowse = true;
            root.sectionedBrowse = false;
            root.sectionedCount = 0;
            root.nativeSearchBrowse = false;
            root.searchCount = 0;
            root.nativeCategoryBrowse = false;
            root.categoryIndices = [];
            root.items = [];
        } else if (root.category === "Symbols" || root.category === "Nerd Fonts") {
            const sections = root.category === "Symbols" ? root.symbolSections : root.nerdFontPurposes;
            root.virtualBrowse = false;
            root.nativeSearchBrowse = false;
            root.searchCount = 0;
            root.nativeCategoryBrowse = false;
            root.categoryIndices = [];
            root.items = [];
            root.sectionedCount = nativeIndex.buildSectionedGrid(root.category, root.nerdFontSource, pins, sections, root.gridColumns);
            root.sectionedBrowse = true;
        } else if (root.category !== "Recent") {
            nativeIndex.clearSectionedGrid();
            root.virtualBrowse = false;
            root.sectionedBrowse = false;
            root.sectionedCount = 0;
            root.nativeSearchBrowse = false;
            root.searchCount = 0;
            root.categoryIndices = nativeIndex.filteredIndices(root.category, root.nerdFontSource, pins);
            root.nativeCategoryBrowse = true;
            root.items = [];
        } else {
            nativeIndex.clearSectionedGrid();
            root.virtualBrowse = false;
            root.sectionedBrowse = false;
            root.sectionedCount = 0;
            root.nativeSearchBrowse = false;
            root.searchCount = 0;
            root.nativeCategoryBrowse = false;
            root.categoryIndices = [];
            const matches = LauncherState.recentEmoji.map((item, order) => {
                const key = root.itemKey(item);
                const usage = LauncherState.emojiUsage[key] || {};
                return {item: item, pinned: pins.indexOf(key) >= 0, lastUsed: Number(usage.lastUsed || 0), order: order};
            });
            matches.sort((a, b) => a.pinned !== b.pinned ? a.pinned ? -1 : 1 : b.lastUsed - a.lastUsed);
            root.items = matches.map(candidate => root.displayItem(candidate.item, candidate.pinned));
        }
        root.browseRevision++;
        root.selectedIndex = 0;
    }

    function requestSearch() {
        const needle = query.trim().toLowerCase();
        if (root.category !== "Search" || !needle.length) return;
        const pins = LauncherState.pinnedEmoji;
        const pinSet = {};
        for (const key of pins) pinSet[key] = true;
        root.browsePinned = pinSet;
        nativeIndex.clearSectionedGrid();
        root.virtualBrowse = false;
        root.sectionedBrowse = false;
        root.sectionedCount = 0;
        root.nativeCategoryBrowse = false;
        root.categoryIndices = [];
        root.items = [];
        root.searchCount = nativeIndex.setSearchResults(needle, pins);
        root.nativeSearchBrowse = true;
        root.browseRevision++;
        root.selectedIndex = 0;
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

    function rebuildDataset() {
        if (!root.emojiLoaded || !root.nerdFontsLoaded) return;
        root.refresh(false);
    }

    function loadEmojiData(text) {
        const valid = nativeIndex.loadEmojiData(text);
        root.emojiDataError = valid ? "" : "Emoji data could not be loaded.";
        root.emojiLoaded = true;
        root.rebuildDataset();
        return valid;
    }

    function failEmojiData() {
        nativeIndex.clearEmojiData();
        root.emojiDataError = "Emoji data could not be loaded.";
        root.emojiLoaded = true;
        root.rebuildDataset();
    }

    function loadNerdFontData(text) {
        const valid = nativeIndex.loadNerdFontData(text);
        root.nerdFontPurposes = nativeIndex.nerdFontPurposes;
        root.nerdFontSources = nativeIndex.nerdFontSources;
        root.nerdFontDataError = valid ? "" : "Nerd Font data could not be loaded.";
        root.nerdFontsLoaded = true;
        root.rebuildDataset();
        return valid;
    }

    function failNerdFontData() {
        nativeIndex.clearNerdFontData();
        root.nerdFontPurposes = nativeIndex.nerdFontPurposes;
        root.nerdFontSources = nativeIndex.nerdFontSources;
        root.nerdFontDataError = "Nerd Font data could not be loaded.";
        root.nerdFontsLoaded = true;
        root.rebuildDataset();
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
        objectName: "emoji-data-file"
        path: Qt.resolvedUrl("../assets/emoji.json")
        preload: true
        blockLoading: true
        onLoaded: root.loadEmojiData(text())
        onLoadFailed: root.failEmojiData()
    }

    FileView {
        objectName: "nerd-font-data-file"
        path: Qt.resolvedUrl("../assets/nerd-fonts.json")
        preload: true
        blockLoading: true
        onLoaded: root.loadNerdFontData(text())
        onLoadFailed: root.failNerdFontData()
    }

    Timer {
        id: searchTimer

        interval: 45
        repeat: false
        onTriggered: root.requestSearch()
    }

    NativeEmojiIndex { id: nativeIndex }

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
