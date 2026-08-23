import QtQuick

QtObject {
    property string path: ""
    property bool preload: false
    property bool blockLoading: false
    property bool watchChanges: false
    property bool printErrors: true

    signal loaded()
    signal fileChanged()

    function text() {
        return "";
    }

    function reload() {
    }
}
