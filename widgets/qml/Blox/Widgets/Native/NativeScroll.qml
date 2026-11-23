import QtQuick
import QtQuick.Controls

ScrollView {
    id: root
    objectName: "nativeScroll"
    property string scrollbarMode: "auto"
    readonly property bool drawsScrollbar: ScrollBar.vertical.visible
    clip: true
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ScrollBar.vertical.policy: scrollbarMode === "hide" ? ScrollBar.AlwaysOff : scrollbarMode === "show" ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
    ScrollBar.vertical.visible: scrollbarMode !== "hide" && (scrollbarMode === "show" || ScrollBar.vertical.active)
}
