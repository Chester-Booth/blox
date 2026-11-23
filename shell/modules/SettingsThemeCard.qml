import QtQuick
import qs.shared

Rectangle {
    id: root
    objectName: "theme-card-" + cardId

    required property var themeData
    property bool compact: false
    property bool readOnly: false
    property bool active: false
    property bool selected: false
    property bool toggleOpen: false
    property bool menuOpen: false
    property Item pointerCoordinateItem: null
    property var globalPointer: ({x: -1, y: -1, occluded: false})
    property bool cardHovered: false
    property bool actionHovered: false

    readonly property string cardId: themeData ? String(themeData.id || "") : ""
    readonly property string name: themeData ? String(themeData.name || cardId) : ""
    readonly property string meta: themeData ? String(themeData.meta || "") : ""
    readonly property var palette: themeData && Array.isArray(themeData.palette) ? themeData.palette : []
    readonly property var preview: themeData ? themeData.preview : null
    readonly property color previewBackground: preview && preview.background ? preview.background : Theme.background
    readonly property color previewSurface: preview && preview.surface ? preview.surface : Theme.surface
    readonly property color previewForeground: preview && preview.foreground ? preview.foreground : Theme.foreground
    readonly property color previewMuted: preview && preview.muted ? preview.muted : Theme.muted
    readonly property color previewAccent: preview && preview.accent ? preview.accent : Theme.blue
    readonly property string previewFont: themeData && themeData.previewFont ? themeData.previewFont : Theme.bodyFontFamily
    readonly property string barPosition: themeData && themeData.barPosition ? themeData.barPosition : "top"
    readonly property var barCounts: themeData && Array.isArray(themeData.barCounts) ? themeData.barCounts : [3, 2, 3]
    readonly property Item actionItem: themeActionButton
    readonly property bool verticalBar: barPosition === "left" || barPosition === "right"
    readonly property real normalWrapWidth: Math.max(titleMetrics.advanceWidth * 0.65, longestWordMetrics.advanceWidth)
    readonly property real previewWidth: Math.max(width * 0.3, Math.min(width * 0.5, width - 59 - normalWrapWidth))
    readonly property bool previewAtMinimum: previewWidth <= width * 0.3 + 0.5
    readonly property bool builtIn: cardId === "blox-panel" || meta.toLowerCase().indexOf("built in") >= 0
    readonly property bool pointerPolling: pointerCoordinateItem !== null
        && Number(globalPointer.x) >= 0 && Number(globalPointer.y) >= 0

    onGlobalPointerChanged: {
        if (pointerPolling)
            syncGlobalPointer();
        else {
            cardHovered = false;
            actionHovered = false;
        }
    }
    onPointerCoordinateItemChanged: {
        if (pointerPolling)
            syncGlobalPointer();
    }
    onMenuOpenChanged: actionHovered = false

    signal chosen(string themeId)
    signal toggleRequested()
    signal contextMenuRequested(Item anchor, bool keyboardOpened)
    signal menuDismissRequested()

    implicitHeight: 82
    radius: Theme.scaledRadius(10)
    color: selected ? previewSurface : cardHovered ? Qt.lighter(previewBackground, 1.13) : previewBackground
    border.color: activeFocus || active || selected ? previewAccent : cardHovered ? previewForeground : Theme.surfaceAlt
    border.width: activeFocus || selected || compact ? 2 : 1
    activeFocusOnTab: !compact && !readOnly
    clip: false

    TextMetrics {
        id: titleMetrics
        font.family: root.previewFont
        font.pixelSize: 17
        font.bold: true
        text: root.name
    }

    TextMetrics {
        id: longestWordMetrics
        font.family: root.previewFont
        font.pixelSize: 17
        font.bold: true
        text: root.longestWord(root.name)
    }

    Item {
        id: normalContent
        anchors.fill: parent

        SettingsThemePreview {
            id: themeThumbnail
            x: 8
            y: 8
            width: root.previewWidth
            height: root.height - 16
            wallpaper: root.themeData ? String(root.themeData.wallpaper || "") : ""
            palette: root.palette
            preview: root.preview
            barPosition: root.barPosition
            barCounts: root.barCounts
        }

        Item {
            id: themeIdentity
            x: themeThumbnail.x + themeThumbnail.width + 10
            y: 7
            width: root.width - x - 8
            height: root.height - 14

            Row {
                id: themePalette
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                spacing: Math.min(Theme.scaledSpacing(5), Math.max(Theme.scaledSpacing(1), themeIdentity.width / 24))
                Repeater {
                    model: root.palette.slice(0, 4)
                    Rectangle {
                        required property var modelData
                        width: Math.max(0, Math.min(24, (themeIdentity.width - 3 * themePalette.spacing) / 4))
                        height: 6
                        radius: Theme.scaledRadius(3)
                        color: modelData
                    }
                }
            }

            Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.rightMargin: themeActionButton.width + Theme.scaledSpacing(3)
                anchors.bottom: themePalette.top
                anchors.bottomMargin: Theme.scaledSpacing(4)
                height: Math.max(0, themeIdentity.height - themePalette.height - Theme.scaledSpacing(4))
                text: root.name
                color: root.previewForeground
                font.family: root.previewFont
                font.pixelSize: 17
                font.bold: true
                fontSizeMode: Text.Fit
                minimumPixelSize: 11
                horizontalAlignment: Text.AlignLeft
                verticalAlignment: Text.AlignBottom
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                clip: true
            }
        }

        Rectangle {
            id: themeActionButton
            visible: !root.readOnly
            objectName: "theme-action-" + root.cardId
            z: 2
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaledSpacing(7)
            anchors.verticalCenter: parent.verticalCenter
            width: 30
            height: 34
            radius: Theme.scaledRadius(8)
            color: root.actionHovered || root.menuOpen || activeFocus ? Theme.withAlpha(root.previewAccent, 0.32) : "transparent"
            border.color: activeFocus ? root.previewAccent : root.compact ? Theme.border : "transparent"
            border.width: activeFocus ? 2 : root.compact ? 1 : 0
            activeFocusOnTab: true
            Keys.onReturnPressed: root.activateAction(false)
            Keys.onSpacePressed: root.activateAction(false)
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) {
                    root.activateAction(true);
                    event.accepted = true;
                }
            }

            PhosphorIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                iconName: root.compact ? (root.toggleOpen ? "caret-up" : "caret-down") : "dots-three"
                iconColor: root.actionHovered || root.menuOpen ? root.previewForeground : root.previewMuted
            }
        }
    }

    MouseArea {
        id: cardPointer
        anchors.fill: parent
        z: 3
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        preventStealing: true
        onEntered: {
            if (root.pointerPolling)
                return;
            root.cardHovered = true;
            root.actionHovered = root.isOverAction(mouseX, mouseY);
        }
        onExited: {
            if (root.pointerPolling)
                return;
            root.cardHovered = false;
            root.actionHovered = false;
        }
        onPositionChanged: mouse => {
            if (!root.pointerPolling)
                root.actionHovered = root.isOverAction(mouse.x, mouse.y);
        }
        onClicked: mouse => {
            const overAction = root.isOverAction(mouse.x, mouse.y);
            if (root.compact) {
                if (overAction)
                    root.toggleRequested();
                else
                    root.chosen(root.cardId);
            } else if (overAction || mouse.button === Qt.RightButton) {
                if (root.menuOpen)
                    root.menuDismissRequested();
                else
                    root.contextMenuRequested(themeActionButton, false);
            } else if (root.menuOpen) {
                root.menuDismissRequested();
            } else {
                root.chosen(root.cardId);
            }
        }
    }

    Keys.onReturnPressed: {
        if (!compact)
            root.chosen(root.cardId);
    }
    Keys.onSpacePressed: {
        if (!compact)
            root.chosen(root.cardId);
    }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) {
            root.contextMenuRequested(themeActionButton, true);
            event.accepted = true;
        }
    }

    function isOverAction(x, y) {
        return x >= themeActionButton.x - 6 && x <= themeActionButton.x + themeActionButton.width + 6
            && y >= themeActionButton.y - 4 && y <= themeActionButton.y + themeActionButton.height + 4;
    }

    function focusAction() {
        themeActionButton.forceActiveFocus();
    }

    function syncGlobalPointer() {
        if (!pointerPolling) {
            cardHovered = false;
            actionHovered = false;
            return;
        }
        const local = mapFromItem(pointerCoordinateItem, Number(globalPointer.x), Number(globalPointer.y));
        const inside = !globalPointer.occluded && local.x >= 0 && local.x <= width
            && local.y >= 0 && local.y <= height;
        cardHovered = inside;
        actionHovered = inside && isOverAction(local.x, local.y) && !menuOpen;
    }

    function activateAction(keyboardOpened) {
        if (compact)
            toggleRequested();
        else if (menuOpen)
            menuDismissRequested();
        else
            contextMenuRequested(themeActionButton, keyboardOpened);
    }

    function longestWord(value) {
        const words = String(value || "").split(" ");
        let longest = "";
        for (let i = 0; i < words.length; i++) {
            if (words[i].length > longest.length)
                longest = words[i];
        }
        return longest;
    }
}
