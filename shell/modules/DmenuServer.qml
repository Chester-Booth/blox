import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool busy: false
    readonly property string scripts: Quickshell.env("HOME") + "/.config/quickshell/blox/scripts/launcher"

    signal request(var options, string prompt, string query, var settings)
    signal updated(var options)
    signal abandoned()

    function finish(value, cancelled) {
        if (!busy || !bridge.running)
            return ;

        busy = false;
        bridge.write(JSON.stringify({
            "value": value,
            "cancelled": cancelled
        }) + "\n");
    }

    Process {
        id: bridge

        command: ["python3", root.scripts + "/parent_guard.py", "python3", root.scripts + "/dmenu_server.py"]
        stdinEnabled: true
        running: true
        onExited: {
            if (root.busy) {
                root.busy = false;
                root.abandoned();
            }
            restart.restart();
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: (line) => {
                try {
                    const message = JSON.parse(line);
                    if (message.event === "abandoned") {
                        if (root.busy) {
                            root.busy = false;
                            root.abandoned();
                        }
                        return ;
                    }
                    if (message.event === "update" && Array.isArray(message.options)) {
                        root.updated(message.options);
                        return ;
                    }
                    const options = message.options || [];
                    if (message.event !== "request" || !Array.isArray(options))
                        return ;

                    root.busy = true;
                    root.request(options, String(message.prompt || ""), String(message.query || ""), {
                        "insensitive": message.insensitive === true,
                        "lines": Math.max(0, Math.min(100, Number(message.lines || 0))),
                        "monitor": String(message.monitor || ""),
                        "bottom": message.bottom === true,
                        "fast": message.fast === true
                    });
                } catch (error) {
                }
            }
        }

    }

    Timer {
        id: restart

        interval: 500
        onTriggered: bridge.running = true
    }

}
