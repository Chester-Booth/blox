import QtQuick

QtObject {
    id: root
    property string scriptRoot: ""
    property int interval: 60000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property bool ok: true
    property int setCalls: 0
    property int refreshCalls: 0
    property string refreshId: "60"
    readonly property var json: ({
        "schemaVersion": 1, "providerRevision": root.revision, "observedAtMs": root.lastUpdatedMs,
        "stale": false, "busy": false, "errorCode": null,
        "monitors": [{"name": "panel", "description": "Panel", "width": 1920, "height": 1080, "refreshRate": Number(root.refreshId), "refreshId": root.refreshId, "x": 30, "y": -10, "scale": 1.25, "transform": 1, "canChange": true, "rates": [{"id": "144", "rate": 144, "label": "144 Hz"}, {"id": "60", "rate": 60, "label": "60 Hz"}]}],
        "monitorCount": 1,
        "capability": {"available": true, "ready": true, "canChange": true, "permission": "not-required", "reason": null}
    })
    function refresh() {
        root.refreshCalls += 1;
        root.revision += 1;
        return true;
    }
    function setRefresh(monitor, rate) {
        if (monitor !== "panel" || ["144", "60"].indexOf(rate) < 0)
            return false;
        root.refreshId = rate;
        root.setCalls += 1;
        root.revision += 1;
        return true;
    }
}
