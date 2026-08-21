import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string query: ""
    property var items: []
    property int selectedIndex: 0
    property int requestSerial: 0
    property var nextCursor: null
    property bool loading: false
    property bool pendingRequest: false
    property bool pendingAppend: false
    property string error: ""
    property int pendingSerial: 0
    property string pendingQuery: ""
    property var pendingCursor: null
    readonly property bool actionBusy: action.running
    readonly property string command: Quickshell.env("HOME") + "/.config/quickshell/blox/scripts/launcher/clipboardctl.py"

    signal closeRequested()
    signal pasteRequested()

    function refresh() {
        requestSerial++;
        nextCursor = null;
        requestPage(false, requestSerial);
    }

    function requestPage(append, serial) {
        pendingRequest = true;
        pendingAppend = append;
        pendingSerial = serial;
        pendingQuery = query;
        pendingCursor = append ? nextCursor : null;
        loading = true;
        if (queryProcess.running) {
            queryProcess.signal(15);
            return ;
        }
        startPendingRequest();
    }

    function startPendingRequest() {
        if (!pendingRequest || queryProcess.running)
            return ;

        queryProcess.serial = pendingSerial;
        queryProcess.append = pendingAppend;
        const request = [command, "list", "--query", pendingQuery, "--limit", "50"];
        if (pendingAppend && pendingCursor !== null)
            request.push("--cursor", String(pendingCursor));

        pendingRequest = false;
        queryProcess.command = request;
        queryProcess.running = true;
    }

    function loadMore() {
        if (loading || nextCursor === null)
            return ;

        requestPage(true, requestSerial);
    }

    function activate() {
        if (action.running || !items[selectedIndex])
            return ;

        action.pasteAfterExit = true;
        action.command = [command, "replay", String(items[selectedIndex].id)];
        action.running = true;
    }

    function togglePin() {
        const item = items[selectedIndex];
        if (action.running || !item)
            return ;

        action.pasteAfterExit = false;
        action.command = [command, item.pinned_at ? "unpin" : "pin", String(item.id)];
        action.running = true;
    }

    function remove() {
        const item = items[selectedIndex];
        if (action.running || !item)
            return ;

        action.pasteAfterExit = false;
        action.command = [command, "remove", String(item.id)];
        action.running = true;
    }

    function clearAll() {
        if (action.running)
            return ;

        action.pasteAfterExit = false;
        action.command = [command, "clear"];
        action.running = true;
    }

    onQueryChanged: {
        requestSerial++;
        nextCursor = null;
        pendingRequest = false;
        if (queryProcess.running)
            queryProcess.signal(15);

        debounce.restart();
    }

    Timer {
        id: debounce

        interval: 120
        onTriggered: root.requestPage(false, root.requestSerial)
    }

    Process {
        id: queryProcess

        property int serial: 0
        property bool append: false

        onExited: {
            if (root.pendingRequest)
                Qt.callLater(root.startPendingRequest);
            else
                root.loading = false;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                if (queryProcess.serial !== root.requestSerial)
                    return ;

                try {
                    const response = JSON.parse(text);
                    root.error = response.ok ? "" : String(response.error || "Clipboard history is unavailable");
                    const received = response.ok ? response.items.map((item) => {
                        item.group = item.pinned_at ? "Pinned" : "Recent";
                        return item;
                    }) : [];
                    root.items = queryProcess.append ? root.items.concat(received) : received;
                    root.nextCursor = response.ok ? response.cursor : null;
                    if (!queryProcess.append)
                        root.selectedIndex = 0;

                } catch (error) {
                    root.error = "Clipboard history is unavailable";
                    if (!queryProcess.append)
                        root.items = [];

                    root.nextCursor = null;
                }
            }
        }

    }

    Process {
        id: action

        property bool pasteAfterExit: false
        property string responseError: ""

        onRunningChanged: {
            if (running)
                responseError = "";

        }
        onExited: (exitCode) => {
            if (pasteAfterExit) {
                pasteAfterExit = false;
                if (exitCode === 0 && !responseError.length)
                    root.pasteRequested();
                else
                    Quickshell.execDetached(["notify-send", "--app-name", "Blox clipboard", "--expire-time", "2500", "Clipboard error", "The selected item could not be copied."]);
            } else {
                if (exitCode !== 0 || responseError.length)
                    Quickshell.execDetached(["notify-send", "--app-name", "Blox clipboard", "--expire-time", "2500", "Clipboard error", responseError || "The clipboard action failed."]);

                root.refresh();
            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const response = JSON.parse(text);
                    action.responseError = response.ok ? "" : String(response.error || "Clipboard action failed");
                } catch (error) {
                    action.responseError = "Clipboard action failed";
                }
            }
        }

    }

}
