import QtQml.WorkerScript
import QtQuick
import QtTest

TestCase {
    id: testCase

    property var response: null

    function init() {
        response = null;
    }

    function test_matches_name_and_stable_id() {
        tryCompare(worker, "ready", true);
        worker.sendMessage({
            "type": "initialise",
            "records": [{
                "index": 0,
                "name": "Catppuccin Mocha",
                "searchText": "catppuccin mocha catppuccin-mocha"
            }, {
                "index": 1,
                "name": "Nord",
                "searchText": "nord nord"
            }]
        });
        worker.sendMessage({
            "type": "search",
            "request": 7,
            "query": "mocha"
        });
        tryVerify(() => {
            return testCase.response !== null;
        });
        compare(response.request, 7);
        compare(response.query, "mocha");
        compare(response.indices.length, 1);
        compare(response.indices[0], 0);
    }

    function test_rejects_non_matches() {
        tryCompare(worker, "ready", true);
        worker.sendMessage({
            "type": "initialise",
            "records": [{
                "index": 0,
                "name": "Catppuccin Mocha",
                "searchText": "catppuccin mocha catppuccin-mocha"
            }]
        });
        worker.sendMessage({
            "type": "search",
            "request": 8,
            "query": "solarized"
        });
        tryVerify(() => {
            return testCase.response !== null;
        });
        compare(response.indices.length, 0);
    }

    name: "ThemeSearchWorker"

    WorkerScript {
        id: worker

        source: "../../shell/modules/ThemeSearchWorker.mjs"
        onMessage: (message) => {
            return testCase.response = message;
        }
    }

}
