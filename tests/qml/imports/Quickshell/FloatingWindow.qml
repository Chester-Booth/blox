import QtQuick

// QsWindow is an Item-backed wrapper, not a QtQuick Window. Tests mount it
// inside a real host Window so attached Window.window resolves to the native
// QQuickWindow without giving the wrapper native-only properties.
Item {
    id: root

    property Item contentItem: root
    property size minimumSize: Qt.size(0, 0)
    property var screen: null
    property var targetScreen: null
    property var _backingWindow: null
    property string title: ""
    property color color: "transparent"

    signal closed()
}
