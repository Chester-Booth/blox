import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io
import "FirstPartyWorkflow.js" as Workflow

// Application actions resolve the current profile. View payloads carry identities only.
Scope {
    id: root

    property var widgetItems: Theme.widgetItems
    property var settingsWindow: null
    property var openCalendar: null
    property int workspaceId: 0
    // Fixed application integration, never a function supplied by a view or profile.
    property var validateCommandHost: null
    property var beginCommandWorkflow: null
    property var finishCommandWorkflow: null
    property bool checkingHost: false
    property string scriptRoot: Quickshell.shellDir + "/scripts"
    property int timeoutMs: 10000
    readonly property int applicationPid: Quickshell.processId
    property var activeRequest: null
    property bool timedOut: false
    property bool processExited: false
    property bool outputFinished: false
    property int exitCode: 0
    property int exitStatus: 0
    readonly property bool busy: activeRequest !== null
    property var lastResult: ({ok: true, code: "idle", message: ""})

    signal actionFinished(string widgetId, string action, var result)

    function result(widgetId, action, ok, code, message, identity) {
        const value = {ok: ok, code: code, message: message || ""};
        if (identity) value.identity = JSON.parse(JSON.stringify(identity));
        lastResult = value;
        actionFinished(widgetId, action, lastResult);
        return lastResult;
    }

    function currentCommand(request) {
        if (checkingHost || typeof validateCommandHost !== "function") return false;
        checkingHost = true;
        let accepted = false;
        try {
            accepted = validateCommandHost(JSON.parse(JSON.stringify(request.identity)),
                JSON.parse(JSON.stringify(request.hostContext))) === true;
        } catch (error) { accepted = false; }
        finally { checkingHost = false; }
        // The callback may change the profile synchronously.
        const matches = widgetItems.filter(item => item.id === request.widgetId && item.enabled === true);
        return accepted && matches.length === 1 && JSON.stringify(matches[0]) === request.widgetJson;
    }

    function dispatchCommand(widget, action, identity, trustedContext) {
        if (action !== "activate") return result(widget.id, action, false, "unsupported", "Unsupported command action");
        if (busy || actionProcess.running || checkingHost)
            return result(widget.id, action, false, "busy", "A widget action is still starting");
        if (!identity || Object.keys(identity).sort().join(",") !== "button,consumerId,generation,widgetId"
                || identity.widgetId !== widget.id || typeof identity.consumerId !== "string"
                || !identity.consumerId.length || identity.consumerId.length > 128
                || !Number.isInteger(identity.generation) || identity.generation < 0 || identity.generation > 2147483647
                || ["left", "right"].indexOf(identity.button) < 0)
            return result(widget.id, action, false, "invalid-data", "Invalid command action identity");
        const binding = widget.settings && widget.settings.actions ? widget.settings.actions[identity.button] : null;
        const workflow = Workflow.operation(binding);
        if (!binding || (binding.kind !== "launch" && !workflow))
            return result(widget.id, action, false, "unavailable", "Command action is no longer available");
        // Capture everything before the fixed callback can re-enter application code.
        let request;
        try {
            const context = JSON.parse(JSON.stringify(trustedContext));
            const workspace = context.workspace;
            if (Object.keys(context).sort().join(",") !== "outputName,workspace"
                    || typeof context.outputName !== "string" || !context.outputName.length
                    || /[\x00-\x1f]/.test(context.outputName)
                    || encodeURIComponent(context.outputName).replace(/%[0-9A-F]{2}/g, "x").length > 256
                    || !workspace || Object.keys(workspace).sort().join(",") !== "id,name,special"
                    || !Number.isInteger(workspace.id) || workspace.id < 1 || workspace.id > 2147483647
                    || workspace.name !== String(workspace.id) || workspace.special !== false)
                throw new Error("unsupported source workspace");
            const capturedIdentity = JSON.parse(JSON.stringify(identity));
            const widgetJson = JSON.stringify(widget);
            const input = JSON.stringify({widget: JSON.parse(widgetJson), action: action,
                payload: {button: capturedIdentity.button}, identity: capturedIdentity, hostContext: context});
            if (input.length > 524288) throw new Error("oversized configuration");
            request = {widgetId: widget.id, action: action, input: input, widgetJson: widgetJson,
                identity: capturedIdentity, hostContext: context, workflow: workflow,
                workflowTimeoutMs: workflow ? Workflow.cap(binding) * 1000 + 3000 : 0};
        } catch (error) {
            return result(widget.id, action, false, "unavailable", "Source workspace is unavailable");
        }
        if (!currentCommand(request))
            return result(widget.id, action, false, "unavailable", "Widget host is no longer current");
        return start(request);
    }

    function dispatch(widgetId, action, payload, trustedContext) {
        if (checkingHost) return result(widgetId, action, false, "busy", "A widget action is still starting");
        const matches = widgetItems.filter(item => item.id === widgetId && item.enabled === true);
        if (matches.length !== 1) return result(widgetId, action, false, "unavailable", "Widget is no longer enabled");
        const widget = matches[0];
        if (widget.kind === "command") return dispatchCommand(widget, action, payload, trustedContext);
        if (widget.kind === "music" || widget.kind === "terminal")
            return {ok: true, code: "provider-managed", message: ""};
        if (widget.kind === "notes" && action === "edit") {
            const opened = settingsWindow && typeof settingsWindow.openWidgetEditor === "function" && settingsWindow.openWidgetEditor(widgetId);
            return result(widgetId, action, !!opened, opened ? "ok" : "unavailable", opened ? "" : "Widget editor is unavailable");
        }
        if (widget.kind === "calendar" && action === "open") {
            const opened = typeof openCalendar === "function" && openCalendar();
            return result(widgetId, action, !!opened, opened ? "ok" : "unavailable", opened ? "" : "Calendar is unavailable");
        }
        if (!((widget.kind === "files" && action === "open") || (widget.kind === "shortcuts" && action === "launch")))
            return result(widgetId, action, false, "unsupported", "Unsupported widget action");
        if (busy || actionProcess.running) return result(widgetId, action, false, "busy", "A widget action is still starting");
        let identity;
        if (widget.kind === "files") {
            if (!payload || typeof payload.path !== "string" || !payload.path.length || payload.path.length > 4096)
                return result(widgetId, action, false, "invalid-data", "Invalid file path");
            identity = {path: payload.path};
        } else {
            if (!payload || typeof payload.id !== "string" || !(widget.settings.items || []).some(item => item.id === payload.id))
                return result(widgetId, action, false, "invalid-data", "Shortcut no longer exists");
            identity = {id: payload.id};
        }
        const input = JSON.stringify({widget: widget, action: action, payload: identity, workspaceId: workspaceId});
        if (input.length > 524288) return result(widgetId, action, false, "invalid-data", "Widget action configuration is too large");
        return start({widgetId: widgetId, action: action, input: input});
    }

    function start(request) {
        activeRequest = request;
        timedOut = false;
        processExited = false;
        outputFinished = false;
        actionProcess.command = ["python3", scriptRoot + "/widgets/action.py"].concat(request.workflow ? ["--workflow", String(applicationPid)] : []);
        actionTimeout.restart();
        actionProcess.running = true;
        return {ok: true, code: "pending", message: ""};
    }

    function maybeFinish() {
        if (processExited && outputFinished) finish(exitCode, exitStatus, actionOutput.text);
    }

    function finish(code, status, output) {
        actionTimeout.stop();
        producerStopTimeout.stop();
        killTimeout.stop();
        const request = activeRequest;
        activeRequest = null;
        if (!request) return;
        function complete(ok, resultCode, message) {
            return root.result(request.widgetId, request.action, ok, resultCode, message, request.identity);
        }
        if (request.workflow && typeof finishCommandWorkflow === "function") finishCommandWorkflow(request.identity);
        if (request.cancelled) {
            complete(false, "cancelled", "Widget action was cancelled");
            return;
        }
        if (request.rejected) {
            complete(false, "unavailable", "Widget host is no longer current");
            return;
        }
        if (timedOut) {
            complete(false, "timeout", request.workflow && !request.inputSent
                ? "Producer teardown was not confirmed; workflow did not start"
                : "Could not confirm whether the application started");
            return;
        }
        try {
            if (output.length > 8192) throw new Error("oversized response");
            const reply = JSON.parse(output);
            if (typeof reply.ok !== "boolean" || typeof reply.code !== "string" || typeof reply.message !== "string" || (reply.ok && (code !== 0 || status !== 0)))
                throw new Error("invalid response");
            complete(reply.ok, reply.code, reply.message);
        } catch (error) {
            complete(false, "failed", "Widget action did not start");
        }
    }

    function matchingWorkflow(identity) {
        const request = activeRequest;
        return request && request.workflow && identity && request.identity.widgetId === identity.widgetId
            && request.identity.consumerId === identity.consumerId && request.identity.generation === identity.generation
            && request.identity.button === identity.button ? request : null;
    }

    function workflowReady(identity) {
        const request = matchingWorkflow(identity);
        if (!request || !request.waitingForProducer || request.cancelled || request.rejected || timedOut
                || request.inputSent || !actionProcess.running) return false;
        checkWorkflowConfiguration();
        if (request.cancelled) return false;
        producerStopTimeout.stop();
        request.waitingForProducer = false;
        request.inputSent = true;
        actionProcess.write(request.input + "\n");
        return true;
    }

    function cancelWorkflow(identity) {
        const request = matchingWorkflow(identity);
        if (!request) return false;
        if (!request.cancelled) {
            request.cancelled = true;
            producerStopTimeout.stop();
            actionProcess.signal(15);
            killTimeout.restart();
        }
        return true;
    }

    function checkWorkflowConfiguration() {
        const request = activeRequest;
        if (!request || !request.workflow) return;
        const matches = widgetItems.filter(item => item.id === request.widgetId && item.enabled === true);
        if (matches.length !== 1 || JSON.stringify(matches[0]) !== request.widgetJson) cancelWorkflow(request.identity);
    }
    onWidgetItemsChanged: checkWorkflowConfiguration()

    Timer {
        id: actionTimeout
        objectName: "widget-action-timeout"
        interval: root.activeRequest && root.activeRequest.workflow ? root.activeRequest.workflowTimeoutMs : root.timeoutMs
        onTriggered: {
            root.timedOut = true;
            actionProcess.signal(15);
            killTimeout.restart();
        }
    }
    Timer {
        id: producerStopTimeout
        objectName: "widget-producer-stop-timeout"
        interval: 3000
        onTriggered: {
            root.timedOut = true;
            actionProcess.signal(15);
            killTimeout.restart();
        }
    }
    Timer {
        id: killTimeout
        objectName: "widget-action-kill-timeout"
        interval: 1000
        onTriggered: { actionProcess.signal(9); actionProcess.running = false; }
    }
    Process {
        id: actionProcess
        objectName: "widget-action-process"
        stdinEnabled: true
        onStarted: {
            const request = root.activeRequest;
            if (!request) return;
            if (request.identity && !root.currentCommand(request)) {
                request.rejected = true;
                signal(15);
                killTimeout.restart();
                return;
            }
            if (request.workflow) {
                request.waitingForProducer = true;
                producerStopTimeout.restart();
                if (typeof root.beginCommandWorkflow !== "function"
                        || root.beginCommandWorkflow(request.identity, request.hostContext) !== true) {
                    request.rejected = true;
                    signal(15);
                    killTimeout.restart();
                    return;
                }
                // Only a matching broker teardown acknowledgement releases input.
                return;
            }
            write(request.input + "\n");
        }
        onExited: (code, status) => {
            root.exitCode = code;
            root.exitStatus = status;
            root.processExited = true;
            root.maybeFinish();
        }
        stdout: StdioCollector {
            id: actionOutput
            onStreamFinished: { root.outputFinished = true; root.maybeFinish(); }
        }
    }
}
