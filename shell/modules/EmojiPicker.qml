import qs.shared
import QtQuick
import QtQuick.Controls
import Quickshell

FloatingWindow {
    id: root

    required property EmojiController controller
    required property bool positionReady
    property bool open: false
    property var targetScreen
    property bool suppressEmojiActivation: false
    property int activeEmojiPopups: 0
    property int contextItemIndex: -1
    property point contextAnchor: Qt.point(0, 0)
    property Item hoveredCell: null
    property var hoveredItem: null
    readonly property var contextItem: contextItemIndex >= 0 ? controller.itemAt(contextItemIndex) : null
    readonly property var categoryIcons: ["magnifying-glass", "clock-counter-clockwise", "smiley", "person-simple", "paw-print", "hamburger", "soccer-ball", "airplane", "lamp", "flag", "shapes", "code"]
    readonly property var toneColours: ["#ffdc5d", "#f7dece", "#e0bb95", "#c58c6b", "#a56b46", "#6f432a"]
    readonly property var symbolSections: controller.symbolSections
    property string activeNerdFontSection: "files"
    property string activeSymbolSection: "emoji"

    function popupOpened() {
        activeEmojiPopups++;
        toneGuard.stop();
        suppressEmojiActivation = true;
    }

    function popupClosed() {
        activeEmojiPopups = Math.max(0, activeEmojiPopups - 1);
        if (activeEmojiPopups === 0)
            toneGuard.restart();
    }

    function prepareEmojiContext(itemIndex, item) {
        contextItemIndex = itemIndex;
        contextAnchor = item.mapToItem(root.contentItem, item.width, item.height);
        controller.selectedIndex = itemIndex;
    }

    function syncGridColumns() {
        const cols = Math.max(1, Math.floor((emojiGrid.width - emojiGrid.rightMargin) / emojiGrid.cellWidth));
        controller.setGridColumns(cols);
    }

    function jumpToSection(key, isNerdFonts) {
        const index = controller.gridHeadingRow(key);
        if (index < 0) return;
        if (isNerdFonts) activeNerdFontSection = key;
        else activeSymbolSection = key;
        emojiGrid.positionViewAtIndex(index, GridView.Beginning);
        emojiGrid.forceActiveFocus();
    }

    function updateActiveSymbolSection() {
        if (!controller.sectionedBrowse)
            return;
        const columns = Math.max(1, Math.floor((emojiGrid.width - emojiGrid.rightMargin) / emojiGrid.cellWidth));
        const firstIndex = Math.max(0, Math.floor(emojiGrid.contentY / emojiGrid.cellHeight) * columns);
        const fallback = controller.category === "Symbols" ? "emoji" : activeNerdFontSection;
        const active = controller.activeSectionForRow(firstIndex, fallback);
        if (controller.category === "Symbols") activeSymbolSection = active;
        else activeNerdFontSection = active;
    }

    function nerdFontSourceTitle() {
        for (const source of controller.nerdFontSources) {
            if (source.key === controller.nerdFontSource)
                return source.title;
        }
        return "All sources";
    }

    screen: targetScreen
    visible: open
    title: "Blox Emoji Picker"
    implicitWidth: LauncherState.emojiWidth
    implicitHeight: LauncherState.emojiHeight
    minimumSize: Qt.size(327, 260)
    color: "transparent"
    onWidthChanged: {
        if (visible && width >= minimumSize.width)
            LauncherState.emojiWidth = width;
    }
    onHeightChanged: {
        if (visible && height >= minimumSize.height)
            LauncherState.emojiHeight = height;
    }
    onOpenChanged: {
        if (open) {
            Qt.callLater(() => emojiGrid.positionViewAtBeginning());
            if (controller.category === "Search")
                focusTimer.restart();
            else
                Qt.callLater(() => emojiGrid.forceActiveFocus());
        } else {
            root.hoveredCell = null;
            root.hoveredItem = null;
            emojiSidebar.closeToneMenu();
            contextPopups.closeAll();
            activeEmojiPopups = 0;
            suppressEmojiActivation = false;
            toneGuard.stop();
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: controller.dismissRequested()
    }

    Connections {
        target: controller
        function onCategoryChanged() { emojiGrid.positionViewAtBeginning(); }
        function onNerdFontSourceChanged() { emojiGrid.positionViewAtBeginning(); }
        function onQueryChanged() { emojiGrid.positionViewAtBeginning(); }
    }

    Rectangle {
        id: card

        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(1)
        radius: Theme.scaledRadius(12)
        color: Theme.surface
        border.color: Theme.border
        clip: true
        opacity: root.positionReady ? 1 : 0

        MouseArea { anchors.fill: parent }

        MouseArea {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 9
            z: 99
            cursorShape: Qt.SizeAllCursor
            onPressed: root.contentItem.QsWindow.window.startSystemMove()
        }

        Row {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(10)
            spacing: Theme.scaledSpacing(8)

            EmojiSidebar {
                id: emojiSidebar
                height: parent.height
                controller: root.controller
                categoryIcons: root.categoryIcons
                toneColours: root.toneColours
                onPopupOpened: root.popupOpened()
                onPopupClosed: root.popupClosed()
                onCategorySelected: name => {
                    if (name === "Search") search.focusEditor(false);
                    else emojiGrid.forceActiveFocus();
                }
            }

            Rectangle {
                width: 1
                height: parent.height
                color: Theme.border
            }

            Column {
                width: parent.width - 61
                height: parent.height
                spacing: Theme.scaledSpacing(8)

                BloxTextField {
                    id: search

                    width: parent.width
                    visible: controller.category === "Search"
                    height: visible ? implicitHeight : 0
                    placeholderText: "Search emoji and icons"
                    text: controller.query
                    onTextEdited: value => controller.query = value
                    onAccepted: controller.activate()
                    Keys.onEscapePressed: controller.dismissRequested()
                }

                Row {
                    id: sectionBar

                    width: parent.width
                    height: visible ? 36 : 0
                    visible: controller.category === "Symbols" || controller.category === "Nerd Fonts"
                    spacing: Theme.scaledSpacing(6)

                    BloxButton {
                        id: nerdFontSourceButton

                        visible: controller.category === "Nerd Fonts"
                        width: visible ? Math.min(180, sourceLabelMetrics.advanceWidth + 45) : 0
                        height: 34
                        compact: true
                        onClicked: nerdFontSourceMenu.opened ? nerdFontSourceMenu.close() : nerdFontSourceMenu.open()

                        TextMetrics {
                            id: sourceLabelMetrics
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                            text: root.nerdFontSourceTitle()
                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.scaledSpacing(7)
                            PhosphorIcon { anchors.verticalCenter: parent.verticalCenter; width: 16; height: 16; iconName: "funnel"; iconColor: Theme.foreground }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: nerdFontSourceButton.width - 42
                                text: root.nerdFontSourceTitle()
                                color: Theme.foreground
                                font.family: Theme.bodyFontFamily
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        Popup {
                            id: nerdFontSourceMenu

                            parent: nerdFontSourceButton
                            popupType: Popup.Item
                            modal: true
                            dim: false
                            x: 0
                            y: nerdFontSourceButton.height + 4
                            width: 240
                            height: Math.min(360, nerdFontSourceList.contentHeight + 8)
                            padding: Theme.scaledSpacing(4)
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                            contentItem: ListView {
                                id: nerdFontSourceList
                                clip: true
                                spacing: Theme.scaledSpacing(3)
                                boundsBehavior: Flickable.StopAtBounds
                                model: controller.nerdFontSources
                                ScrollBar.vertical: BloxScrollBar {
                                    width: 8
                                    policy: nerdFontSourceList.contentHeight > nerdFontSourceList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                                }
                                delegate: BloxButton {
                                    required property var modelData
                                    width: nerdFontSourceList.width - 8
                                    height: 34
                                    compact: true
                                    checked: controller.nerdFontSource === modelData.key
                                    text: modelData.title + " · " + modelData.count
                                    onClicked: {
                                        controller.nerdFontSource = modelData.key;
                                        nerdFontSourceMenu.close();
                                        emojiGrid.forceActiveFocus();
                                    }
                                }
                            }

                            background: Rectangle { radius: Theme.scaledRadius(9); color: Theme.surfaceAlt; border.color: Theme.border }
                        }
                    }

                    Rectangle {
                        id: nerdFontSectionDivider
                        visible: controller.category === "Nerd Fonts"
                        width: visible ? 1 : 0
                        height: 26
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.border
                    }

                    ListView {
                        id: symbolJumpList

                        width: parent.width - nerdFontSourceButton.width - nerdFontSectionDivider.width - (nerdFontSourceButton.visible ? parent.spacing * 2 : 0)
                        height: 36
                        orientation: ListView.Horizontal
                        spacing: Theme.scaledSpacing(6)
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: controller.category === "Symbols" ? root.symbolSections : controller.nerdFontPurposes

                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: event => {
                                const delta = (event.pixelDelta.y || 0) !== 0 ? event.pixelDelta.y : (event.angleDelta.y || 0) / 2;
                                const maxX = Math.max(symbolJumpList.originX, symbolJumpList.originX + symbolJumpList.contentWidth - symbolJumpList.width);
                                symbolJumpList.contentX = Math.max(symbolJumpList.originX, Math.min(maxX, symbolJumpList.contentX - delta * 4));
                                event.accepted = true;
                            }
                        }

                        delegate: BloxButton {
                            required property var modelData
                            height: 34
                            width: implicitWidth
                            compact: true
                            text: modelData.title
                            checked: controller.category === "Symbols" ? root.activeSymbolSection === modelData.key : root.activeNerdFontSection === modelData.key
                            onClicked: root.jumpToSection(modelData.key, controller.category === "Nerd Fonts")
                        }
                    }
                }

                Text {
                    id: partialDataError
                    width: parent.width
                    height: visible ? 16 : 0
                    visible: controller.partialDataErrorText.length > 0
                    text: controller.partialDataErrorText
                    color: Theme.red
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }

                GridView {
                    id: emojiGrid

                    width: parent.width
                    height: parent.height - (search.visible ? search.height + 8 : 0) - (sectionBar.visible ? sectionBar.height + 8 : 0) - (partialDataError.visible ? partialDataError.height + 8 : 0)
                    rightMargin: emojiScrollbar.policy === ScrollBar.AlwaysOn ? 12 : 0
                    cellWidth: 58
                    cellHeight: 54
                    clip: true
                    model: controller.gridModel
                    currentIndex: controller.sectionedBrowse ? controller.gridIndexForItem(controller.selectedIndex) : controller.selectedIndex
                    activeFocusOnTab: true
                    onWidthChanged: root.syncGridColumns()
                    onContentYChanged: root.updateActiveSymbolSection()
                    Component.onCompleted: root.syncGridColumns()
                    Keys.onPressed: event => {
                        const columns = Math.max(1, Math.floor(width / cellWidth));
                        const pageSize = columns * Math.max(1, Math.floor(height / cellHeight));
                        let delta = 0;
                        if (event.key === Qt.Key_Left) delta = -1;
                        else if (event.key === Qt.Key_Right) delta = 1;
                        else if (event.key === Qt.Key_Up) delta = -columns;
                        else if (event.key === Qt.Key_Down) delta = columns;
                        else if (event.key === Qt.Key_PageUp) delta = -pageSize;
                        else if (event.key === Qt.Key_PageDown) delta = pageSize;
                        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ShiftModifier) && currentItem && currentItem.mixedToneCapable) {
                            currentItem.openToneComposer();
                            event.accepted = true;
                            return;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            controller.activate();
                            event.accepted = true;
                            return;
                        } else if (event.key === Qt.Key_Escape) {
                            controller.dismissRequested();
                            event.accepted = true;
                            return;
                        }
                        if ((event.key === Qt.Key_Home || event.key === Qt.Key_End) && controller.itemCount) {
                            if (!controller.sectionedBrowse) {
                                controller.selectedIndex = event.key === Qt.Key_Home ? 0 : controller.itemCount - 1;
                                positionViewAtIndex(controller.selectedIndex, GridView.Contain);
                            } else {
                                const step = event.key === Qt.Key_Home ? 1 : -1;
                                const total = controller.gridCount;
                                let target = event.key === Qt.Key_Home ? 0 : total - 1;
                                while (target >= 0 && target < total && controller.gridRowKind(target) !== 0) target += step;
                                if (target >= 0 && target < total) {
                                    controller.selectedIndex = controller.gridRowItemIndex(target);
                                    positionViewAtIndex(target, GridView.Contain);
                                }
                            }
                            event.accepted = true;
                            return;
                        }
                        if (delta !== 0 && controller.itemCount) {
                            if (!controller.sectionedBrowse) {
                                const target = Math.max(0, Math.min(controller.itemCount - 1, currentIndex + delta));
                                controller.selectedIndex = target;
                                positionViewAtIndex(target, GridView.Contain);
                            } else {
                                const total = controller.gridCount;
                                let target = Math.max(0, Math.min(total - 1, currentIndex + delta));
                                const direction = delta < 0 ? -1 : 1;
                                while (target >= 0 && target < total && controller.gridRowKind(target) !== 0) target += direction;
                                if (target >= 0 && target < total) {
                                    controller.selectedIndex = controller.gridRowItemIndex(target);
                                    positionViewAtIndex(target, GridView.Contain);
                                }
                            }
                            event.accepted = true;
                        }
                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: event => {
                            const delta = event.pixelDelta.y || event.angleDelta.y / 2;
                            emojiGrid.contentY = Math.max(emojiGrid.originY, Math.min(emojiGrid.originY + emojiGrid.contentHeight - emojiGrid.height, emojiGrid.contentY - delta * 4));
                            event.accepted = true;
                        }
                    }

                    ScrollBar.vertical: BloxScrollBar {
                        id: emojiScrollbar
                        width: 8
                        policy: emojiGrid.contentHeight > emojiGrid.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: controller.itemCount === 0 && controller.emptyStateText.length > 0
                        text: controller.emptyStateText
                        color: controller.emptyStateIsError ? Theme.red : Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                    }

                    delegate: Rectangle {
                        id: emojiCell

                        required property int index
                        readonly property var modelData: {
                            const revision = controller.browseRevision;
                            if (!controller.sectionedBrowse)
                                return {kind: "emoji", item: controller.itemAt(index), itemIndex: index};
                            const rowKind = controller.gridRowKind(index);
                            if (rowKind === 1)
                                return {kind: "heading", title: controller.gridRowTitle(index), itemIndex: -1};
                            if (rowKind !== 0)
                                return {kind: "spacer", itemIndex: -1};
                            const itemIndex = controller.gridRowItemIndex(index);
                            return {kind: "emoji", item: controller.itemAt(itemIndex), itemIndex: itemIndex};
                        }
                        readonly property bool mixedToneCapable: Boolean(modelData.kind === "emoji" && modelData.item && modelData.item.hasMixedTones)

                        function openToneComposer() {
                            if (!mixedToneCapable) return;
                            root.prepareEmojiContext(modelData.itemIndex, emojiCell);
                            contextPopups.openToneComposer(modelData.itemIndex, root.contextAnchor);
                        }

                        function closePopups() {
                            contextPopups.closeAll();
                        }

                        width: 48
                        height: 48
                        radius: Theme.scaledRadius(8)
                        z: modelData.kind === "heading" ? 2 : 0
                        color: modelData.kind === "emoji" && modelData.itemIndex === controller.selectedIndex ? Theme.surfaceAlt
                            : emojiHover.hovered ? Theme.withAlpha(Theme.foreground, 0.07) : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.scaledSpacing(4)
                            anchors.verticalCenter: parent.verticalCenter
                            visible: modelData.kind === "heading"
                            width: emojiGrid.width - emojiGrid.rightMargin - 8
                            text: modelData.title || ""
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                            font.bold: true
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: modelData.kind === "emoji"
                            text: modelData.item ? modelData.item.value : ""
                            color: Theme.foreground
                            font.family: modelData.item && modelData.item.fontFamily ? modelData.item.fontFamily : "Twemoji"
                            font.pixelSize: 25
                        }

                        Loader {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaledSpacing(3)
                            anchors.top: parent.top
                            anchors.topMargin: Theme.scaledSpacing(3)
                            width: 12
                            height: 12
                            active: Boolean(modelData.kind === "emoji" && modelData.item && modelData.item.pinned)
                            sourceComponent: PhosphorIcon {
                                iconName: "push-pin"
                                iconColor: Theme.foreground
                            }
                        }

                        Loader {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.scaledSpacing(3)
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.scaledSpacing(3)
                            width: 18
                            height: 11
                            active: Boolean(modelData.kind === "emoji" && modelData.item && modelData.item.hasMixedTones && (emojiHover.hovered || modelData.itemIndex === controller.selectedIndex))
                            sourceComponent: Item {
                                readonly property var tones: controller.preferredTonePair(emojiCell.modelData.item)
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 10; height: 10; radius: Theme.scaledRadius(5)
                                    color: root.toneColours[tones[0]]
                                    border.color: Theme.surface
                                }
                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 10; height: 10; radius: Theme.scaledRadius(5)
                                    color: root.toneColours[tones[1]]
                                    border.color: Theme.surface
                                }
                            }
                        }

                        HoverHandler {
                            id: emojiHover
                            enabled: modelData.kind === "emoji"
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onHoveredChanged: {
                                if (hovered && emojiCell.modelData.kind === "emoji" && emojiCell.modelData.item) {
                                    root.hoveredCell = emojiCell;
                                    root.hoveredItem = emojiCell.modelData.item;
                                } else if (root.hoveredCell === emojiCell) {
                                    root.hoveredCell = null;
                                    root.hoveredItem = null;
                                }
                            }
                        }

                        TapHandler {
                            enabled: modelData.kind === "emoji" && !root.suppressEmojiActivation && !emojiSidebar.toneMenuOpen
                            onTapped: {
                                controller.selectedIndex = modelData.itemIndex;
                                controller.activate();
                            }
                        }

                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            enabled: modelData.kind === "emoji"
                            onTapped: {
                                root.prepareEmojiContext(modelData.itemIndex, emojiCell);
                                contextPopups.openContextMenu(modelData.itemIndex, root.contextAnchor);
                            }
                        }
                    }
                }
            }
        }

        WindowResizeHandles { targetWindow: root; baseZ: 100 }

        BloxToolTip {
            parent: root.hoveredCell || card
            shown: root.open && root.hoveredCell !== null && root.hoveredItem !== null
            text: root.hoveredItem ? root.hoveredItem.name + (root.hoveredItem.pinned ? " · Pinned" : " · Right-click to pin") + (root.hoveredItem.hasMixedTones ? root.hoveredItem.pinned ? " · Right-click for tones" : " or adjust tones" : "") : ""
        }
    }

    EmojiContextPopups {
        id: contextPopups
        controller: root.controller
        hostContentItem: root.contentItem
        toneColours: root.toneColours
        emojiFontFamily: "Twemoji"
        onPopupOpened: root.popupOpened()
        onPopupClosed: root.popupClosed()
    }

    Timer {
        id: focusTimer
        interval: 30
        onTriggered: search.focusEditor(false)
    }

    Timer {
        id: toneGuard
        interval: 180
        onTriggered: {
            if (root.activeEmojiPopups === 0)
                root.suppressEmojiActivation = false;
        }
    }
}
