import "../shared"
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PanelWindow {
    id: root

    required property bool guideOpen
    required property bool interactive
    required property bool rendered
    property var captureSource: null
    property var captureMonitor: null
    property var captureWorkspace: null
    property string wallpaperSource: ""
    property string wallpaperFit: "cover"
    readonly property real contentScale: Math.min(1.08, Math.min(width / 1840, height / 1000))
    readonly property real keySize: 48

    signal closeRequested()

    function iconForKey(key) {
        if (key === "Shift")
            return "arrow-fat-up";

        if (key === "Scroll")
            return "mouse-scroll";

        return "";
    }

    function barHasClock() {
        for (const item of Theme.barItems) {
            if (item.id === "clock")
                return item.enabled && item.region !== "hidden";

        }
        return false;
    }

    visible: rendered
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    focusable: false
    aboveWindows: true
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "blox-shortcut-guide"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    Rectangle {
        id: backdrop

        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.9)
        opacity: root.guideOpen ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: root.guideOpen ? 300 : 180
                easing.type: Easing.Linear
            }

        }

    }

    Item {
        anchors.fill: parent

        Item {
            id: content

            width: 1760
            height: 920
            anchors.centerIn: parent
            scale: root.contentScale
            transformOrigin: Item.Center
            opacity: root.guideOpen ? 1 : 0
            y: (parent.height - height) / 2 + (root.guideOpen ? 0 : 70)

            Column {
                width: 600
                height: parent.height
                spacing: Theme.scaledSpacing(24)

                Rectangle {
                    id: previewFrame

                    width: parent.width
                    height: root.captureMonitor && root.captureMonitor.width > 0 ? Math.round(width * root.captureMonitor.height / root.captureMonitor.width) : 338
                    radius: Theme.scaledRadius(0)
                    color: Theme.background
                    opacity: 1
                    clip: true

                    Loader {
                        anchors.fill: parent
                        active: root.rendered && root.captureSource !== null

                        sourceComponent: ScreencopyView {
                            captureSource: root.captureSource
                            live: false
                            paintCursor: false
                            opacity: hasContent ? 1 : 0
                        }

                    }

                    Item {
                        id: liveWorkspace

                        anchors.fill: parent
                        visible: root.captureMonitor !== null && root.captureWorkspace !== null

                        Repeater {
                            model: root.captureWorkspace ? root.captureWorkspace.toplevels : []

                            Item {
                                id: liveToplevel

                                required property var modelData
                                readonly property var ipc: modelData.lastIpcObject || ({
                                })
                                readonly property var position: ipc.at || [0, 0]
                                readonly property var dimensions: ipc.size || [0, 0]
                                readonly property real monitorWidth: root.captureMonitor ? root.captureMonitor.width : 1
                                readonly property real monitorHeight: root.captureMonitor ? root.captureMonitor.height : 1
                                readonly property real monitorX: root.captureMonitor ? root.captureMonitor.x : 0
                                readonly property real monitorY: root.captureMonitor ? root.captureMonitor.y : 0

                                x: (Number(position[0] || 0) - monitorX) * liveWorkspace.width / monitorWidth
                                y: (Number(position[1] || 0) - monitorY) * liveWorkspace.height / monitorHeight
                                width: Number(dimensions[0] || 0) * liveWorkspace.width / monitorWidth
                                height: Number(dimensions[1] || 0) * liveWorkspace.height / monitorHeight
                                visible: modelData.wayland !== null && ipc.mapped !== false && ipc.hidden !== true && width > 0 && height > 0
                                clip: true

                                Rectangle {
                                    anchors.fill: parent
                                    color: Theme.background
                                }

                                Image {
                                    x: -liveToplevel.x
                                    y: -liveToplevel.y
                                    width: liveWorkspace.width
                                    height: liveWorkspace.height
                                    source: root.wallpaperSource
                                    fillMode: root.wallpaperFit === "contain" ? Image.PreserveAspectFit : root.wallpaperFit === "tile" ? Image.Tile : Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: true
                                }

                                ScreencopyView {
                                    id: capturedToplevel

                                    anchors.fill: parent
                                    captureSource: liveToplevel.modelData.wayland
                                    live: true
                                    paintCursor: false
                                    opacity: hasContent ? 1 : 0
                                }

                                ShaderEffectSource {
                                    id: capturedToplevelTexture

                                    anchors.fill: parent
                                    sourceItem: capturedToplevel
                                    hideSource: true
                                    live: true
                                    textureSize: Qt.size(Math.max(1, Number(liveToplevel.dimensions[0] || 0)), Math.max(1, Number(liveToplevel.dimensions[1] || 0)))
                                    mipmap: true
                                }

                                ShaderEffect {
                                    property ShaderEffectSource source: capturedToplevelTexture

                                    anchors.fill: parent
                                    // Discard the compositor-baked backdrop from translucent window captures.
                                    fragmentShader: "../assets/shaders/window-content.frag.qsb"
                                }

                            }

                        }

                    }

                    Rectangle {
                        id: liveBarClock

                        readonly property bool horizontal: Theme.barPosition === "top" || Theme.barPosition === "bottom"
                        readonly property real screenScaleX: previewFrame.width / (root.captureMonitor ? root.captureMonitor.width : 1920)
                        readonly property real screenScaleY: previewFrame.height / (root.captureMonitor ? root.captureMonitor.height : 1080)

                        width: horizontal ? 132 * screenScaleX : Theme.railWidth * screenScaleX
                        height: horizontal ? Theme.railWidth * screenScaleY : 88 * screenScaleY
                        x: horizontal ? (parent.width - width) / 2 : Theme.barPosition === "right" ? parent.width - width : 0
                        y: horizontal ? Theme.barPosition === "bottom" ? parent.height - height : 0 : (parent.height - height) / 2
                        visible: root.barHasClock()
                        color: Theme.background

                        Text {
                            anchors.centerIn: parent
                            text: liveBarClock.horizontal ? Qt.formatTime(previewClock.date, "hh:mm:ss AP") : Qt.formatTime(previewClock.date, "hh\nmm\nss")
                            color: Theme.blue
                            font.family: Theme.fontFamily
                            font.pixelSize: liveBarClock.horizontal ? 14 : 16
                            scale: Math.min(liveBarClock.screenScaleX, liveBarClock.screenScaleY)
                            horizontalAlignment: Text.AlignHCenter
                        }

                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.scaledSpacing(32)

                    Column {
                        width: 316
                        spacing: Theme.scaledSpacing(14)

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Window controls"
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 29
                            font.weight: Font.Medium
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.scaledSpacing(16)

                            Column {
                                spacing: Theme.scaledSpacing(8)

                                Item {
                                    width: 184
                                    height: 120

                                    KeyCap {
                                        x: 64
                                        y: 0
                                        iconName: "arrow-up"
                                    }

                                    KeyCap {
                                        x: 0
                                        y: 64
                                        iconName: "arrow-left"
                                    }

                                    KeyCap {
                                        x: 64
                                        y: 64
                                        iconName: "arrow-down"
                                    }

                                    KeyCap {
                                        x: 128
                                        y: 64
                                        iconName: "arrow-right"
                                    }

                                }

                                Text {
                                    width: 184
                                    text: "Focus direction"
                                    color: Theme.foreground
                                    horizontalAlignment: Text.AlignHCenter
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 20
                                }

                            }

                        }

                        Column {
                            id: moveWindowShortcuts

                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.scaledSpacing(6)

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: Theme.scaledSpacing(9)

                                Item {
                                    width: root.keySize
                                    height: 118

                                    KeyCap {
                                        anchors.centerIn: parent
                                        iconName: "arrow-fat-up"
                                    }

                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "+"
                                    color: Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 18
                                }

                                Item {
                                    width: 182
                                    height: 118

                                    KeyCap {
                                        x: 64
                                        iconName: "arrow-up"
                                    }

                                    KeyCap {
                                        x: 0
                                        y: 64
                                        iconName: "arrow-left"
                                    }

                                    KeyCap {
                                        x: 64
                                        y: 64
                                        iconName: "arrow-down"
                                    }

                                    KeyCap {
                                        x: 128
                                        y: 64
                                        iconName: "arrow-right"
                                    }

                                }

                            }

                            PointerShortcutKeys {
                                iconName: "mouse-left-click"
                            }

                            Text {
                                width: parent.width
                                text: "Move window"
                                color: Theme.foreground
                                font.family: Theme.bodyFontFamily
                                font.pixelSize: 20
                                horizontalAlignment: Text.AlignHCenter
                            }

                        }

                        IconShortcutRow {
                            x: moveWindowShortcuts.x
                            iconName: "mouse-right-click"
                            action: "Resize window"
                        }

                    }

                    Column {
                        width: 252
                        spacing: Theme.scaledSpacing(14)

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Numpad"
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 29
                            font.weight: Font.Medium
                        }

                        Grid {
                            id: numpadGrid

                            anchors.horizontalCenter: parent.horizontalCenter
                            columns: 3
                            spacing: Theme.scaledSpacing(8)

                            Repeater {
                                model: [{
                                    "key": "7",
                                    "icon": "picture-in-picture"
                                }, {
                                    "key": "8",
                                    "icon": "frame-corners"
                                }, {
                                    "key": "9",
                                    "icon": "corners-out"
                                }, {
                                    "key": "4",
                                    "icon": "arrows-out-line-horizontal"
                                }, {
                                    "key": "5",
                                    "icon": "swap"
                                }, {
                                    "key": "6",
                                    "icon": "arrows-in-line-horizontal"
                                }, {
                                    "key": "1",
                                    "icon": "sidebar-simple"
                                }, {
                                    "key": "2",
                                    "icon": "square-split-horizontal"
                                }, {
                                    "key": "3",
                                    "icon": "sidebar-simple",
                                    "mirrored": true
                                }]

                                NumpadKey {
                                    required property var modelData

                                    width: root.keySize
                                    height: root.keySize
                                    keyLabel: modelData.key
                                    iconName: modelData.icon
                                    mirroredIcon: modelData.mirrored ?? false
                                }

                            }

                        }

                        Item {
                            width: numpadGrid.width
                            height: root.keySize
                            anchors.horizontalCenter: parent.horizontalCenter

                            NumpadKey {
                                width: root.keySize
                                height: root.keySize
                                keyLabel: "0"
                                iconName: "push-pin"
                            }

                        }

                    }

                }

            }

            Row {
                x: 660
                width: 1100
                height: parent.height
                spacing: Theme.scaledSpacing(56)

                // Explicit mirror of the Super binds in hypr/conf.d/binds.lua.
                Column {
                    width: 500
                    spacing: Theme.scaledSpacing(26)

                    ShortcutGroup {
                        width: parent.width
                        heading: "Apps & shell"
                        shortcuts: [{
                            "keys": ["T"],
                            "action": "Terminal"
                        }, {
                            "keys": ["E"],
                            "action": "Files"
                        }, {
                            "keys": ["M"],
                            "action": "Micro"
                        }, {
                            "keys": ["Space"],
                            "action": "Launcher"
                        }, {
                            "keys": ["N"],
                            "action": "Notifications"
                        }, {
                            "keys": ["Shift", "O"],
                            "action": "Orca"
                        }]
                    }

                    ShortcutGroup {
                        width: parent.width
                        heading: "Session & shell"
                        shortcuts: [{
                            "keys": ["Q"],
                            "action": "Close window"
                        }, {
                            "keys": ["L"],
                            "action": "Lock"
                        }, {
                            "keys": ["\\"],
                            "action": "Toggle bar"
                        }, {
                            "keys": ["."],
                            "action": "Emoji picker"
                        }, {
                            "keys": ["Shift", "/"],
                            "action": "Toggle shortcut guide"
                        }]
                    }

                }

                Column {
                    width: 544
                    spacing: Theme.scaledSpacing(26)

                    ShortcutGroup {
                        width: parent.width
                        heading: "Capture & tools"
                        shortcuts: [{
                            "keys": ["Shift", "S"],
                            "action": "Capture region"
                        }, {
                            "keys": ["Alt", "S"],
                            "action": "Capture frozen region"
                        }, {
                            "keys": ["Shift", "T"],
                            "action": "Copy text from region"
                        }, {
                            "keys": ["Shift", "C"],
                            "action": "Colour picker"
                        }, {
                            "keys": ["V"],
                            "action": "Clipboard history"
                        }]
                    }

                    ShortcutGroup {
                        width: parent.width
                        heading: "Workspaces"
                        shortcuts: [{
                            "keys": ["1–0"],
                            "action": "Switch to 1–10"
                        }, {
                            "keys": ["Shift", "1–0"],
                            "action": "Move window to 1–10"
                        }, {
                            "keys": ["F1–F12"],
                            "action": "Switch to 11–22"
                        }, {
                            "keys": ["Shift", "F1–F12"],
                            "action": "Move window to 11–22"
                        }, {
                            "keys": ["Tab"],
                            "action": "Next workspace"
                        }, {
                            "keys": ["Shift", "Tab"],
                            "action": "Previous workspace"
                        }, {
                            "keys": ["`"],
                            "action": "Magic workspace"
                        }, {
                            "keys": ["Shift", "`"],
                            "action": "Move to magic workspace"
                        }, {
                            "keys": ["Scroll"],
                            "action": "Cycle workspaces"
                        }]
                    }

                }

            }

            Behavior on opacity {
                NumberAnimation {
                    duration: root.guideOpen ? 300 : 180
                    easing.type: root.guideOpen ? Easing.OutExpo : Easing.InCubic
                }

            }

            Behavior on y {
                NumberAnimation {
                    duration: root.guideOpen ? 300 : 180
                    easing.type: root.guideOpen ? Easing.OutExpo : Easing.InCubic
                }

            }

        }

    }

    SystemClock {
        id: previewClock

        precision: SystemClock.Seconds
    }

    MouseArea {
        id: clickCatcher

        anchors.fill: parent
        enabled: root.interactive
        onClicked: root.closeRequested()
    }

    mask: Region {
        width: root.interactive ? root.width : 0
        height: root.interactive ? root.height : 0
    }

    component KeyCap: Rectangle {
        id: keyCap

        property string label: ""
        property string iconName: ""
        property bool mirroredIcon: false
        property real widthUnits: 1

        implicitWidth: root.keySize * widthUnits
        implicitHeight: root.keySize
        radius: Theme.scaledRadius(4)
        color: Theme.accent

        Text {
            visible: keyCap.iconName === ""
            anchors.centerIn: parent
            text: keyCap.label
            color: Theme.selectionForeground
            font.family: Theme.monoFontFamily
            font.pixelSize: keyCap.label.length > 5 ? 11 : keyCap.label.length > 3 ? 14 : 20
            font.weight: Font.DemiBold
        }

        PhosphorIcon {
            visible: keyCap.iconName !== ""
            anchors.centerIn: parent
            width: 28
            height: 28
            iconName: keyCap.iconName
            mirroredIcon: keyCap.mirroredIcon
        }

    }

    component ShortcutRow: Row {
        id: shortcutRow

        required property var keys
        required property string action
        property real actionWidth: 280

        spacing: Theme.scaledSpacing(10)
        height: root.keySize

        Row {
            id: keySequence

            spacing: Theme.scaledSpacing(8)

            Repeater {
                model: shortcutRow.keys

                Row {
                    required property int index
                    required property string modelData

                    spacing: Theme.scaledSpacing(8)

                    Text {
                        visible: index > 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: "+"
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 18
                    }

                    KeyCap {
                        label: modelData
                        iconName: root.iconForKey(modelData)
                        widthUnits: modelData === "Space" ? 2 : 1
                    }

                }

            }

        }

        Text {
            width: shortcutRow.actionWidth
            anchors.verticalCenter: keySequence.verticalCenter
            text: shortcutRow.action
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 20
            wrapMode: Text.Wrap
        }

    }

    component ShortcutGroup: Column {
        id: shortcutGroup

        required property string heading
        required property var shortcuts
        property real actionWidth: 290

        spacing: Theme.scaledSpacing(4)

        Text {
            text: shortcutGroup.heading
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 29
            font.weight: Font.Medium
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.withAlpha(Theme.foreground, 0.18)
        }

        Repeater {
            model: shortcutGroup.shortcuts

            ShortcutRow {
                required property var modelData

                keys: modelData.keys
                action: modelData.action
                actionWidth: shortcutGroup.actionWidth
            }

        }

    }

    component NumpadKey: Item {
        id: numpadKey

        required property string keyLabel
        required property string iconName
        property bool mirroredIcon: false

        KeyCap {
            anchors.horizontalCenter: parent.horizontalCenter
            iconName: numpadKey.iconName
            mirroredIcon: numpadKey.mirroredIcon

            Text {
                x: 4
                y: 1
                text: numpadKey.keyLabel
                color: Theme.selectionForeground
                font.family: Theme.monoFontFamily
                font.pixelSize: 11
                font.weight: Font.Bold
            }

        }

    }

    component PointerShortcutKeys: Row {
        id: pointerShortcut

        required property string iconName

        spacing: Theme.scaledSpacing(10)
        height: root.keySize

        KeyCap {
            iconName: pointerShortcut.iconName
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "+"
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 18
        }

        KeyCap {
            iconName: "cursor"
        }

    }

    component IconShortcutRow: Row {
        id: iconShortcut

        required property string iconName
        required property string action

        spacing: Theme.scaledSpacing(10)
        height: root.keySize

        PointerShortcutKeys {
            iconName: iconShortcut.iconName
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: iconShortcut.action
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 20
        }

    }

    component PhosphorIcon: Image {
        required property string iconName
        property bool mirroredIcon: false

        source: iconName === "" ? "" : "../assets/phosphor/" + iconName + ".svg"
        fillMode: Image.PreserveAspectFit
        mirror: mirroredIcon
        smooth: true
        mipmap: true
        layer.enabled: true

        layer.effect: MultiEffect {
            brightness: 1
            colorization: 1
            colorizationColor: Theme.selectionForeground
        }

    }

}
