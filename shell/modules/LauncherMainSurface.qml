import qs.shared
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    required property LauncherMainController controller
    property bool open: false
    property var targetScreen

    screen: targetScreen
    visible: open
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    focusable: true
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "blox-launcher-main"
    onOpenChanged: {
        if (open) {
            controller.refresh();
            focusTimer.restart();
        } else {
            controller.query = "";
        }
    }

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    MouseArea {
        anchors.fill: parent
        onClicked: (mouse) => {
            if (mouse.x < card.x || mouse.x > card.x + card.width || mouse.y < card.y || mouse.y > card.y + card.height)
                controller.closeRequested();

        }
    }

    Timer {
        id: focusTimer

        interval: 30
        repeat: false
        onTriggered: search.forceActiveFocus()
    }

    Rectangle {
        id: card

        width: 770
        height: controller.query.startsWith("%") ? 650 : controller.query.length || (controller.dmenuMode && controller.results.length) ? (controller.dmenuMode && controller.dmenuLimit > 0 ? Math.min(520, 78 + controller.dmenuLimit * 58) : 520) : 62
        x: (root.width - width) / 2
        y: controller.dmenuMode && controller.dmenuBottom ? root.height - height - 20 : controller.query.startsWith("%") ? (root.height - height) / 2 : (root.height - 520) / 2
        radius: Theme.scaledRadius(9)
        color: Theme.background
        border.color: Theme.withAlpha(Theme.foreground, 0.2)
        border.width: 1
        clip: true

        MouseArea {
            anchors.fill: parent
        }

        TextInput {
            id: search

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 61
            leftPadding: Theme.scaledSpacing(16)
            rightPadding: Theme.scaledSpacing(16)
            color: Theme.foreground
            selectionColor: Theme.withAlpha(Theme.blue, 0.5)
            selectedTextColor: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 16
            verticalAlignment: TextInput.AlignVCenter
            selectByMouse: true
            clip: true
            activeFocusOnTab: true
            text: controller.query
            onTextEdited: controller.query = text
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Escape) {
                    if (controller.query.startsWith("%"))
                        controller.query = "";
                    else
                        controller.closeRequested();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down) {
                    controller.move(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    controller.move(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    controller.activate();
                    event.accepted = true;
                }
            }
        }

        Text {
            anchors.fill: search
            anchors.leftMargin: search.leftPadding
            anchors.rightMargin: search.rightPadding
            visible: search.text.length === 0
            text: controller.dmenuMode && controller.dmenuPrompt.length ? controller.dmenuPrompt : "Search for anything..."
            color: Theme.withAlpha(Theme.foreground, 0.78)
            font: search.font
            verticalAlignment: Text.AlignVCenter
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: search.bottom
            height: 1
            color: Theme.withAlpha(Theme.foreground, 0.12)
        }

        ListView {
            id: resultList

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: controller.calculation.length ? calculator.bottom : search.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.scaledSpacing(8)
            spacing: Theme.scaledSpacing(3)
            clip: true
            model: controller.results
            visible: !controller.themesLoading && controller.themesError.length === 0
            currentIndex: controller.selectedIndex
            rightMargin: resultScrollbar.policy === ScrollBar.AlwaysOn ? 12 : 0

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: (event) => {
                    const delta = event.pixelDelta.y || event.angleDelta.y / 2;
                    resultList.contentY = Math.max(resultList.originY, Math.min(resultList.originY + resultList.contentHeight - resultList.height, resultList.contentY - delta * 4));
                    event.accepted = true;
                }
            }

            ScrollBar.vertical: ScrollBar {
                id: resultScrollbar

                width: 8
                policy: resultList.contentHeight > resultList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

                background: Rectangle {
                    radius: 999
                    color: Theme.withAlpha(Theme.foreground, 0.04)
                }

                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: 999
                    color: resultScrollbar.hovered ? Theme.foreground : Theme.surfaceAlt
                }

            }

            delegate: Rectangle {
                id: resultCard

                required property var modelData
                required property int index
                readonly property bool themeResult: modelData.kind === "theme"
                readonly property var themeData: themeResult ? modelData.theme : ({
                })
                readonly property color previewBackground: themeResult ? controller.previewColour(themeData, "background", Theme.background) : Theme.surface
                readonly property color previewSurface: themeResult ? controller.previewColour(themeData, "surface", Theme.surface) : Theme.surface
                readonly property color previewSurfaceAlt: themeResult ? controller.previewColour(themeData, "surface_alt", Theme.surfaceAlt) : Theme.surfaceAlt
                readonly property color previewForeground: themeResult ? controller.previewColour(themeData, "foreground", Theme.foreground) : Theme.foreground
                readonly property color previewMuted: themeResult ? controller.previewColour(themeData, "muted", Theme.muted) : Theme.muted
                readonly property color previewAccent: themeResult ? controller.previewColour(themeData, "accent", Theme.blue) : Theme.blue
                readonly property color previewSuccess: themeResult ? controller.previewColour(themeData, "success", Theme.green) : Theme.green
                readonly property color previewWarning: themeResult ? controller.previewColour(themeData, "warning", Theme.yellow) : Theme.yellow
                readonly property string previewFont: themeResult && themeData.preview && themeData.preview.fonts && themeData.preview.fonts.ui ? themeData.preview.fonts.ui : Theme.bodyFontFamily
                readonly property string previewMonoFont: themeResult && themeData.preview && themeData.preview.fonts && themeData.preview.fonts.mono ? themeData.preview.fonts.mono : Theme.fontFamily
                readonly property string previewBarPosition: themeResult ? controller.previewBarPosition(themeData) : "left"
                readonly property bool verticalBar: previewBarPosition === "left" || previewBarPosition === "right"

                width: ListView.view.width - (resultScrollbar.policy === ScrollBar.AlwaysOn ? 12 : 0)
                height: themeResult ? 106 : 55
                radius: Theme.scaledRadius(7)
                color: themeResult ? previewBackground : (!controller.calculationSelected && index === controller.selectedIndex) || resultHover.hovered ? Theme.surfaceAlt : Theme.surface
                border.width: themeResult && index === controller.selectedIndex ? 2 : 1
                border.color: themeResult ? index === controller.selectedIndex || themeData.id === Theme.activeThemeId ? previewAccent : resultHover.hovered ? previewForeground : previewSurfaceAlt : resultHover.hovered ? Theme.withAlpha(Theme.foreground, 0.32) : Theme.border
                clip: true

                Row {
                    visible: !resultCard.themeResult
                    anchors.fill: parent
                    anchors.leftMargin: Theme.scaledSpacing(10)
                    anchors.rightMargin: Theme.scaledSpacing(12)
                    spacing: modelData.kind === "dmenu" ? 0 : Theme.scaledSpacing(12)

                    Item {
                        width: modelData.kind === "dmenu" ? 0 : 34
                        height: parent.height

                        Image {
                            anchors.centerIn: parent
                            width: 30
                            height: 30
                            visible: (modelData.kind === "app" || modelData.kind === "command") && modelData.icon.length > 0
                            source: modelData.icon || ""
                            sourceSize.width: 30
                            sourceSize.height: 30
                            fillMode: Image.PreserveAspectFit
                        }

                        PhosphorIcon {
                            anchors.centerIn: parent
                            width: 22
                            height: 22
                            visible: modelData.kind === "category" || modelData.kind === "theme-action" || ((modelData.kind === "app" || modelData.kind === "command") && modelData.icon.length === 0)
                            iconName: modelData.kind === "category" || modelData.kind === "theme-action" ? modelData.iconName : modelData.kind === "command" ? "terminal-window" : "image-broken"
                            iconColor: Theme.foreground
                        }

                    }

                    Column {
                        width: modelData.kind === "dmenu" ? parent.width : parent.width - 142
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.scaledSpacing(2)

                        Text {
                            width: parent.width
                            text: modelData.title
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 14
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            visible: modelData.subtitle.length > 0
                            text: modelData.subtitle
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }

                    }

                }

                Text {
                    visible: !resultCard.themeResult && modelData.kind !== "dmenu"
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaledSpacing(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.kind === "category" ? "Category" : modelData.kind === "theme-action" ? "Settings" : modelData.kind === "command" ? "Command" : "Application"
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                }

                Rectangle {
                    id: themeThumbnail

                    visible: resultCard.themeResult
                    x: 10
                    y: 9
                    width: 208
                    height: 88
                    radius: Theme.scaledRadius(7)
                    color: resultCard.previewSurface
                    border.color: resultCard.previewSurfaceAlt
                    border.width: 1
                    clip: true

                    Image {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(3)
                        source: resultCard.themeResult && resultCard.themeData.preview ? controller.localFileUrl(resultCard.themeData.preview.wallpaper) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Theme.scaledSpacing(3)
                        color: "#18000000"
                    }

                    Rectangle {
                        id: themeBarPreview

                        x: resultCard.previewBarPosition === "right" ? parent.width - width - 3 : 3
                        y: resultCard.previewBarPosition === "bottom" ? parent.height - height - 3 : 3
                        width: resultCard.verticalBar ? 6 : parent.width - 6
                        height: resultCard.verticalBar ? parent.height - 6 : 6
                        color: resultCard.previewSurface

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.scaledSpacing(2)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: !resultCard.verticalBar

                            Repeater {
                                model: resultCard.themeResult ? controller.previewBarCount(resultCard.themeData, "start") : 0

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: resultCard.previewForeground
                                }

                            }

                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.scaledSpacing(1)
                            visible: !resultCard.verticalBar

                            Repeater {
                                model: resultCard.themeResult ? controller.previewBarCount(resultCard.themeData, "centre") : 0

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: resultCard.previewAccent
                                }

                            }

                        }

                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaledSpacing(2)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: !resultCard.verticalBar

                            Repeater {
                                model: resultCard.themeResult ? controller.previewBarCount(resultCard.themeData, "end") : 0

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: resultCard.previewForeground
                                }

                            }

                        }

                        Column {
                            anchors.top: parent.top
                            anchors.topMargin: Theme.scaledSpacing(2)
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: resultCard.verticalBar

                            Repeater {
                                model: resultCard.themeResult ? controller.previewBarCount(resultCard.themeData, "start") : 0

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: resultCard.previewForeground
                                }

                            }

                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.scaledSpacing(1)
                            visible: resultCard.verticalBar

                            Repeater {
                                model: resultCard.themeResult ? controller.previewBarCount(resultCard.themeData, "centre") : 0

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: resultCard.previewAccent
                                }

                            }

                        }

                        Column {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.scaledSpacing(2)
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.scaledSpacing(1)
                            visible: resultCard.verticalBar

                            Repeater {
                                model: resultCard.themeResult ? controller.previewBarCount(resultCard.themeData, "end") : 0

                                Rectangle {
                                    width: 2
                                    height: 2
                                    radius: Theme.scaledRadius(1)
                                    color: resultCard.previewForeground
                                }

                            }

                        }

                    }

                }

                Text {
                    visible: resultCard.themeResult
                    x: 234
                    y: 14
                    width: 330
                    text: modelData.title
                    color: resultCard.previewForeground
                    font.family: resultCard.previewFont
                    font.pixelSize: 17
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    visible: resultCard.themeResult
                    x: 234
                    y: 43
                    text: modelData.subtitle
                    color: resultCard.previewMuted
                    font.family: resultCard.previewMonoFont
                    font.pixelSize: 11
                }

                Row {
                    visible: resultCard.themeResult
                    x: 234
                    y: 76
                    spacing: Theme.scaledSpacing(5)

                    Repeater {
                        model: [resultCard.previewAccent, resultCard.previewSuccess, resultCard.previewWarning, resultCard.previewForeground]

                        Rectangle {
                            required property color modelData

                            width: 24
                            height: 6
                            radius: Theme.scaledRadius(3)
                            color: modelData
                        }

                    }

                }

                Text {
                    visible: resultCard.themeResult
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaledSpacing(16)
                    y: 18
                    text: resultCard.themeData.id === Theme.activeThemeId ? "✓  Active" : String(resultCard.themeData.variant || "").replace(/^./, (letter) => {
                        return letter.toUpperCase();
                    })
                    color: resultCard.themeData.id === Theme.activeThemeId ? resultCard.previewAccent : resultCard.previewMuted
                    font.family: resultCard.previewFont
                    font.pixelSize: 11
                }

                Text {
                    visible: resultCard.themeResult
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaledSpacing(16)
                    y: 45
                    text: resultCard.previewBarPosition.replace(/^./, (letter) => {
                        return letter.toUpperCase();
                    }) + " bar"
                    color: resultCard.previewMuted
                    font.family: resultCard.previewFont
                    font.pixelSize: 11
                }

                Text {
                    readonly property int widgetCount: controller.previewWidgetCount(resultCard.themeData)

                    visible: resultCard.themeResult
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaledSpacing(16)
                    y: 64
                    text: widgetCount + (widgetCount === 1 ? " widget" : " widgets")
                    color: resultCard.previewMuted
                    font.family: resultCard.previewMonoFont
                    font.pixelSize: 10
                }

                TapHandler {
                    onTapped: {
                        controller.selectedIndex = index;
                        controller.activateResult(index);
                    }
                }

                HoverHandler {
                    id: resultHover

                    cursorShape: Qt.PointingHandCursor
                }

            }

        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: search.bottom
            anchors.margins: Theme.scaledSpacing(28)
            spacing: Theme.scaledSpacing(14)
            visible: controller.query.startsWith("%") && (controller.themesLoading || controller.themesError.length > 0)

            Text {
                text: controller.themesLoading ? "Loading themes" : "Theme switcher"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 22
                font.bold: true
            }

            BusyIndicator {
                visible: controller.themesLoading
                running: visible
            }

            Text {
                width: parent.width
                visible: controller.themesError.length > 0
                text: controller.themesError
                color: Theme.red
                wrapMode: Text.Wrap
                font.family: Theme.bodyFontFamily
                font.pixelSize: 13
            }

            BloxButton {
                visible: controller.themesError.length > 0
                text: "Retry"
                onClicked: controller.loadThemes()
            }

        }

        Column {
            id: calculator

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: search.bottom
            visible: controller.calculation.length > 0
            height: visible ? 132 : 0
            padding: Theme.scaledSpacing(8)
            spacing: Theme.scaledSpacing(7)

            Text {
                text: "Calculator"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
            }

            Rectangle {
                id: calculatorCard

                width: parent.width - 16
                height: 88
                radius: Theme.scaledRadius(8)
                color: controller.calculationSelected || calculatorHover.hovered ? Theme.surfaceAlt : Theme.surface
                border.width: controller.calculationSelected ? 2 : 1
                border.color: controller.calculationSelected ? Theme.accent : calculatorHover.hovered ? Theme.withAlpha(Theme.foreground, 0.32) : Theme.border

                Row {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(16)

                    Column {
                        width: (parent.width - arrow.width) / 2
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: controller.query
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 20
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Question"
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                        }

                    }

                    PhosphorIcon {
                        id: arrow

                        width: 38
                        height: 22
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "arrow-right"
                        iconColor: Theme.foreground
                    }

                    Column {
                        width: (parent.width - arrow.width) / 2
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: controller.calculation
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 20
                            font.bold: true
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Answer"
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                        }

                    }

                }

                TapHandler {
                    onTapped: {
                        controller.calculationSelected = true;
                        controller.activateCalculation();
                    }
                }

                HoverHandler {
                    id: calculatorHover

                    cursorShape: Qt.PointingHandCursor
                }

            }

        }

    }

}
