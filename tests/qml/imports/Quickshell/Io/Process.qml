import QtQuick

QtObject {
    property var command: []
    property var environment: ({})
    property bool running: false
    property bool stdinEnabled: false
    property QtObject stdout
    property QtObject stderr

    signal started()
    signal exited(int code, int status)
    property var sentSignals: []

    function signal(number) { sentSignals = sentSignals.concat([number]); }
    function finish(code, status) { running = false; exited(code, status); }
    onRunningChanged: { if (running) started(); }

    function write(value) {
    }

}
