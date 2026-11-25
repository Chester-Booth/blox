import qs.shared
import QtQuick

QtObject {
    id: root

    required property var host
    property var draft: null
    property int editIndex: -1
    property bool editModePending: false
    property string errorMessage: ""

    function copy(value) { return JSON.parse(JSON.stringify(value)); }

    // QV4 Array.from counts UTF-16 units. Schema lengths count surrogate pairs once.
    function textLength(value) {
        let length = 0;
        for (let index = 0; index < value.length; ++index) {
            const unit = value.charCodeAt(index);
            const next = value.charCodeAt(index + 1);
            if (unit >= 0xd800 && unit <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) ++index;
            ++length;
        }
        return length;
    }

    function profile() {
        return typeof host.widgetProfileProvider === "function" ? host.widgetProfileProvider()
            : host.candidate ? host.candidate.widgets : null;
    }

    function items() {
        const source = profile();
        return source && source.schemaVersion === 1 && Array.isArray(source.widgets) ? source.widgets : [];
    }

    function sourceProfileError() {
        const source = profile();
        return source && source.schemaVersion === 1 && Array.isArray(source.widgets)
            && Object.keys(source).every(key => key === "schemaVersion" || key === "widgets")
            ? "" : "Unsupported widget profile. Expected schemaVersion 1 and a widgets list.";
    }

    // Validate the current draft before staging. The Settings owner also validates the full profile.
    function fieldError(value, rule, path) {
        if (rule.$ref) {
            let target = host.widgetSchema;
            for (const key of rule.$ref.slice(2).split("/")) target = target[key];
            rule = target;
        }
        if (rule.oneOf) {
            const matches = rule.oneOf.filter(branch => !fieldError(value, branch, path));
            return matches.length === 1 ? "" : path + ": invalid binding or value";
        }
        if (rule.anyOf) {
            return rule.anyOf.some(branch => !fieldError(value, branch, path)) ? "" : path + ": invalid value";
        }
        if (rule.const !== undefined && value !== rule.const) return path + ": unsupported value";
        const type = rule.type;
        if (type === "null" && value !== null
                || type === "integer" && !Number.isInteger(value)
                || type === "number" && (typeof value !== "number" || !isFinite(value))
                || type === "string" && typeof value !== "string"
                || type === "boolean" && typeof value !== "boolean"
                || type === "array" && !Array.isArray(value)
                || type === "object" && (!value || typeof value !== "object" || Array.isArray(value)))
            return path + ": expected " + type;
        if (rule.enum && rule.enum.indexOf(value) < 0) return path + ": unsupported value";
        if (typeof value === "number" && (rule.minimum !== undefined && value < rule.minimum || rule.maximum !== undefined && value > rule.maximum))
            return path + ": value outside allowed bounds";
        if (typeof value === "string") {
            const length = textLength(value);
            if (length < (rule.minLength || 0) || rule.maxLength !== undefined && length > rule.maxLength
                    || rule.pattern && !(new RegExp(rule.pattern)).test(value)) return path + ": invalid text";
        }
        if (Array.isArray(value) && (value.length < (rule.minItems || 0) || rule.maxItems !== undefined && value.length > rule.maxItems))
            return path + ": invalid number of entries";
        if (typeof value === "string" && rule["x-blox-maxUtf8Bytes"] !== undefined) {
            try {
                if (utf8Bytes(value) > rule["x-blox-maxUtf8Bytes"]) return path + ": text exceeds UTF-8 budget";
            } catch (error) { return path + ": invalid Unicode text"; }
        }
        if (Array.isArray(value)) {
            if (rule.uniqueItems && value.some((item, index) => value.slice(0, index).some(previous => JSON.stringify(previous) === JSON.stringify(item))))
                return path + ": entries must be unique";
            if (rule["x-blox-orderedRange"] && value.length === 2 && value[0] > value[1])
                return path + ": ranges need ascending endpoints";
            if (rule["x-blox-uniqueBy"]) {
                const key = rule["x-blox-uniqueBy"];
                const ids = value.map(item => item && item[key]);
                if (ids.some((id, index) => ids.indexOf(id) !== index)) return path + ": " + key + " values must be unique";
            }
            for (let index = 0; index < value.length; ++index) {
                for (const child of [rule.items, (rule.prefixItems || [])[index]]) {
                    if (!child) continue;
                    const error = fieldError(value[index], child, path + "[" + index + "]");
                    if (error) return error;
                }
            }
        } else if (value && typeof value === "object") {
            for (const key of rule.required || []) if (!Object.prototype.hasOwnProperty.call(value, key)) return path + ": missing " + key;
            if (rule.maxProperties !== undefined && Object.keys(value).length > rule.maxProperties) return path + ": too many properties";
            for (const key of Object.keys(value)) {
                if (rule.propertyNames) {
                    const error = fieldError(key, rule.propertyNames, path);
                    if (error) return error;
                }
                const child = Object.prototype.hasOwnProperty.call(rule.properties || {}, key) ? rule.properties[key] : null;
                if (!child && rule.additionalProperties === false) return path + ": unknown field " + key;
                const extra = typeof rule.additionalProperties === "object" ? rule.additionalProperties : null;
                const error = child || extra ? fieldError(value[key], child || extra, path + "." + key) : "";
                if (error) return error;
            }
            const budget = rule["x-blox-commandBudget"] || rule["x-blox-terminalBudget"];
            if (budget) {
                if (budget.maxCells !== undefined && value.columns * value.rows > budget.maxCells)
                    return path + ": terminal grid exceeds cell limit";
                let bytes = 0;
                const records = [value].concat(Object.values(value.actions || {}).filter(action => action !== null));
                for (const record of records) {
                    for (const argument of record.command) bytes += utf8Bytes(argument);
                    for (const key of Object.keys(record.environment || {})) bytes += utf8Bytes(key) + utf8Bytes(record.environment[key]);
                }
                if (bytes > budget.maxArgvEnvironmentUtf8Bytes) return path + ": command and environment exceed UTF-8 budget";
                const encoded = JSON.stringify(value).replace(/[\u007f-\uffff]/g, character => "\\u" + character.charCodeAt(0).toString(16).padStart(4, "0"));
                if (encoded.length > budget.maxEncodedJsonBytes) return path + ": settings exceed JSON budget";
            }
        }
        return "";
    }

    function utf8Bytes(value) { return encodeURIComponent(value).replace(/%[0-9A-F]{2}/g, "x").length; }

    function objectError(value, rule, path) { return fieldError(value, rule, path); }

    function profileError(nextItems) {
        if (!Array.isArray(nextItems)) return "Widgets must be a list.";
        if (nextItems.length > host.widgetSchema.properties.widgets.maxItems) return "Too many widgets.";
        const identifiers = [];
        for (const widget of nextItems) {
            if (!widget || typeof widget !== "object" || Array.isArray(widget)) return "Each widget must be an object.";
            const rule = host.widgetSchema.properties.widgets.items.oneOf.find(item => item.properties.kind.const === widget.kind);
            if (!rule) return "Unknown widget kind.";
            let error = objectError(widget, rule, widget.name || "Widget");
            if (error) return error;
            if (identifiers.indexOf(widget.id) >= 0) return "Widget identifiers must be unique.";
            identifiers.push(widget.id);
            for (const key of ["placement", "workspaces", "appearance", "fullscreen", "settings"]) {
                let field = rule.properties[key];
                if (field.$ref) field = host.widgetSchema.$defs[field.$ref.split("/").pop()];
                error = objectError(widget[key], field, key);
                if (error) return error;
            }
            if (widget.kind === "qml") {
                const manifest = host.widgetRegistry ? host.widgetRegistry[widget.settings.manifest] : null;
                if (!manifest) return "Choose a registered trusted QML manifest.";
                if (!widget.settings.layouts.every(layout => manifest.layouts.indexOf(layout) >= 0)
                        || !widget.settings.providers.every(provider => (manifest.providers || []).indexOf(provider) >= 0))
                    return "QML layouts and providers must be approved by its registry entry.";
                if (widget.settings.layouts.indexOf(widget.fullscreen.mode) < 0 || manifest.layouts.indexOf(widget.fullscreen.mode) < 0)
                    return "Fullscreen mode must be an approved QML layout.";
            }
            for (const id of widget.workspaces.ids) {
                if (!(typeof id === "string" && textLength(id) > 0 && textLength(id) <= 128 || Number.isInteger(id) && Math.abs(id) <= 1000000))
                    return "Workspaces need exact names or integer IDs.";
            }
            for (const range of widget.workspaces.ranges) {
                if (!Array.isArray(range) || range.length !== 2 || !range.every(id => Number.isInteger(id) && Math.abs(id) <= 1000000) || range[0] > range[1])
                    return "Workspace ranges need ascending integer endpoints.";
            }
        }
        return "";
    }

    function setItems(nextItems) {
        errorMessage = sourceProfileError();
        if (errorMessage) return false;
        if (!host.widgetSchema) { errorMessage = "Widget schema is unavailable."; return false; }
        const profile = {schemaVersion: 1, widgets: nextItems};
        errorMessage = profileError(nextItems);
        if (errorMessage) return false;
        if (!host.widgetItemsChangeAllowed(nextItems)) {
            errorMessage = "Widgets cannot be changed while Settings is busy.";
            return false;
        }
        if (typeof host.widgetProfileWriter === "function") {
            if (host.widgetProfileWriter(copy(profile)) === false) {
                errorMessage = "Could not stage the widget changes. Try again when Settings is ready.";
                return false;
            }
            return true;
        }
        const next = host.cloneCandidate();
        next.widgets = copy(profile);
        host.markCandidate(next, "widgets.widgets", true);
        return true;
    }

    function uniqueId() {
        const existing = items().map(item => item.id);
        let index = 1;
        while (existing.indexOf("widget-" + index) >= 0) index++;
        return "widget-" + index;
    }

    function newDraft(kind) {
        const entries = host.widgetCatalogue ? host.widgetCatalogue.widgets || [] : [];
        const entry = entries.find(item => item.kind === (kind || "clock"));
        if (!entry) { errorMessage = "Widget catalogue is unavailable."; return null; }
        return {id: uniqueId(), kind: entry.kind, name: entry.name, enabled: true,
            placement: {anchor: "top-left", x: 24, y: 24, width: entry.width, height: entry.height,
                sizing: entry.kind === "command" ? "content" : "fixed"},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "empty-workspace",
            appearance: {presentation: "open", backgroundOpacity: 0.8, scrollbars: "auto"},
            fullscreen: {enabled: false, mode: entry.kind === "terminal" ? "resize" : "native"}, settings: copy(entry.defaultSettings)};
    }

    function refreshDraftError() {
        if (!draft) { errorMessage = ""; return; }
        if (!host.widgetSchema) { errorMessage = "Widget schema is unavailable."; return; }
        const current = copy(items());
        if (editIndex >= 0 && editIndex < current.length) current[editIndex] = copy(draft);
        else current.push(copy(draft));
        errorMessage = profileError(current);
    }

    function updateDraft(values) {
        if (!draft) return;
        const next = copy(draft);
        Object.keys(values).forEach(key => Object.defineProperty(next, key, {value: values[key], writable: true, enumerable: true, configurable: true}));
        draft = next;
        refreshDraftError();
    }

    function updateOption(key, value) {
        if (!draft) return;
        const settings = copy(draft.settings);
        Object.defineProperty(settings, key, {value: copy(value), writable: true, enumerable: true, configurable: true});
        updateDraft({settings: settings});
    }

    function openEditor(index) {
        errorMessage = sourceProfileError();
        if (errorMessage) return;
        editIndex = index >= 0 && index < items().length ? index : -1;
        draft = editIndex >= 0 ? copy(items()[editIndex]) : newDraft("clock");
        refreshDraftError();
        if (draft) host.showModal("widget");
    }

    function openEditMode() {
        if (editModePending) return false;
        errorMessage = sourceProfileError();
        if (errorMessage) return false;
        if (!host.widgetItemsChangeAllowed(items())) {
            errorMessage = "Widgets cannot be changed while Settings is busy.";
            return false;
        }
        editModePending = true;
        host.rendered = false;
        Theme.widgetEditModeRequested(copy(items()));
        return true;
    }

    function saveDraft() {
        if (!draft) return false;
        const current = copy(items());
        if (editIndex >= 0) current[editIndex] = copy(draft);
        else current.unshift(copy(draft));
        if (!setItems(current)) return false;
        host.dismissModal();
        return true;
    }
}
