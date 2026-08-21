import QtQuick
import QtQuick.Effects

Image {
    required property string iconName
    property color iconColor: Theme.foreground

    source: iconName === "" ? "" : "../assets/phosphor/" + iconName + ".svg"
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    sourceSize: Qt.size(128, 128)
    layer.enabled: true
    layer.smooth: true
    layer.textureSize: Qt.size(Math.max(64, width * 4), Math.max(64, height * 4))

    layer.effect: MultiEffect {
        brightness: 1
        colorization: 1
        colorizationColor: iconColor
    }

}
