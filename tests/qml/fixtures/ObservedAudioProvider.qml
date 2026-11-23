import QtQuick

MediaKeyAudioProvider {
    property bool deferWrites: false
    function setVolume(value) {
        if (!deferWrites)
            volume = Number(value) / 100;
        return true;
    }
}
