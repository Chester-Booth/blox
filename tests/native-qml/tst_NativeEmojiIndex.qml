import QtQuick
import QtQml.WorkerScript
import QtTest
import Blox.Services 1.0

TestCase {
    id: testCase
    name: "NativeEmojiIndex"
    property var sourceItems: []
    property var baseRecords: []
    property var emojiDocument: null
    property var nerdDocument: null
    property var response: null
    property int request: 0

    NativeEmojiIndex { id: index }
    WorkerScript {
        id: oracle
        // Frozen pre-native scoring, kept outside the shipped shell.
        source: "../qml/fixtures/EmojiSearchOracle.mjs"
        onMessage: message => testCase.response = message
    }
    function document(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(path), false);
        xhr.send();
        return JSON.parse(xhr.responseText);
    }
    function baseValue(value) {
        for (const tone of ["🏻", "🏼", "🏽", "🏾", "🏿"]) value = value.split(tone).join("");
        return value;
    }
    function hasTone(value) { return ["🏻", "🏼", "🏽", "🏾", "🏿"].some(tone => value.indexOf(tone) >= 0); }
    function restoreAssets() {
        verify(index.loadEmojiData(JSON.stringify(emojiDocument)));
        verify(index.loadNerdFontData(JSON.stringify(nerdDocument)));
    }
    function initTestCase() {
        emojiDocument = document("../../shell/assets/emoji.json");
        nerdDocument = document("../../shell/assets/nerd-fonts.json");
        sourceItems = emojiDocument.items.concat(nerdDocument.items);
        restoreAssets();
        for (let i = 0; i < sourceItems.length; i++) {
            const item = sourceItems[i];
            if (hasTone(item.value)) continue;
            baseRecords.push({index: i, key: baseValue(item.baseValue || item.value),
                searchText: (item.name + " " + item.keywords).toLowerCase(),
                isEmoji: item.kind !== "nerd-font" && !String(item.subcategory || "").startsWith("text-"), order: i});
        }
        tryCompare(oracle, "ready", true);
        oracle.sendMessage({type: "initialise", records: baseRecords});
    }
    function init() { response = null; }
    function test_ranking_matches_frozen_worker_data() {
        const rows = [];
        for (const query of ["a", "cat", "arrow", "account", "nf-cod-account", "family", "mth", "grinning", "heart", "zzzzzzzzzz", "é"]) {
            rows.push({tag: query + "-plain", query: query, pinned: false});
            rows.push({tag: query + "-pinned", query: query, pinned: true});
        }
        return rows;
    }
    function test_ranking_matches_frozen_worker(data) {
        const pins = data.pinned ? [baseRecords[0].key, baseRecords[baseRecords.length - 1].key] : [];
        const serial = ++request;
        oracle.sendMessage({type: "search", request: serial, query: data.query, pins: pins});
        tryVerify(() => response && response.request === serial);
        compare(JSON.stringify(index.search(data.query, pins)), JSON.stringify(response.indices));
    }
    function test_source_payloads_browse_and_category_order() {
        compare(index.sourceCount, sourceItems.length);
        compare(index.count, baseRecords.length);
        for (const i of [0, 1, 84, emojiDocument.items.length - 1, emojiDocument.items.length, sourceItems.length - 1])
            compare(index.item(i), sourceItems[i]);
        const pins = [baseRecords[baseRecords.length - 1].key, baseRecords[0].key];
        index.setPins(pins);
        const ordered = baseRecords.filter(record => pins.indexOf(record.key) >= 0)
            .concat(baseRecords.filter(record => pins.indexOf(record.key) < 0));
        for (let row = 0; row < ordered.length; row++) compare(index.sourceIndexAt(row), ordered[row].index);
        for (const category of ["Smileys & Emotion", "Symbols", "Nerd Fonts"]) {
            const records = ordered.filter(record => sourceItems[record.index].category === category);
            compare(JSON.stringify(index.filteredIndices(category, "all", pins)), JSON.stringify(records.map(record => record.index)));
        }
        const filter = nerdDocument.source_filters.find(filter => filter.keys && filter.keys.length > 1);
        verify(filter);
        const records = ordered.filter(record => sourceItems[record.index].category === "Nerd Fonts"
            && filter.keys.indexOf(sourceItems[record.index].source) >= 0);
        compare(JSON.stringify(index.filteredIndices("Nerd Fonts", filter.key, pins)), JSON.stringify(records.map(record => record.index)));
    }
    function test_z_partial_source_failure_and_reload_keep_healthy_half() {
        verify(!index.loadNerdFontData('{"items": [], "purposes": null}'));
        compare(index.sourceCount, emojiDocument.items.length);
        compare(index.emojiCount, emojiDocument.items.length);
        compare(index.nerdFontCount, 0);
        verify(index.search("grinning", []).length > 0);
        verify(index.loadNerdFontData(JSON.stringify(nerdDocument)));
        verify(!index.loadEmojiData('{"items": [{"value": 1, "name": "bad", "keywords": "bad"}]}'));
        compare(index.sourceCount, nerdDocument.items.length);
        verify(index.search("account", []).length > 0);
        restoreAssets();
    }
}
