import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Notifications

Scope {
    id: root

    property string openPanel: ""
    property real openPanelY: 8
    property real panelY: 0
    property bool dnd: false
    property bool toastsEnabled: true
    property var items: server.trackedNotifications.values
    property var toasts: []
    property bool initialSyncComplete: false
    property double toggleAllowedAt: 0
    property int nextToastId: 0
    property var actionRunner: null
    property var persistentState: null
    property string focusScript: ""
    property var actionResult: ({"version": 1, "ok": true, "code": "ok", "message": "", "data": null})
    property int sourceFocusNotificationId: -1
    property bool sourceFocusNotificationDismissed: false

    signal openRequested(real centreY)
    signal closeRequested()

    function log(event, detail) {
        console.log("[blox.notifications] " + new Date().toISOString() + " " + event + " " + (detail || ""));
    }

    function status() {
        const count = items ? items.length : 0;
        return {
            "icon": dnd ? "󰂛" : count > 0 ? "󰂚" : "󰂜",
            "class": dnd ? "dnd" : count > 0 ? "notification" : "none",
            "count": count,
            "dnd": dnd,
            "inhibited": false,
            "tooltip": (count === 1 ? "1 notification" : count + " notifications") + "\nDND: " + (dnd ? "true" : "false")
        };
    }

    function clear() {
        const current = items ? items.slice() : [];
        for (let i = 0; i < current.length; i++) {
            notificationDismissed(current[i]);
            current[i].dismiss();
        }
        toasts = [];
    }

    function toggleDnd() {
        if (persistentState)
            persistentState.notificationDnd = !persistentState.notificationDnd;
        else
            dnd = !dnd;
    }

    function makeActionResult(ok, code, message, data) {
        return {"version": 1, "ok": ok, "code": code, "message": message || "", "data": data === undefined ? null : data};
    }

    function resultNotificationId(result) {
        return result && result.data && result.data.notificationId !== undefined
            ? Number(result.data.notificationId) : -1;
    }

    function clearActionResultForNotification(notification) {
        const notificationId = Number(notification && notification.id || 0);
        if (notificationId === sourceFocusNotificationId)
            sourceFocusNotificationDismissed = true;
        if (notificationId === resultNotificationId(actionResult))
            actionResult = makeActionResult(true, "ok", "", null);
    }

    function notificationDismissed(notification) {
        if (notification)
            clearActionResultForNotification(notification);
    }

    function activate(notification) {
        if (!notification)
            return actionResult = makeActionResult(false, "invalid-data", "This notification is no longer available.", null);

        // Focus first so an action can safely close its notification or change
        // the application's own view.
        const focusResult = focusSource(notification, "notification-action");
        if (focusResult.code === "busy")
            return focusResult;
        const actions = notification.actions || [];
        for (let i = 0; i < actions.length; i++) {
            if (actions[i].identifier === "default") {
                try {
                    actions[i].invoke();
                } catch (error) {
                    return actionResult = makeActionResult(false, "failed", "Could not open the notification.", {"operation": "notification-action", "notificationId": notification.id || 0});
                }

                // NotificationAction.invoke() returns void, so this records
                // dispatch only. Source-focus completion remains asynchronous.
                if (focusResult.code !== "pending")
                    actionResult = makeActionResult(true, "dispatched", "", {"operation": "notification-action", "notificationId": notification.id || 0});
                return actionResult;
            }
        }

        if (focusResult.code === "disabled")
            return actionResult = makeActionResult(false, "unavailable", "This notification has no action to open.", {"operation": "notification-action", "notificationId": notification.id || 0});

        return focusResult;
    }

    function hint(notification, names) {
        const hints = notification && notification.hints ? notification.hints : null;
        if (!hints)
            return "";

        for (let i = 0; i < names.length; i++) {
            const value = hints[names[i]];
            if (value !== undefined && value !== null && String(value).length > 0)
                return String(value);

        }
        return "";
    }

    function normaliseFocusValue(value) {
        return String(value || "").toLowerCase().replace(/\.desktop$/, "").replace(/[^a-z0-9]/g, "");
    }

    function canFocusSource(notification) {
        if (!notification)
            return false;

        const wantedAddress = hint(notification, ["x-blox-window-address", "window-address"]);
        const wantedPid = Number(hint(notification, ["x-blox-sender-pid", "sender-pid", "x-kde-pid", "pid"])) || 0;
        const app = normaliseFocusValue(notification.appName);
        const desktop = normaliseFocusValue(notification.desktopEntry);
        const candidates = [app, desktop].filter((value, index, values) => {
            return value.length > 1 && values.indexOf(value) === index;
        });
        const toplevels = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < toplevels.length; i++) {
            const client = toplevels[i].lastIpcObject || ({
            });
            if (wantedAddress.length > 0 && String(client.address || "").toLowerCase() === wantedAddress.toLowerCase())
                return true;

            if (wantedPid > 0 && Number(client.pid || 0) === wantedPid)
                return true;

            if (wantedAddress.length > 0 || wantedPid > 0)
                continue;

            const clientClass = normaliseFocusValue(client.class);
            const initialClass = normaliseFocusValue(client.initialClass);
            for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex++) {
                const candidate = candidates[candidateIndex];
                if (clientClass === candidate || initialClass === candidate || (candidate.length > 2 && (clientClass.indexOf(candidate) >= 0 || initialClass.indexOf(candidate) >= 0)))
                    return true;

            }
        }
        return false;
    }

    function activationLabel(notification) {
        const actions = notification ? notification.actions || [] : [];
        for (let i = 0; i < actions.length; i++) {
            if (actions[i].identifier === "default") {
                const label = String(actions[i].text || "").trim();
                return label.length > 0 ? label : "Open";
            }
        }
        return canFocusSource(notification) ? "Focus" : "";
    }

    function focusSource(notification, operation) {
        if (!notification)
            return actionResult = makeActionResult(false, "invalid-data", "This notification is no longer available.", null);

        const notificationId = notification.id || 0;
        if (sourceFocusProcessObject.running) {
            return actionResult = makeActionResult(false, "busy", "Another notification is being focused. Try again when it finishes.", {
                "operation": operation || "notification-focus",
                "notificationId": notificationId,
                "sourceFocusNotificationId": sourceFocusNotificationId
            });
        }

        if (focusScript.trim().length === 0)
            return actionResult = makeActionResult(true, "disabled", "", {"operation": "notification-focus", "notificationId": notificationId});

        const windowAddress = hint(notification, ["x-blox-window-address", "window-address"]);
        const senderPid = hint(notification, ["x-blox-sender-pid", "sender-pid", "x-kde-pid", "pid"]);
        log("activate", "app=" + (notification.appName || "") + " desktop=" + (notification.desktopEntry || "") + " address=" + windowAddress + " pid=" + senderPid + " summary=" + (notification.summary || ""));
        sourceFocusNotificationId = notificationId;
        sourceFocusNotificationDismissed = false;
        actionResult = makeActionResult(true, "pending", "", {"operation": "notification-focus", "pending": true, "notificationId": sourceFocusNotificationId});
        sourceFocusProcessObject.command = ["env", "BLOX_NOTIFICATION_APP_NAME=" + (notification.appName || ""), "BLOX_NOTIFICATION_DESKTOP_ENTRY=" + (notification.desktopEntry || ""), "BLOX_NOTIFICATION_WINDOW_ADDRESS=" + windowAddress, "BLOX_NOTIFICATION_SENDER_PID=" + senderPid, focusScript];
        sourceFocusProcessObject.running = true;
        return actionResult;
    }

    function finishSourceFocus(exitCode, exitStatus) {
        const notificationId = sourceFocusNotificationId;
        const dismissed = sourceFocusNotificationDismissed;
        sourceFocusNotificationId = -1;
        sourceFocusNotificationDismissed = false;
        const data = {"operation": "notification-focus", "notificationId": notificationId, "exitCode": exitCode, "exitStatus": exitStatus};
        if (dismissed) {
            const resultSourceFocusId = actionResult && actionResult.code === "busy" && actionResult.data
                ? Number(actionResult.data.sourceFocusNotificationId) : -1;
            if (notificationId === resultNotificationId(actionResult) || notificationId === resultSourceFocusId)
                actionResult = makeActionResult(true, "ok", "", null);
            return actionResult;
        }

        const currentResult = actionResult;
        if (currentResult && currentResult.ok === false && currentResult.code === "failed" && currentResult.data
            && currentResult.data.operation === "notification-action"
            && Number(currentResult.data.notificationId) === notificationId)
            return currentResult;

        if (exitCode === 0 && exitStatus === 0)
            return actionResult = makeActionResult(true, "ok", "", data);

        let code = "failed";
        let message = "Could not focus the notification source.";
        if (exitStatus !== 0)
            message = "The notification focus helper stopped unexpectedly.";
        else if (exitCode === 127) {
            code = "unavailable";
            message = "The notification focus helper could not be found.";
        } else if (exitCode === 126) {
            code = "permission-denied";
            message = "The notification focus helper could not be run.";
        } else if (exitCode === 124) {
            code = "timeout";
            message = "The notification focus helper timed out.";
        }
        return actionResult = makeActionResult(false, code, message, data);
    }

    function open(centreY) {
        const now = Date.now();
        // Only pass an explicit coordinate when the caller supplied one.
        // Passing -1 lets BarSurfaceController resolve the live anchor on the active screen.
        const targetY = centreY !== undefined && centreY > 0 ? centreY : -1;
        if (openPanel === "notifications" || now < toggleAllowedAt)
            return ;

        toggleAllowedAt = now + 750;
        toasts = [];
        openRequested(targetY);
    }

    function toggle() {
        const now = Date.now();
        if (now < toggleAllowedAt)
            return ;

        if (openPanel === "notifications") {
            toggleAllowedAt = now + 750;
            closeRequested();
        } else {
            open();
        }
    }

    function addToast(notification) {
        if (!toastsEnabled || dnd || openPanel === "notifications")
            return ;

        const timeout = notification.expireTimeout && notification.expireTimeout > 0 ? notification.expireTimeout : 6000;
        const boundedTimeout = Math.max(3500, Math.min(12000, timeout));
        const next = toasts ? toasts.slice() : [];
        next.unshift({
            "toastId": ++nextToastId,
            "notification": notification,
            "timeout": boundedTimeout,
            "expiresAt": Date.now() + boundedTimeout
        });
        toasts = next.slice(0, 4);
    }

    function markCentreOnly(notification) {
        if (!notification)
            return ;

        notification.tracked = true;
        notification.bloxToastKnown = true;
        if (!notification.bloxReceivedAt)
            notification.bloxReceivedAt = Date.now();

    }

    function markExistingCentreOnly() {
        const current = items ? items.slice() : [];
        for (let i = 0; i < current.length; i++) markCentreOnly(current[i])
        initialSyncComplete = true;
    }

    function removeToast(notification) {
        toasts = toasts ? toasts.filter((item) => {
            return item.notification !== notification;
        }) : [];
    }

    onDndChanged: {
        if (dnd)
            toasts = [];

    }

    Connections {
        function onNotificationPositionPreviewRequested() {
            Quickshell.execDetached(["notify-send", "--app-name", "Theme picker", "--expire-time", "2500", "Notification position", "Previewing " + Theme.notificationPosition]);
        }

        target: Theme
    }

    Timer {
        interval: 1200
        repeat: false
        running: true
        onTriggered: root.markExistingCentreOnly()
    }

    NotificationServer {
        id: server

        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        actionsSupported: true
        actionIconsSupported: true
        inlineReplySupported: true
        onNotification: (notification) => {
            const known = notification.bloxToastKnown === true;
            notification.tracked = true;
            if (!notification.bloxReceivedAt)
                notification.bloxReceivedAt = Date.now();

            notification.bloxToastKnown = true;
            if (!known && root.initialSyncComplete)
                root.addToast(notification);

            notification.closed.connect(() => {
                root.notificationDismissed(notification);
                return root.removeToast(notification);
            });
        }
    }

    Process {
        id: sourceFocusProcessObject
        objectName: "notification-focus-process"

        onExited: (exitCode, exitStatus) => root.finishSourceFocus(exitCode, exitStatus)
    }

    IpcHandler {
        function open() : string {
            root.open();
            return "open";
        }

        function toggle() : string {
            root.toggle();
            return root.openPanel === "notifications" ? "open" : "closed";
        }

        function close() : string {
            root.closeRequested();
            return "closed";
        }

        function dnd() : string {
            root.toggleDnd();
            return root.dnd ? "enabled" : "disabled";
        }

        function clear() : string {
            root.clear();
            return "cleared";
        }

        target: "notifications"
    }

}
