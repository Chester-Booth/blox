import QtQuick
import QtQuick.Window
import QtQuick.Effects
import qs.shared
import Blox.Services 1.0

// Small bar and wallpaper preview shared by the selected-theme card and shelf cards.
Rectangle {
    id: root

    property string wallpaper: ""
    property var palette: []
    property var preview: null
    property string barPosition: "top"
    property var barCounts: [3, 2, 3]

    readonly property color previewSurface: preview && preview.surface ? preview.surface : palette.length > 0 ? palette[0] : Theme.surface
    readonly property color previewSurfaceAlt: preview && preview.surfaceAlt ? preview.surfaceAlt : palette.length > 0 ? palette[0] : Theme.surfaceAlt
    readonly property color previewForeground: preview && preview.foreground ? preview.foreground : palette.length > 3 ? palette[3] : Theme.foreground
    readonly property color previewAccent: preview && preview.accent ? preview.accent : palette.length > 1 ? palette[1] : Theme.blue
    readonly property bool verticalBar: barPosition === "left" || barPosition === "right"

    radius: Theme.scaledRadius(7)
    color: previewSurface
    border.color: previewSurfaceAlt
    clip: true

    ImageCacheResolver {
        id: imageCache
        source: root.wallpaper
        pixelWidth: Math.max(1, Math.ceil(wallpaperImage.width * Screen.devicePixelRatio))
        pixelHeight: Math.max(1, Math.ceil(wallpaperImage.height * Screen.devicePixelRatio))
        fit: "cover"
        active: root.visible && wallpaperImage.width > 0 && wallpaperImage.height > 0
    }

    Image {
        id: wallpaperImage
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(3)
        source: imageCache.status === "ready" ? imageCache.readySource : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(Math.max(1, Math.ceil(width * Screen.devicePixelRatio)),
            Math.max(1, Math.ceil(height * Screen.devicePixelRatio)))
        visible: source.toString().length > 0
        smooth: true
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: wallpaperMask
        }
    }
    Rectangle {
        id: wallpaperMask
        anchors.fill: wallpaperImage
        radius: Math.max(0, root.radius - Theme.scaledSpacing(3))
        color: "white"
        visible: false
        layer.enabled: true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(3)
        radius: Theme.scaledRadius(5)
        color: Theme.withAlpha("black", 24 / 255)
    }

    Rectangle {
        x: root.barPosition === "right" ? parent.width - width - 3 : 3
        y: root.barPosition === "bottom" ? parent.height - height - 3 : 3
        width: root.verticalBar ? 5 : parent.width - 6
        height: root.verticalBar ? parent.height - 6 : 5
        color: root.previewSurface

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.scaledSpacing(2)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaledSpacing(1)
            visible: !root.verticalBar
            Repeater {
                model: root.barCounts[0]
                Rectangle { width: 2; height: 2; radius: Theme.scaledRadius(1); color: root.previewForeground }
            }
        }

        Row {
            anchors.centerIn: parent
            spacing: Theme.scaledSpacing(1)
            visible: !root.verticalBar
            Repeater {
                model: root.barCounts[1]
                Rectangle { width: 2; height: 2; radius: Theme.scaledRadius(1); color: root.previewAccent }
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaledSpacing(2)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaledSpacing(1)
            visible: !root.verticalBar
            Repeater {
                model: root.barCounts[2]
                Rectangle { width: 2; height: 2; radius: Theme.scaledRadius(1); color: root.previewForeground }
            }
        }

        Column {
            anchors.top: parent.top
            anchors.topMargin: Theme.scaledSpacing(2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaledSpacing(1)
            visible: root.verticalBar
            Repeater {
                model: root.barCounts[0]
                Rectangle { width: 2; height: 2; radius: Theme.scaledRadius(1); color: root.previewForeground }
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: Theme.scaledSpacing(1)
            visible: root.verticalBar
            Repeater {
                model: root.barCounts[1]
                Rectangle { width: 2; height: 2; radius: Theme.scaledRadius(1); color: root.previewAccent }
            }
        }

        Column {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.scaledSpacing(2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaledSpacing(1)
            visible: root.verticalBar
            Repeater {
                model: root.barCounts[2]
                Rectangle { width: 2; height: 2; radius: Theme.scaledRadius(1); color: root.previewForeground }
            }
        }
    }
}
