pragma Singleton
import QtQuick

QtObject {
    readonly property string shellDir: "/nonexistent/shell"
    property var screens: []
    readonly property int processId: 4242

    property var detachedCalls: []

    function execDetached(arguments) {
        detachedCalls = detachedCalls.concat([arguments]);
    }

    function statePath(name) {
        return "/tmp/blox-qml-state/" + name;
    }

    function env(name) {
        return "";
    }
}
