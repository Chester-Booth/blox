pragma Singleton
import QtQuick

QtObject {
    property var activeToplevel: null
    property var focusedMonitor: null
    property var monitorsByName: ({})
    signal rawEvent(var event)

    function refreshToplevels() {}

    function monitorFor(screen) {
        return monitorsByName[screen.name] || null;
    }
}
