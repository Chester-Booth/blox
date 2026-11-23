import QtQuick
import Quickshell
import Blox.Services

// Guard native plugin objects when their D-Bus service owner disappears.
Scope {
    id: root
    property alias service: watcher.service
    property alias alternateService: watcher.alternateService
    property alias enabled: watcher.enabled
    property alias owner: watcher.owner
    property alias ready: watcher.ready
    readonly property bool available: watcher.available
    signal serviceFound()

    function refresh() { watcher.refresh(); }

    NativeServiceOwner {
        id: watcher
        onServiceFound: root.serviceFound()
    }
}
