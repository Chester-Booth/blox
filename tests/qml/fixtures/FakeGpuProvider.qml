import QtQuick

QtObject {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property int revision: 1
    property real lastUpdatedMs: 1000
    property string lastError: ""
    property bool ok: true
    property string mode: "hybrid"
    property var pendingMode: null
    property var pendingAction: null
    property int setCalls: 0
    property bool confirmationRequired: false
    property string requestedMode: ""
    property var activeClients: []
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.lastUpdatedMs,
        "stale": false,
        "busy": false,
        "errorCode": null,
        "devices": [{"id": "card0", "vendor": "amd", "driver": "amdgpu", "kind": "integrated", "bootVga": true}, {"id": "card1", "vendor": "nvidia", "driver": "nvidia", "kind": "discrete", "bootVga": false}],
        "deviceCount": 2,
        "integratedCount": 1,
        "discreteCount": 1,
        "backend": "drm",
        "controller": "supergfxctl",
        "controllerMode": "Hybrid",
        "mode": root.mode,
        "label": "AMD graphics",
        "gpuOn": false,
        "gpuUtil": "10",
        "gpuTemp": "42",
        "vramUsed": "",
        "vramTotal": "",
        "controlReason": "",
        "supportedModes": ["dedicated", "hybrid", "integrated"],
        "pendingMode": root.pendingMode,
        "pendingAction": root.pendingAction,
        "tooltip": "AMD graphics",
        "capability": {
            "available": true,
            "ready": true,
            "canChange": true,
            "permission": "not-required",
            "reason": null
        }
    })

    function refresh() {
    }

    function setMode(value, logoutAfterAcceptance) {
        const requested = String(value);
        if (requested === "integrated" || logoutAfterAcceptance === true) {
            root.pendingMode = requested;
            root.pendingAction = "logout";
        } else {
            root.mode = requested;
            root.pendingMode = null;
            root.pendingAction = null;
        }
        root.setCalls += 1;
        root.revision += 1;
        root.lastUpdatedMs += 1;
        return true;
    }

    function requestMode(value) {
        const requested = String(value);
        root.requestedMode = requested;
        root.activeClients = requested === "integrated" ? [{"pid": 42, "name": "gpu-app"}] : [];
        root.confirmationRequired = true;
        return true;
    }

    function cancelModeRequest() {
        root.requestedMode = "";
        root.activeClients = [];
        root.confirmationRequired = false;
    }

    function confirmModeRequest() {
        const requested = root.requestedMode;
        if (!root.confirmationRequired || requested.length === 0)
            return false;
        root.cancelModeRequest();
        return root.setMode(requested, true);
    }
}
