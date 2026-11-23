import QtQuick
QtObject {
    property var menu
    readonly property var children: menu ? menu.items : []
}
