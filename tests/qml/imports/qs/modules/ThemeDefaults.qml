import QtQuick

QtObject {
    readonly property bool ready: true
    function widgetProfile(name) {
        return {opacity: 0.7, padding: 8, radius: 6, font_size: 12};
    }
}
