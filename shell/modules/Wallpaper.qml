import "../shared"
import QtQuick
import Quickshell
import Quickshell.Wayland

// Owns one click-through, double-buffered wallpaper surface per output.
Scope {
    id: root

    function fillMode(fit) {
        if (fit === "contain")
            return Image.PreserveAspectFit;

        if (fit === "tile")
            return Image.Tile;

        return Image.PreserveAspectCrop;
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: wallpaperWindow

            required property var modelData
            property bool frontIsFirst: true
            readonly property real outputScale: modelData ? modelData.devicePixelRatio : 1
            readonly property url requestedSource: Theme.wallpaperSource || ""

            function showWhenReady(image) {
                if (image.status !== Image.Ready || String(image.source) !== String(requestedSource))
                    return ;

                frontIsFirst = image === firstImage;
                firstImage.opacity = frontIsFirst ? 1 : 0;
                secondImage.opacity = frontIsFirst ? 0 : 1;
            }

            function loadWallpaper() {
                if (!requestedSource)
                    return ;

                const front = frontIsFirst ? firstImage : secondImage;
                const back = frontIsFirst ? secondImage : firstImage;
                if (String(front.source) === String(requestedSource) && front.status === Image.Ready)
                    return ;

                if (String(back.source) === String(requestedSource)) {
                    showWhenReady(back);
                    return ;
                }
                back.source = "";
                Qt.callLater(() => {
                    back.source = wallpaperWindow.requestedSource;
                });
            }

            screen: modelData
            color: Theme.background
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "blox-wallpaper-" + modelData.name
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            onRequestedSourceChanged: loadWallpaper()
            Component.onCompleted: loadWallpaper()

            anchors {
                top: true
                right: true
                bottom: true
                left: true
            }

            Image {
                id: firstImage

                anchors.fill: parent
                asynchronous: true
                cache: true
                fillMode: root.fillMode(Theme.wallpaperFit)
                mipmap: wallpaperWindow.outputScale <= 1
                smooth: true
                opacity: 0
                onStatusChanged: wallpaperWindow.showWhenReady(firstImage)
            }

            Image {
                id: secondImage

                anchors.fill: parent
                asynchronous: true
                cache: true
                fillMode: root.fillMode(Theme.wallpaperFit)
                mipmap: wallpaperWindow.outputScale <= 1
                smooth: true
                opacity: 0
                onStatusChanged: wallpaperWindow.showWhenReady(secondImage)
            }

            // A zero-sized mask lets desktop and compositor input pass through.
            mask: Region {
            }

        }

    }

}
