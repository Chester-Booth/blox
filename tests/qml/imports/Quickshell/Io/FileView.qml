import QtQuick

Item {
    default property alias adapterData: adapterContainer.data
    property string path: ""
    property bool preload: false
    property bool blockLoading: false
    property bool watchChanges: false
    property bool printErrors: true
    property bool atomicWrites: false
    property string fixtureText: ""

    signal loaded()
    signal loadFailed(var error)
    signal fileChanged()
    signal adapterUpdated()

    function text() {
        return fixtureText;
    }

    function reload() {
    }

    function writeAdapter() {
    }

    Item {
        id: adapterContainer
        visible: false
    }
}
