import QtQuick
import qs.shared

Item {
    id: root

    property real radiusScale: 1.25
    property real densityScale: 1.0
    property real windowGap: 5
    property real inactiveOpacity: 1.0
    property real borderSize: 1

    readonly property real sceneScale: width / 260
    readonly property real gap: Math.max(0, windowGap * sceneScale)
    readonly property real barHeight: 13 * sceneScale
    readonly property real workspaceHeight: Math.max(0, height - barHeight - 2 * gap)
    readonly property real workspaceWidth: Math.max(0, width - 2 * gap)
    readonly property real mainWidth: Math.max(0, (workspaceWidth - gap) * 0.62)
    readonly property real stackWidth: Math.max(0, workspaceWidth - mainWidth - gap)
    readonly property real stackHeight: Math.max(0, (workspaceHeight - gap) / 2)
    readonly property real windowRadius: Math.round(8 * radiusScale * sceneScale)
    readonly property real innerPadding: Math.round(5 * densityScale * sceneScale)
    readonly property real sceneRadius: Math.min(width / 2, height / 2, windowRadius)

    implicitWidth: 260
    implicitHeight: width * 96 / 260
    clip: true

    Rectangle {
        anchors.fill: parent
        radius: root.sceneRadius
        color: Theme.withAlpha(Theme.background, 0.58)
    }

    component AppWindow: Rectangle {
        id: sceneWindow
        required property bool active
        readonly property real contentInset: Math.min(
            Math.max(2, root.innerPadding, root.windowRadius * 0.3) + (active ? root.borderSize : 0),
            Math.max(0, Math.min(width, height) / 4))
        radius: root.windowRadius
        color: active ? Theme.withAlpha(Theme.foreground, 0.12) : Theme.withAlpha(Theme.foreground, 0.08)
        border.color: active ? Theme.withAlpha(Theme.accent, 0.72) : "transparent"
        border.width: active ? Math.max(0, root.borderSize) : 0
        opacity: active ? 1 : root.inactiveOpacity
        clip: true

        Column {
            anchors.fill: parent
            anchors.margins: sceneWindow.contentInset
            spacing: Math.max(2, 3 * root.densityScale * root.sceneScale)
            Repeater {
                model: 3
                Rectangle {
                    width: Math.max(0, parent.width * (index === 1 ? 0.72 : 0.9))
                    height: Math.max(0, Math.min(3 * root.sceneScale, (parent.height - 2 * parent.spacing) / 3))
                    radius: height / 2
                    color: index === 0 && sceneWindow.active ? Theme.accent : Theme.withAlpha(Theme.foreground, 0.34)
                }
            }
        }
    }

    AppWindow { x: root.gap; y: root.gap; width: root.mainWidth; height: root.workspaceHeight; active: true }
    AppWindow { x: root.gap + root.mainWidth + root.gap; y: root.gap; width: root.stackWidth; height: root.stackHeight; active: false }
    AppWindow { x: root.gap + root.mainWidth + root.gap; y: root.gap + root.stackHeight + root.gap; width: root.stackWidth; height: root.stackHeight; active: false }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.barHeight
        color: Theme.withAlpha(Theme.foreground, 0.08)
        border.color: Theme.border
        Row {
            anchors.centerIn: parent
            spacing: 3 * root.densityScale * root.sceneScale
            Repeater {
                model: 5
                Rectangle {
                    width: Math.max(2, 5 * root.sceneScale)
                    height: width
                    radius: Math.min(width / 2, 2 * root.radiusScale * root.sceneScale)
                    color: index === 2 ? Theme.accent : Theme.withAlpha(Theme.foreground, 0.14)
                }
            }
        }
    }
}
