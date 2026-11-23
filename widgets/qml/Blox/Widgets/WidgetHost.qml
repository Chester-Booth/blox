import QtQuick
import "WorkspaceRules.js" as Rules
import "JsonValue.js" as JsonValue
import "FirstPartyWorkflow.js" as Workflow

Item {
    id: root
    property var widget: null
    property var theme: defaultTheme
    property var provider: null
    property var workspace: ({id: 1, name: "1", special: false, empty: true})
    property bool fullscreen: false
    property bool editing: false
    // Reserved for the application owner. Never read launch context from profile, env or output.
    property var trustedLaunchContext: null
    // The application registers trusted manifests. Profile data cannot supply a URL.
    property var qmlRegistry: ({})
    property rect placementBounds: Qt.rect(0, 0, parent ? parent.width : 0, parent ? parent.height : 0)
    property rect fullscreenBounds: placementBounds
    readonly property real contentWidth: loader.item ? loader.item.implicitWidth : 0
    readonly property real contentHeight: loader.item ? loader.item.implicitHeight : 0
    readonly property var _normalGeometry: Rules.geometry(widget ? widget.placement : null, placementBounds, false,
        {width: contentWidth, height: contentHeight})
    readonly property real normalWidth: _normalGeometry.width
    readonly property real normalHeight: _normalGeometry.height
    readonly property Item view: loader.item
    readonly property string phase: _phase
    readonly property int revealGeneration: _generation
    readonly property var snapshot: _snapshot
    readonly property string error: _error
    readonly property string consumerId: Rules.consumerId()
    readonly property bool eligible: _eligibleNow()
    readonly property bool effectiveFullscreen: fullscreen && !!widget && !!widget.fullscreen && widget.fullscreen.enabled
    readonly property var _geometry: Rules.geometry(widget ? widget.placement : null, placementBounds, effectiveFullscreen,
        {width: contentWidth, height: contentHeight}, fullscreenBounds)
    readonly property string _configuration: _configurationKey()
    readonly property var _viewContext: {
        var generation = _generation;
        return {consumerId: consumerId, generation: generation, workspace: workspace, editing: editing,
            // Width measurement must not depend on wrapped content's height.
            availableWidth: Rules.geometry(widget ? widget.placement : null, placementBounds, false,
                {width: contentWidth, height: 0}).width,
            fullscreenMode: widget && widget.fullscreen ? widget.fullscreen.mode : "native",
            fullscreenEnabled: !!widget && !!widget.fullscreen && widget.fullscreen.enabled === true,
            presentation: widget && widget.appearance ? widget.appearance.presentation || "open" : "open",
            scrollbars: effectiveFullscreen ? "hide" : (widget && widget.appearance ? widget.appearance.scrollbars : "auto"),
            data: _data,
            requestData: function(name, options, required) { return root._requestData(generation, name, options, required); },
            releaseData: function(name) { root._releaseData(generation, name); },
            requestAction: function(action, payload, name) { if (generation === root._generation) root._action(action, payload, name); },
            requestRefresh: function() { if (generation === root._generation) root.refresh(); }};
    }
    property string _phase: "hidden"
    property int _generation: 0
    property var _snapshot: null
    property string _error: ""
    property int _revision: -1
    property bool _complete: false
    property var _subscribedProvider: null
    property var _subscription: null
    property url _source: ""
    property bool _viewInitialised: false
    property bool _accepting: false
    property var _handles: ({})
    property var _data: ({})
    property int _handleSerial: 0
    signal actionRequested(string action, var payload)
    signal applicationActionRequested(string action, var identity, var trustedContext)
    signal focusReleaseRequested()
    signal applicationWorkflowReady(var identity)
    signal applicationWorkflowCancelled(var identity)
    property var _applicationWorkflow: null

    x: _geometry.x
    y: _geometry.y
    width: _geometry.width
    height: _geometry.height
    clip: true

    WidgetTheme { id: defaultTheme }

    // This is the only element affected by backgroundOpacity.
    Rectangle {
        objectName: "widgetBackground"
        anchors.fill: parent
        visible: root.phase === "visible"
        color: root.theme && root.theme.palette ? root.theme.palette.background : "transparent"
        opacity: root.widget && root.widget.appearance ? root.widget.appearance.backgroundOpacity : 1
        radius: Math.min(width / 2, height / 2, 12 * (root.theme ? root.theme.radiusScale : 1))
    }
    // Foreground view controls get input first. Fullscreen blanks consume what they leave unhandled.
    MouseArea {
        anchors.fill: parent
        enabled: root.effectiveFullscreen && root.eligible
        acceptedButtons: Qt.AllButtons
        onPressed: event => event.accepted = true
        onWheel: event => event.accepted = true
    }
    Loader {
        id: loader
        anchors.fill: parent
        active: root._source.toString() !== "" && root.eligible
        visible: root.phase === "visible"
        onLoaded: root._initialiseView()
        onStatusChanged: {
            if (status === Loader.Error) root._fail("The widget view could not be loaded");
        }
    }
    Connections {
        target: loader.item
        ignoreUnknownSignals: true
        function onContentReadyChanged() { root._updateReady(); }
        function onReadinessChanged() { root._updateReady(); }
        function onActionRequested(action, payload) { root._action(action, payload); }
    }
    Connections {
        target: root.provider
        ignoreUnknownSignals: true
        function onConsumerStopped(consumerId, generation, ok) { root._producerStopped(consumerId, generation, ok); }
        function onSnapshotReady(consumerId, envelope) { root.acceptSnapshot(consumerId, envelope); }
        // Adaptors with a connection lifecycle can use these optional signals.
        function onConnectionError(message) { root._disconnect(String(message)); }
        function onReconnected() { root.refresh(); }
    }

    function _cancel() {
        var old = _subscribedProvider;
        var handles = _handles;
        _subscribedProvider = null;
        _subscription = null;
        _handles = {};
        _data = {};
        for (var name in handles) _unsubscribe(handles[name].provider, handles[name].id);
        _unsubscribe(old, consumerId);
    }

    // Read nested settings afresh. In-place JavaScript edits do not notify QML bindings.
    function _configurationKey() {
        var settings = widget ? widget.settings : null;
        if (widget && ["clock", "system", "calendar", "music", "command"].indexOf(widget.kind) >= 0) {
            settings = Object.assign({}, settings);
            // Presentation changes do not restart data work.
            delete settings.style;
            if (widget.kind === "command") {
                delete settings.fontFamily; delete settings.fontSize; delete settings.padding;
            }
        }
        return JsonValue.stringify({id: widget ? widget.id : null,
            kind: widget ? widget.kind : null, settings: settings,
            registry: widget && widget.kind === "qml" ? qmlRegistry : null});
    }

    // Call directly at action boundaries. In-place widget/workspace edits do not notify eligible.
    function _eligibleNow() {
        if (!widget || widget.enabled !== true || !visible) return false;
        if (!editing && (!Rules.matches(widget.workspaces, workspace)
                || (widget.visibility === "empty-workspace" && workspace.empty !== true))) return false;
        // Measured content needs a loaded view, so use its bounds rather than loaded dimensions.
        var expanded = fullscreen && widget.fullscreen && widget.fullscreen.enabled;
        var bounds = expanded ? fullscreenBounds : placementBounds;
        if (widget.placement && widget.placement.sizing === "content") return bounds.width > 0 && bounds.height > 0;
        var geometry = Rules.geometry(widget.placement, placementBounds, expanded, null, fullscreenBounds);
        return geometry.width > 0 && geometry.height > 0;
    }

    // Every view uses the identity captured at preparation, before any kind-specific action routing.
    function _currentSubscription(expected) {
        if (!_accepting || (expected !== undefined && _subscription !== expected)) return false;
        var subscription = _subscription;
        if (subscription && widget && subscription.generation === _generation
                && subscription.adapter === provider && subscription.kind === widget.kind
                && subscription.configuration === _configurationKey() && _eligibleNow()) return true;
        // Cancel ownership now. Deferred preparation cannot replay this action or reuse its context.
        refresh();
        return false;
    }

    function _unsubscribe(adapter, id) {
        if (adapter && typeof adapter.unsubscribe === "function") {
            try { adapter.unsubscribe(id); } catch (e) { /* Cancellation must still hide content. */ }
        }
    }

    function _setData(name, envelope) {
        var data = Object.assign({}, _data);
        data[name] = envelope;
        _data = data;
    }

    // A view can hold one managed request per declared provider. Replacing options cancels it.
    function _requestData(generation, name, options, required) {
        if (!_complete || generation !== _generation || !_accepting || !eligible || !widget || widget.kind !== "qml") return "";
        var allowed = widget.settings.providers || [];
        if (typeof name !== "string" || allowed.indexOf(name) < 0) {
            _fail("The view requested an undeclared provider"); return "";
        }
        if (!provider || typeof provider.subscribe !== "function") {
            _fail("No provider is connected"); return "";
        }
        var key;
        try { key = JsonValue.stringify(options || {}); }
        catch (e) { _fail("Provider options must be JSON"); return ""; }
        if (!key || key.length > 65536) { _fail("Provider options exceed the size limit"); return ""; }
        var canonical = JSON.parse(key);
        if (!canonical || typeof canonical !== "object" || Array.isArray(canonical)) {
            _fail("Provider options must be a JSON object"); return "";
        }
        var previous = _handles[name];
        var isRequired = required !== false;
        if (previous && previous.optionsKey === key && previous.required === isRequired) return previous.id;
        if (previous) _releaseData(generation, name, true);
        var id = consumerId + "-data-" + generation + "-" + (++_handleSerial);
        var handles = Object.assign({}, _handles);
        handles[name] = {id: id, provider: provider, optionsKey: key, required: isRequired,
            generation: generation, revision: -1};
        _handles = handles;
        _setData(name, {generation: generation, revision: -1, observedMonotonicMs: 0,
            state: "preparing", value: {}, error: ""});
        _updateReady();
        try { provider.subscribe(id, name, canonical, generation); }
        catch (e) { _fail(String(e)); return ""; }
        return id;
    }

    function _releaseData(generation, name, deferReady) {
        if (generation !== _generation) return;
        var handle = _handles[name];
        if (!handle) return;
        var handles = Object.assign({}, _handles);
        var data = Object.assign({}, _data);
        delete handles[name]; delete data[name];
        _handles = handles; _data = data;
        _unsubscribe(handle.provider, handle.id);
        if (!deferReady) _updateReady();
    }

    // Invalidation is synchronous. Only preparation is deferred to coalesce property changes.
    function refresh(preserveWorkflow) {
        if (!_complete) return;
        if (_applicationWorkflow && !(preserveWorkflow === true && _workflowCurrent())) cancelApplicationWorkflow();
        ++_generation;
        _phase = "hidden";
        _snapshot = null;
        _revision = -1;
        _error = "";
        _viewInitialised = false;
        _accepting = false;
        _source = "";
        loader.source = "";
        _cancel();
        var generation = _generation;
        Qt.callLater(function() {
            if (root._complete && root._generation === generation && !root._applicationWorkflow && root._eligibleNow()) root._prepare();
        });
    }

    function _resolveSource() {
        var nativeSources = {clock: "ClockView", music: "MusicView", system: "SystemView",
            network: "NetworkView", calendar: "CalendarView", notes: "NotesView", files: "FilesView",
            shortcuts: "ShortcutsView", weather: "WeatherView", terminal: "TerminalView", command: "CommandView"};
        if (widget.kind !== "qml") {
            var name = nativeSources[widget.kind];
            return name ? Qt.resolvedUrl("Native/" + name + ".qml") : "";
        }
        var settings = widget.settings || {};
        var manifest = qmlRegistry[settings.manifest];
        if (!manifest || !manifest.source || !manifest.layouts || typeof manifest.layouts.length !== "number") return "";
        var layouts = settings.layouts || [];
        var providers = settings.providers || [];
        if (providers.length > 16) return "";
        for (var i = 0; i < layouts.length; ++i)
            if (manifest.layouts.indexOf(layouts[i]) < 0) return "";
        for (var j = 0; j < providers.length; ++j)
            if (!manifest.providers || manifest.providers.indexOf(providers[j]) < 0) return "";
        if (effectiveFullscreen && (manifest.layouts.indexOf(widget.fullscreen.mode) < 0
                || layouts.indexOf(widget.fullscreen.mode) < 0)) return "";
        return manifest.source;
    }

    function _prepare() {
        _phase = "preparing";
        var source = _resolveSource();
        if (!source) { _fail("The widget kind or trusted manifest is unavailable"); return; }
        _subscription = {generation: _generation, adapter: provider, kind: widget.kind,
            configuration: _configurationKey()};
        _accepting = true;
        _source = source;
        loader.setSource(source, {
            context: Qt.binding(function() { return root._viewContext; }),
            settings: Qt.binding(function() {
                return root.widget ? (root.widget.kind === "qml" ? root.widget.settings.settings : root.widget.settings) : {};
            }),
            fullscreen: Qt.binding(function() { return root.effectiveFullscreen; }),
            theme: Qt.binding(function() { return root.theme; }),
            snapshot: Qt.binding(function() { return root._snapshot; })
        });
        if (_phase === "unavailable") return;
        if (widget.kind === "notes" || widget.kind === "shortcuts" || widget.kind === "qml") {
            // Settings-only views have no external observation. QML requests are managed separately.
            acceptSnapshot(consumerId, {generation: _generation, revision: 0,
                observedMonotonicMs: 0, state: "ready", value: {}, error: ""});
            return;
        }
        if (!provider || typeof provider.subscribe !== "function") {
            _fail("No provider is connected"); return;
        }
        _subscribedProvider = provider;
        try { provider.subscribe(consumerId, widget.kind, widget.settings || {}, _generation); }
        catch (e) { _fail(String(e)); }
    }

    function _initialiseView() {
        if (!loader.item || !widget) return;
        var item = loader.item;
        if (!("contentReady" in item) || !("snapshot" in item) || !("context" in item)) {
            _fail("The view must implement WidgetView"); return;
        }
        _viewInitialised = true;
        _updateReady();
    }

    function _validEnvelope(envelope, generation, revision) {
        return envelope && envelope.generation === generation && Number.isInteger(envelope.revision)
            && envelope.revision > revision && Number.isFinite(envelope.observedMonotonicMs)
            && ["preparing", "ready", "unavailable"].indexOf(envelope.state) >= 0;
    }

    function acceptSnapshot(id, envelope) {
        if (!eligible || !_accepting) return;
        if (id !== consumerId) {
            for (var name in _handles) {
                var handle = _handles[name];
                if (handle.id !== id) continue;
                if (!_validEnvelope(envelope, _generation, handle.revision)) return;
                handle.revision = envelope.revision;
                _setData(name, envelope);
                _updateReady();
                return;
            }
            return;
        }
        if (!_validEnvelope(envelope, _generation, _revision)) return;
        _revision = envelope.revision;
        _snapshot = envelope;
        _error = envelope.error || "";
        if (envelope.state === "unavailable") { _phase = "unavailable"; return; }
        _updateReady();
    }

    function _updateReady() {
        if (!eligible || !_viewInitialised || !_snapshot || _snapshot.generation !== _generation) return;
        for (var name in _handles) {
            var handle = _handles[name];
            if (!handle.required) continue;
            var envelope = _data[name];
            if (!envelope || envelope.generation !== _generation || envelope.state === "preparing") {
                _phase = "preparing"; return;
            }
            if (envelope.state === "unavailable") {
                _error = envelope.error || "A required provider is unavailable";
                _phase = "unavailable"; return;
            }
        }
        if (_snapshot.state === "ready" && loader.status === Loader.Ready && loader.item.contentReady) {
            _error = _snapshot.error || "";
            _phase = "visible";
        }
        else if (_snapshot.state !== "unavailable") _phase = "preparing";
    }

    // Keep demand during a lost connection so the adapter can retry. Hide still cancels it.
    function _disconnect(message) {
        if (!_complete || !eligible) return;
        ++_generation;
        _accepting = false;
        _viewInitialised = false;
        _phase = "unavailable";
        _error = message;
        _snapshot = null;
        _data = {};
        _source = "";
        loader.source = "";
    }

    function _fail(message) {
        _accepting = false;
        _phase = eligible ? "unavailable" : "hidden";
        _error = message;
        _snapshot = null;
        _cancel();
    }

    function _action(action, payload, providerName) {
        if (_applicationWorkflow || !_currentSubscription() || _phase !== "visible" || editing) return;
        const subscription = _subscription;
        const generation = _generation;
        const adapter = provider;
        const currentWidget = widget;
        const widgetIdentity = JsonValue.stringify(widget);
        const workspaceIdentity = JsonValue.stringify(workspace);
        const launchContext = trustedLaunchContext === null ? null : JSON.parse(JsonValue.stringify(trustedLaunchContext));
        function current() {
            return root._currentSubscription(subscription) && !root.editing && root._phase === "visible"
                && JsonValue.stringify(root.workspace) === workspaceIdentity
                && root.widget === currentWidget && JsonValue.stringify(root.widget) === widgetIdentity && root.provider === adapter;
        }
        let binding = null;
        if (widget.kind === "command" && action === "activate") {
            if (!payload || Object.keys(payload).length !== 1 || ["left", "right"].indexOf(payload.button) < 0) return;
            binding = widget.settings.actions ? widget.settings.actions[payload.button] : null;
            if (!binding || ["run", "launch"].indexOf(binding.kind) < 0) return;
            payload = {button: payload.button};
        } else if (widget.kind === "command" && ["fullscreen", "releaseFocus"].indexOf(action) < 0) return;
        actionRequested(action, JSON.parse(JsonValue.stringify(payload)));
        if (!current()) return;
        if (action === "releaseFocus") {
            _releaseViewFocus(view);
            focusReleaseRequested();
            return;
        }
        if (action === "fullscreen") return;
        if (binding && (binding.kind === "launch" || Workflow.operation(binding))) {
            applicationActionRequested(action, {widgetId: currentWidget.id, consumerId: consumerId,
                generation: generation, button: payload.button}, launchContext);
            return;
        }
        var targetId = consumerId;
        if (widget.kind === "qml") {
            if (providerName !== undefined) {
                if (!_handles[providerName]) return;
                targetId = _handles[providerName].id;
            } else {
                var names = Object.keys(_handles);
                if (names.length !== 1) return;
                targetId = _handles[names[0]].id;
            }
        } else if (["command", "terminal", "music"].indexOf(widget.kind) < 0) return;
        if (current() && adapter && typeof adapter.dispatchAction === "function") {
            // Action rejection must never invalidate the content subscription.
            try {
                if (binding && launchContext !== null) {
                    // Nested origin data may change without notifying the context binding.
                    const source = launchContext.workspace;
                    if (!source || source.id !== workspace.id || source.name !== workspace.name || source.special !== workspace.special) return;
                    adapter.dispatchAction(targetId, action, payload, generation, launchContext);
                }
                else adapter.dispatchAction(targetId, action, payload, generation);
            }
            catch (e) { /* Provider action errors do not change content readiness. */ }
        }
    }

    // Fixed application callback target. Root must locate this exact host by consumerId.
    function isCurrentAction(identity, context) {
        return !!identity && _currentSubscription() && _phase === "visible" && !editing
            && widget.kind === "command" && ["left", "right"].indexOf(identity.button) >= 0
            && identity.widgetId === widget.id && identity.consumerId === consumerId
            && identity.generation === _generation
            && JsonValue.stringify(trustedLaunchContext) === JsonValue.stringify(context);
    }

    // Application lifetime is separate from the reveal generation. The producer
    // stops before helper input; a later reveal cannot replay or overlap finite work.
    function beginApplicationWorkflow(identity, context) {
        if (_applicationWorkflow || !isCurrentAction(identity, context)) return false;
        const operation = Workflow.operation(widget.settings.actions[identity.button]);
        if (!operation || !_subscribedProvider || typeof _subscribedProvider.unsubscribeAndWait !== "function") return false;
        _applicationWorkflow = {identity: JSON.parse(JsonValue.stringify(identity)),
            context: JSON.parse(JsonValue.stringify(context)), widget: JsonValue.stringify(widget),
            adapter: provider, operation: operation};
        const old = _subscribedProvider;
        _subscribedProvider = null;
        try {
            if (old.unsubscribeAndWait(consumerId, identity.generation) === true) return true;
        } catch (error) { /* Failure cannot release helper input. */ }
        _unsubscribe(old, consumerId);
        cancelApplicationWorkflow();
        return false;
    }

    function _producerStopped(id, generation, ok) {
        const work = _applicationWorkflow;
        if (!work || work.identity.consumerId !== id || work.identity.generation !== generation || work.producerStopped) return;
        if (!ok || !_workflowCurrent()) { cancelApplicationWorkflow(); return; }
        work.producerStopped = true;
        applicationWorkflowReady(work.identity);
    }

    function _workflowCurrent() {
        const work = _applicationWorkflow;
        if (!work || work.cancelled || !widget || widget.enabled !== true || !visible || editing
                || work.widget !== JsonValue.stringify(widget) || work.adapter !== provider) return false;
        const source = work.context.workspace;
        // Todo can make the source occupied. Calendar deliberately focuses 1.
        // Other workspace changes, explicit hiding and edits still cancel.
        return workspace && workspace.special === false && workspace.name === String(workspace.id)
            && (workspace.id === source.id || (work.operation === "calendar" && workspace.id === 1))
            && trustedLaunchContext && trustedLaunchContext.outputName === work.context.outputName;
    }

    function cancelApplicationWorkflow() {
        const work = _applicationWorkflow;
        if (!work) return;
        // Keep the busy identity until the application confirms group teardown.
        work.cancelled = true;
        applicationWorkflowCancelled(work.identity);
    }

    function finishApplicationWorkflow(identity) {
        const work = _applicationWorkflow;
        if (!work || JsonValue.stringify(work.identity) !== JsonValue.stringify(identity)) return false;
        _applicationWorkflow = null;
        refresh();
        return true;
    }

    function _workspaceVisibilityChanged() {
        refresh(true);
    }

    function _releaseViewFocus(item) {
        if (!item) return;
        for (var i = 0; i < item.children.length; ++i) _releaseViewFocus(item.children[i]);
        item.focus = false;
    }

    onEligibleChanged: _workspaceVisibilityChanged()
    onWorkspaceChanged: if (_applicationWorkflow && !_workflowCurrent()) refresh()
    onVisibleChanged: if (_applicationWorkflow && !visible) refresh()
    onEditingChanged: if (_applicationWorkflow && editing) refresh()
    onWidgetChanged: if (_applicationWorkflow && !_workflowCurrent()) refresh()
    onTrustedLaunchContextChanged: if (_applicationWorkflow && !_workflowCurrent()) refresh()
    on_ConfigurationChanged: refresh()
    onProviderChanged: refresh()
    Component.onCompleted: { _complete = true; refresh(); }
    Component.onDestruction: { cancelApplicationWorkflow(); _complete = false; _accepting = false; _cancel(); }
}
