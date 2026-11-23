import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    readonly property var items: settings.items || []
    readonly property bool gridLayout: fullscreen || compactPresentation || width < 260
    contentReady: width > 0 && height > 0
    implicitWidth: 380
    implicitHeight: 100
    NativeScroll {
        id: shortcutScroll
        anchors.fill: parent
        anchors.margins: root.padding
        scrollbarMode: root.scrollbarMode
        contentWidth: availableWidth
        GridLayout {
            width: shortcutScroll.availableWidth
            columns: root.gridLayout ? Math.max(1, Math.floor(width / ((root.compactPresentation ? 85 : 170) * root.displayScale))) : Math.max(1, root.items.length)
            rowSpacing: root.gap
            columnSpacing: root.gap
            Repeater { model: root.items
                NativeAction {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.fullscreen ? 80 * root.displayScale : (root.compactPresentation ? 32 : 42) * root.density
                    text: modelData.label
                    fontFamily: root.bodyFont
                    pixelSize: (root.compactPresentation ? 12 : 14) * root.displayScale
                    foreground: root.foreground
                    accent: root.accent
                    rounding: root.rounding
                    density: root.density
                    onClicked: root.actionRequested("launch", {id: modelData.id})
                }
            }
            Text { visible: !root.items.length; text: "No shortcuts"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize }
        }
    }
}
