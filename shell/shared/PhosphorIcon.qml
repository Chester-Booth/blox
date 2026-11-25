import QtQuick
import QtQuick.Effects
import QtQuick.Window

// Rasterises Phosphor SVGs at the item's native physical pixel size with mipmapped
// layer tinting so small icons stay anti-aliased instead of aliasing on downscale.
Image {
    id: root

    required property string iconName
    property color iconColor: Theme.foreground
    readonly property real deviceScale: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1

    source: iconName === ""
        ? ""
        : Qt.resolvedUrl("../assets/phosphor/" + iconName + ".svg")
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    sourceSize: Qt.size(
        Math.max(1, Math.ceil((width > 0 ? width : 16) * deviceScale)),
        Math.max(1, Math.ceil((height > 0 ? height : 16) * deviceScale))
    )
    layer.enabled: true
    layer.smooth: true
    layer.mipmap: true

    layer.effect: MultiEffect {
        brightness: 1
        colorization: 1
        colorizationColor: root.iconColor
    }
}
