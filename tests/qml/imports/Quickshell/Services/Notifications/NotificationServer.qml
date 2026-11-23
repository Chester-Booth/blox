import QtQuick

QtObject {
    property bool keepOnReload: false
    property bool persistenceSupported: false
    property bool bodySupported: false
    property bool bodyMarkupSupported: false
    property bool bodyImagesSupported: false
    property bool imageSupported: false
    property bool actionsSupported: false
    property bool actionIconsSupported: false
    property bool inlineReplySupported: false
    property var trackedNotifications: ({"values": []})

    signal notification(var notification)
}
