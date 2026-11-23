import QtQuick

// Pure transaction state shared by the Settings UI and its owner tests.
Item {
    id: root

    property int schemaVersion: 1
    property int revision: 0
    property real observedAt: 0
    property bool dirty: false
    property bool conflict: false
    property var changedComponents: []
    property string commitState: "not-applicable"
    property string rollbackState: "not-attempted"
    property var error: null
    property var settings: null
    property var lastResult: null

    function validResult(action) {
        if (!action || action.version !== 1 || typeof action.ok !== "boolean"
                || typeof action.code !== "string" || typeof action.message !== "string")
            return false;
        const data = action.data;
        if (!data || typeof data !== "object"
                || !Number.isInteger(data.schemaVersion)
                || data.schemaVersion < 1
                || !(data.revision === null || (Number.isInteger(data.revision) && data.revision >= 0))
                || !(data.beforeRevision === null || (Number.isInteger(data.beforeRevision) && data.beforeRevision >= 0))
                || !(data.afterRevision === null || (Number.isInteger(data.afterRevision) && data.afterRevision >= 0))
                || typeof data.observedAt !== "number" || !isFinite(data.observedAt) || data.observedAt < 0
                || typeof data.dirty !== "boolean" || typeof data.conflict !== "boolean"
                || !Array.isArray(data.changedComponents)
                || ["not-applicable", "committed", "not-committed"].indexOf(data.commitState) < 0
                || ["not-attempted", "rolled-back", "rollback-failed"].indexOf(data.rollbackState) < 0)
            return false;
        for (let i = 0; i < data.changedComponents.length; i++) {
            if (typeof data.changedComponents[i] !== "string")
                return false;
        }
        if (data.settings !== null && (typeof data.settings !== "object" || Array.isArray(data.settings)))
            return false;
        if (data.error !== null && (!data.error || typeof data.error.code !== "string" || typeof data.error.message !== "string"))
            return false;
        if (action.ok !== (action.code === "ok") || data.conflict !== (action.code === "conflict")
                || (action.ok && data.error !== null)
                || (!action.ok && (!data.error || data.error.code !== action.code)))
            return false;
        return true;
    }

    function acceptResult(action) {
        if (!root.validResult(action)) {
            root.error = ({"code": "invalid-data", "message": "The Settings owner returned an invalid result."});
            root.lastResult = null;
            return false;
        }

        const data = action.data;
        root.lastResult = action;
        root.schemaVersion = data.schemaVersion;
        root.revision = data.revision === null ? root.revision : data.revision;
        root.observedAt = data.observedAt;
        root.conflict = action.code === "conflict" || data.conflict;
        root.changedComponents = data.changedComponents.slice(0);
        root.commitState = data.commitState;
        root.rollbackState = data.rollbackState;
        root.error = data.error;
        if (data.settings !== null && data.settings !== undefined)
            root.settings = data.settings;
        if (action.ok)
            root.dirty = false;
        return true;
    }

    function markDirty() {
        root.dirty = true;
    }

    function discardDraft() {
        root.dirty = false;
        root.conflict = false;
    }
}
