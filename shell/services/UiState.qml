import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property alias notificationDnd: state.notificationDnd
    property alias activeMprisPlayer: state.activeMprisPlayer

    FileView {
        path: Quickshell.statePath("ui-state.json")
        preload: true
        blockLoading: true
        atomicWrites: true
        printErrors: false
        onAdapterUpdated: writeAdapter()

        JsonAdapter {
            id: state

            property bool notificationDnd: false
            property string activeMprisPlayer: ""
        }

    }

}
