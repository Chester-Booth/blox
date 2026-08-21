import QtQml.WorkerScript
import QtQuick
import QtTest

TestCase {
    id: testCase

    property var response: null

    function init() {
        response = null;
    }

    function test_caps_large_result_sets() {
        tryCompare(worker, "ready", true);
        const records = [];
        for (let index = 0; index < 600; index++) records.push({
            "index": index,
            "key": String(index),
            "searchText": "a",
            "isEmoji": true,
            "order": index
        })
        worker.sendMessage({
            "type": "initialise",
            "records": records
        });
        worker.sendMessage({
            "type": "search",
            "request": 3,
            "query": "a",
            "pins": []
        });
        tryVerify(() => {
            return testCase.response !== null;
        });
        compare(response.indices.length, 512);
    }

    function test_ranks_emoji_before_unicode_symbols() {
        tryCompare(worker, "ready", true);
        worker.sendMessage({
            "type": "initialise",
            "records": [{
                "index": 0,
                "key": "😺",
                "searchText": "grinning cat face",
                "isEmoji": true,
                "order": 0
            }, {
                "index": 1,
                "key": "ℂ",
                "searchText": "cat",
                "isEmoji": false,
                "order": 1
            }, {
                "index": 2,
                "key": "😀",
                "searchText": "grinning face happy",
                "isEmoji": true,
                "order": 2
            }]
        });
        worker.sendMessage({
            "type": "search",
            "request": 4,
            "query": "cat",
            "pins": []
        });
        tryVerify(() => {
            return testCase.response !== null;
        });
        compare(response.request, 4);
        compare(response.query, "cat");
        compare(response.indices.length, 2);
        compare(response.indices[0], 0);
        compare(response.indices[1], 1);
    }

    name: "EmojiSearchWorker"

    WorkerScript {
        id: worker

        source: "../../shell/modules/EmojiSearchWorker.mjs"
        onMessage: (message) => {
            return testCase.response = message;
        }
    }

}
