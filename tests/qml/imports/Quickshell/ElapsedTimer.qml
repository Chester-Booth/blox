import QtQuick
QtObject {
    property real valueNs: 0
    function elapsedNs() { return valueNs; }
    function restartNs() { valueNs = 0; return 0; }
}
