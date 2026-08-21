import "../shared"
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
    readonly property var contextItem: contextItemIndex >= 0 ? controller.itemAt(contextItemIndex) : null
    property var gridItems: []
    readonly property var categoryIcons: ["magnifying-glass", "clock-counter-clockwise", "smiley", "person-simple", "paw-print", "hamburger", "soccer-ball", "airplane", "lamp", "flag", "shapes", "code"]
    readonly property var toneColours: ["#ffdc5d", "#f7dece", "#e0bb95", "#c58c6b", "#a56b46", "#6f432a"]
    readonly property var symbolSections: [{
        "key": "emoji",
        "title": "Emoji signs"
    }, {
        "key": "common",
        "title": "Common marks & games"
    }, {
        "key": "shape",
        "title": "Shapes"
    }, {
        "key": "arrow",
        "title": "Arrows"
    }, {
        "key": "maths",
        "title": "Maths & logic"
    }, {
        "key": "currency",
        "title": "Currency"
    }, {
        "key": "technical",
        "title": "Technical notation"
    }]
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

    function symbolSectionKey(item) {
        const subgroup = String(item.subcategory || "");
        if (!subgroup.startsWith("text-"))
            return "emoji";

        if (subgroup === "text-common" || subgroup === "text-punctuation")
            return "common";

        if (subgroup === "text-shape")
            return "shape";

        if (subgroup === "text-arrow")
            return "arrow";

        if (subgroup === "text-maths")
            return "maths";

        if (subgroup === "text-currency")
            return "currency";

        return "technical";
    }

    function appendHeading(target, key, title, columns) {
        while (target.length % columns)target.push({
            "kind": "spacer",
            "itemIndex": -1
        })
        target.push({
            "kind": "heading",
            "sectionKey": key,
            "title": title,
            "itemIndex": -1
        });
        for (let index = 1; index < columns; index++) target.push({
            "kind": "spacer",
            "itemIndex": -1
        })
    }

    function rebuildGridItems() {
        if (controller.virtualBrowse) {
            gridItems = [];
            return ;
        }
        const columns = Math.max(1, Math.floor((emojiGrid.width - emojiGrid.rightMargin) / emojiGrid.cellWidth));
        const display = [];
        if (controller.category === "Symbols" || controller.category === "Nerd Fonts") {
            const sections = controller.category === "Symbols" ? symbolSections : controller.nerdFontPurposes;
            for (const section of sections) {
                const matches = [];
                for (let index = 0; index < controller.items.length; index++) {
                    const sectionKey = controller.category === "Symbols" ? symbolSectionKey(controller.items[index]) : controller.items[index].subcategory;
                    if (sectionKey === section.key)
                        matches.push({
                        "kind": "emoji",
                        "item": controller.items[index],
                        "itemIndex": index
                    });

                }
                if (!matches.length)
                    continue;

                appendHeading(display, section.key, section.title, columns);
                for (const match of matches) display.push(match)
            }
        } else {
            for (let index = 0; index < controller.items.length; index++) display.push({
                "kind": "emoji",
                "item": controller.items[index],
                "itemIndex": index
            })
        }
        gridItems = display;
    }

    function gridIndexForItem(itemIndex) {
        for (let index = 0; index < gridItems.length; index++) {
            if (gridItems[index].itemIndex === itemIndex)
                return index;

        }
        return -1;
    }

    function jumpToSymbolSection(key) {
        for (let index = 0; index < gridItems.length; index++) {
            const item = gridItems[index];
            if (item.kind === "heading" && item.sectionKey === key) {
                activeSymbolSection = key;
                emojiGrid.positionViewAtIndex(index, GridView.Beginning);
                emojiGrid.forceActiveFocus();
                return ;
            }
        }
    }

    function jumpToNerdFontSection(key) {
        for (let index = 0; index < gridItems.length; index++) {
            const item = gridItems[index];
            if (item.kind === "heading" && item.sectionKey === key) {
                activeNerdFontSection = key;
                emojiGrid.positionViewAtIndex(index, GridView.Beginning);
                emojiGrid.forceActiveFocus();
                return ;
            }
        }
    }

    function updateActiveSymbolSection() {
        if (controller.category !== "Symbols" && controller.category !== "Nerd Fonts")
            return ;

        const columns = Math.max(1, Math.floor((emojiGrid.width - emojiGrid.rightMargin) / emojiGrid.cellWidth));
        const firstIndex = Math.min(gridItems.length - 1, Math.max(0, Math.floor(emojiGrid.contentY / emojiGrid.cellHeight) * columns));
        for (let index = firstIndex; index >= 0; index--) {
            if (gridItems[index].kind === "heading") {
                if (controller.category === "Symbols")
                    activeSymbolSection = gridItems[index].sectionKey;
                else
                    activeNerdFontSection = gridItems[index].sectionKey;
                return ;
            }
        }
        if (controller.category === "Symbols")
            activeSymbolSection = "emoji";

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
            Qt.callLater(() => {
                return emojiGrid.positionViewAtBeginning();
            });
            if (controller.category === "Search")
                focusTimer.restart();
            else
                Qt.callLater(() => {
                return emojiGrid.forceActiveFocus();
            });
        } else {
            toneMenu.close();
            if (emojiGrid.currentItem && emojiGrid.currentItem.closePopups)
                emojiGrid.currentItem.closePopups();

            activeEmojiPopups = 0;
            suppressEmojiActivation = false;
            toneGuard.stop();
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: controller.closeRequested()
    }

    Connections {
        function onItemsChanged() {
            root.rebuildGridItems();
            emojiGrid.positionViewAtBeginning();
        }

        function onBrowseItemsChanged() {
            if (controller.virtualBrowse)
                emojiGrid.positionViewAtBeginning();

        }

        function onVirtualBrowseChanged() {
            root.rebuildGridItems();
            emojiGrid.positionViewAtBeginning();
        }

        target: controller
    }

    Rectangle {
        id: card

        anchors.fill: parent
        anchors.margins: 1
        radius: 12
        color: Theme.surface
        border.color: Theme.border
        clip: true
        opacity: root.positionReady ? 1 : 0

        MouseArea {
            anchors.fill: parent
        }

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
            anchors.margins: 10
            spacing: 8

            Item {
                width: 44
                height: parent.height

                ListView {
                    id: categoryList

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: categoryToneSeparator.top
                    anchors.bottomMargin: 5
                    model: controller.categories
                    spacing: 5
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            const delta = event.pixelDelta.y || event.angleDelta.y / 2;
                            categoryList.contentY = Math.max(categoryList.originY, Math.min(categoryList.originY + categoryList.contentHeight - categoryList.height, categoryList.contentY - delta * 4));
                            event.accepted = true;
                        }
                    }

                    delegate: Rectangle {
                        id: categoryButton

                        required property string modelData
                        required property int index

                        width: 40
                        height: 40
                        radius: 8
                        color: controller.category === modelData ? Theme.surfaceAlt : categoryHover.hovered ? Theme.withAlpha(Theme.foreground, 0.1) : "transparent"
                        border.width: controller.category === modelData || categoryHover.hovered ? 1 : 0
                        border.color: controller.category === modelData ? Theme.accent : Theme.withAlpha(Theme.foreground, 0.4)

                        PhosphorIcon {
                            anchors.centerIn: parent
                            width: 20
                            height: 20
                            iconName: root.categoryIcons[index]
                            opacity: controller.category === modelData ? 1 : 0.62
                        }

                        BloxToolTip {
                            shown: categoryHover.hovered
                            text: modelData
                        }

                        HoverHandler {
                            id: categoryHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: {
                                controller.category = modelData;
                                if (modelData === "Search")
                                    search.focusEditor(false);
                                else
                                    emojiGrid.forceActiveFocus();
                            }
                        }

                    }

                }

                Rectangle {
                    id: categoryToneSeparator

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: toneButton.top
                    anchors.bottomMargin: 5
                    height: 1
                    color: Theme.border
                }

                Rectangle {
                    id: toneButton

                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    width: 40
                    height: 40
                    radius: 8
                    color: toneHover.hovered ? Theme.surfaceAlt : "transparent"

                    Rectangle {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        radius: 10
                        color: root.toneColours[LauncherState.emojiTone]
                        border.color: Theme.border
                    }

                    BloxToolTip {
                        shown: toneHover.hovered && !toneMenu.opened
                        text: "Skin tone"
                    }

                    HoverHandler {
                        id: toneHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: toneMenu.opened ? toneMenu.close() : toneMenu.open()
                    }

                    Popup {
                        id: toneMenu

                        parent: toneButton
                        popupType: Popup.Item
                        modal: true
                        dim: false
                        x: toneButton.width + 6
                        y: (toneButton.height - height) / 2
                        width: toneRow.implicitWidth + 12
                        height: 46
                        padding: 6
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                        onOpened: root.popupOpened()
                        onClosed: root.popupClosed()

                        contentItem: Row {
                            id: toneRow

                            spacing: 5

                            Repeater {
                                model: root.toneColours

                                Rectangle {
                                    id: toneChoice

                                    required property color modelData
                                    required property int index

                                    width: 30
                                    height: 30
                                    radius: 15
                                    color: modelData
                                    border.width: LauncherState.emojiTone === index || toneChoiceHover.hovered ? 3 : 1
                                    border.color: LauncherState.emojiTone === index || toneChoiceHover.hovered ? Theme.accent : Theme.border

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onPressed: (mouse) => {
                                            return mouse.accepted = true;
                                        }
                                        onClicked: (mouse) => {
                                            mouse.accepted = true;
                                            LauncherState.emojiTone = index;
                                            toneMenu.close();
                                        }
                                    }

                                    HoverHandler {
                                        id: toneChoiceHover

                                        cursorShape: Qt.PointingHandCursor
                                    }

                                }

                            }

                        }

                        background: Rectangle {
                            radius: 9
                            color: Theme.surfaceAlt
                            border.color: Theme.border
                        }

                    }

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
                spacing: 8

                BloxTextField {
                    id: search

                    width: parent.width
                    visible: controller.category === "Search"
                    height: visible ? implicitHeight : 0
                    placeholderText: "Search emoji and icons"
                    text: controller.query
                    onTextEdited: (value) => {
                        return controller.query = value;
                    }
                    onAccepted: controller.activate()
                    Keys.onEscapePressed: controller.closeRequested()
                }

                Row {
                    id: sectionBar

                    width: parent.width
                    height: visible ? 36 : 0
                    visible: controller.category === "Symbols" || controller.category === "Nerd Fonts"
                    spacing: 6

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
                            spacing: 7

                            PhosphorIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 16
                                height: 16
                                iconName: "funnel"
                                iconColor: Theme.foreground
                            }

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
                            padding: 4
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                            contentItem: ListView {
                                id: nerdFontSourceList

                                clip: true
                                spacing: 3
                                boundsBehavior: Flickable.StopAtBounds
                                model: controller.nerdFontSources

                                ScrollBar.vertical: ScrollBar {
                                    id: nerdFontSourceScrollbar

                                    width: 8
                                    policy: nerdFontSourceList.contentHeight > nerdFontSourceList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

                                    background: Rectangle {
                                        radius: 999
                                        color: Theme.withAlpha(Theme.foreground, 0.08)
                                    }

                                    contentItem: Rectangle {
                                        implicitWidth: 5
                                        radius: 999
                                        color: nerdFontSourceScrollbar.hovered ? Theme.foreground : Theme.muted
                                    }

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

                            background: Rectangle {
                                radius: 9
                                color: Theme.surfaceAlt
                                border.color: Theme.border
                            }

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
                        spacing: 6
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: controller.category === "Symbols" ? root.symbolSections : controller.nerdFontPurposes

                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: (event) => {
                                const pixelDelta = event.pixelDelta.y || 0;
                                const angleDelta = event.angleDelta.y || 0;
                                const delta = pixelDelta !== 0 ? pixelDelta : angleDelta / 2;
                                const maximumContentX = Math.max(symbolJumpList.originX, symbolJumpList.originX + symbolJumpList.contentWidth - symbolJumpList.width);
                                symbolJumpList.contentX = Math.max(symbolJumpList.originX, Math.min(maximumContentX, symbolJumpList.contentX - delta * 4));
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
                            onClicked: {
                                if (controller.category === "Symbols")
                                    root.jumpToSymbolSection(modelData.key);
                                else
                                    root.jumpToNerdFontSection(modelData.key);
                            }
                        }

                    }

                }

                GridView {
                    id: emojiGrid

                    width: parent.width
                    height: parent.height - (search.visible ? search.height + 8 : 0) - (sectionBar.visible ? sectionBar.height + 8 : 0)
                    rightMargin: emojiScrollbar.policy === ScrollBar.AlwaysOn ? 12 : 0
                    cellWidth: 58
                    cellHeight: 54
                    clip: true
                    model: controller.virtualBrowse ? controller.itemCount : root.gridItems.length
                    currentIndex: controller.virtualBrowse ? controller.selectedIndex : root.gridIndexForItem(controller.selectedIndex)
                    activeFocusOnTab: true
                    onWidthChanged: root.rebuildGridItems()
                    onContentYChanged: root.updateActiveSymbolSection()
                    Component.onCompleted: root.rebuildGridItems()
                    Keys.onPressed: (event) => {
                        const columns = Math.max(1, Math.floor(width / cellWidth));
                        let delta = 0;
                        if (event.key === Qt.Key_Left) {
                            delta = -1;
                        } else if (event.key === Qt.Key_Right) {
                            delta = 1;
                        } else if (event.key === Qt.Key_Up) {
                            delta = -columns;
                        } else if (event.key === Qt.Key_Down) {
                            delta = columns;
                        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ShiftModifier) && currentItem && currentItem.mixedToneCapable) {
                            currentItem.openToneComposer();
                            event.accepted = true;
                            return ;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            controller.activate();
                            event.accepted = true;
                            return ;
                        } else if (event.key === Qt.Key_Escape) {
                            controller.closeRequested();
                            event.accepted = true;
                            return ;
                        }
                        if (delta !== 0 && controller.itemCount) {
                            if (controller.virtualBrowse) {
                                const target = Math.max(0, Math.min(controller.itemCount - 1, currentIndex + delta));
                                controller.selectedIndex = target;
                                positionViewAtIndex(target, GridView.Contain);
                            } else {
                                let target = Math.max(0, Math.min(root.gridItems.length - 1, currentIndex + delta));
                                const direction = delta < 0 ? -1 : 1;
                                while (target >= 0 && target < root.gridItems.length && root.gridItems[target].kind !== "emoji")target += direction
                                if (target >= 0 && target < root.gridItems.length) {
                                    controller.selectedIndex = root.gridItems[target].itemIndex;
                                    positionViewAtIndex(target, GridView.Contain);
                                }
                            }
                            event.accepted = true;
                        }
                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            const delta = event.pixelDelta.y || event.angleDelta.y / 2;
                            emojiGrid.contentY = Math.max(emojiGrid.originY, Math.min(emojiGrid.originY + emojiGrid.contentHeight - emojiGrid.height, emojiGrid.contentY - delta * 4));
                            event.accepted = true;
                        }
                    }

                    ScrollBar.vertical: ScrollBar {
                        id: emojiScrollbar

                        width: 8
                        policy: emojiGrid.contentHeight > emojiGrid.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

                        background: Rectangle {
                            radius: 999
                            color: Theme.withAlpha(Theme.foreground, 0.04)
                        }

                        contentItem: Rectangle {
                            implicitWidth: 4
                            radius: 999
                            color: emojiScrollbar.hovered ? Theme.foreground : Theme.surfaceAlt
                        }

                    }

                    delegate: Rectangle {
                        id: emojiCell

                        required property int index
                        readonly property var modelData: controller.virtualBrowse ? ({
                            "kind": "emoji",
                            "item": controller.itemAt(index),
                            "itemIndex": index
                        }) : root.gridItems[index]
                        readonly property bool mixedToneCapable: Boolean(modelData.kind === "emoji" && modelData.item && modelData.item.hasMixedTones)

                        function openToneComposer() {
                            if (!mixedToneCapable)
                                return ;

                            root.prepareEmojiContext(modelData.itemIndex, emojiCell);
                            toneComposer.openForItem();
                        }

                        function closePopups() {
                            emojiMenu.close();
                            toneComposer.close();
                        }

                        width: 48
                        height: 48
                        radius: 8
                        z: modelData.kind === "heading" ? 2 : 0
                        color: modelData.kind === "emoji" && modelData.itemIndex === controller.selectedIndex ? Theme.surfaceAlt : emojiHover.hovered ? Theme.withAlpha(Theme.foreground, 0.07) : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 4
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

                        PhosphorIcon {
                            anchors.right: parent.right
                            anchors.rightMargin: 3
                            anchors.top: parent.top
                            anchors.topMargin: 3
                            width: 12
                            height: 12
                            visible: modelData.kind === "emoji" && modelData.item && modelData.item.pinned
                            iconName: "push-pin"
                            iconColor: Theme.foreground
                        }

                        Item {
                            anchors.left: parent.left
                            anchors.leftMargin: 3
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 3
                            width: 18
                            height: 11
                            visible: modelData.kind === "emoji" && modelData.item && modelData.item.hasMixedTones && (emojiHover.hovered || modelData.itemIndex === controller.selectedIndex)

                            Rectangle {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: 10
                                height: 10
                                radius: 5
                                color: root.toneColours[controller.preferredTonePair(modelData.item)[0]]
                                border.color: Theme.surface
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 10
                                height: 10
                                radius: 5
                                color: root.toneColours[controller.preferredTonePair(modelData.item)[1]]
                                border.color: Theme.surface
                            }

                        }

                        BloxToolTip {
                            shown: modelData.kind === "emoji" && emojiHover.hovered
                            text: modelData.item ? modelData.item.name + (modelData.item.pinned ? " · Pinned" : " · Right-click to pin") + (modelData.item.hasMixedTones ? modelData.item.pinned ? " · Right-click for tones" : " or adjust tones" : "") : ""
                        }

                        HoverHandler {
                            id: emojiHover

                            enabled: modelData.kind === "emoji"
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        }

                        TapHandler {
                            enabled: modelData.kind === "emoji" && !root.suppressEmojiActivation && !toneMenu.opened
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
                                emojiMenu.open();
                            }
                        }

                        Popup {
                            id: emojiMenu

                            parent: root.contentItem
                            popupType: Popup.Item
                            modal: true
                            dim: false
                            x: Math.max(6, Math.min(root.width - width - 6, root.contextAnchor.x - width))
                            y: root.contextAnchor.y + height <= root.height - 6 ? root.contextAnchor.y : Math.max(6, root.contextAnchor.y - emojiCell.height - height)
                            width: 168
                            padding: 4
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                            onOpened: root.popupOpened()
                            onClosed: root.popupClosed()

                            contentItem: Column {
                                spacing: 3

                                BloxButton {
                                    visible: modelData.item && modelData.item.hasMixedTones
                                    width: emojiMenu.availableWidth
                                    height: visible ? 34 : 0
                                    compact: true
                                    text: "Choose tones"
                                    onClicked: {
                                        emojiMenu.close();
                                        emojiCell.openToneComposer();
                                    }
                                }

                                BloxButton {
                                    width: emojiMenu.availableWidth
                                    height: 34
                                    compact: true
                                    text: modelData.item && modelData.item.pinned ? "Unpin" : "Pin"
                                    onClicked: {
                                        controller.togglePin(modelData.itemIndex);
                                        emojiMenu.close();
                                    }

                                    PhosphorIcon {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 9
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 15
                                        height: 15
                                        iconName: "push-pin"
                                        iconColor: Theme.foreground
                                    }

                                }

                            }

                            background: Rectangle {
                                radius: 9
                                color: Theme.surfaceAlt
                                border.color: Theme.border
                            }

                        }

                        Popup {
                            id: toneComposer

                            property int firstTone: 3
                            property int secondTone: 3
                            property bool defaultSelected: false
                            readonly property string previewValue: !modelData.item ? "" : defaultSelected ? modelData.item.baseValue : controller.variantValue(modelData.item, firstTone, secondTone)

                            function openForItem() {
                                const pair = controller.preferredTonePair(modelData.item);
                                firstTone = pair[0] > 0 ? pair[0] : 3;
                                secondTone = pair[1] > 0 ? pair[1] : 3;
                                defaultSelected = controller.prefersDefaultVariant(modelData.item);
                                open();
                                Qt.callLater(() => {
                                    const choice = firstToneChoices.itemAt(firstTone - 1);
                                    if (choice)
                                        choice.forceActiveFocus();

                                });
                            }

                            parent: root.contentItem
                            popupType: Popup.Item
                            modal: true
                            dim: false
                            x: Math.max(6, Math.min(root.width - width - 6, root.contextAnchor.x - width))
                            y: root.contextAnchor.y + height <= root.height - 6 ? root.contextAnchor.y : Math.max(6, root.contextAnchor.y - emojiCell.height - height)
                            width: 264
                            height: 226
                            padding: 10
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                            onOpened: root.popupOpened()
                            onClosed: root.popupClosed()

                            contentItem: Column {
                                spacing: 8

                                Text {
                                    width: parent.width
                                    text: "Choose skin tones"
                                    color: Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 13
                                    font.bold: true
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 54
                                    radius: 8
                                    color: Theme.withAlpha(Theme.foreground, 0.06)

                                    Text {
                                        anchors.centerIn: parent
                                        text: toneComposer.previewValue || (modelData.item ? modelData.item.baseValue : "")
                                        font.family: "Twemoji"
                                        font.pixelSize: 32
                                    }

                                }

                                Row {
                                    width: parent.width
                                    height: 30
                                    spacing: 7

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 40
                                        text: "Left"
                                        color: Theme.muted
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 12
                                    }

                                    Repeater {
                                        id: firstToneChoices

                                        model: 5

                                        Rectangle {
                                            required property int index

                                            activeFocusOnTab: true
                                            width: 28
                                            height: 28
                                            radius: 14
                                            color: root.toneColours[index + 1]
                                            border.width: !toneComposer.defaultSelected && toneComposer.firstTone === index + 1 ? 3 : 1
                                            border.color: !toneComposer.defaultSelected && toneComposer.firstTone === index + 1 || activeFocus ? Theme.accent : Theme.border
                                            Keys.onReturnPressed: {
                                                toneComposer.defaultSelected = false;
                                                toneComposer.firstTone = index + 1;
                                            }
                                            Keys.onEnterPressed: {
                                                toneComposer.defaultSelected = false;
                                                toneComposer.firstTone = index + 1;
                                            }
                                            Keys.onSpacePressed: {
                                                toneComposer.defaultSelected = false;
                                                toneComposer.firstTone = index + 1;
                                            }

                                            TapHandler {
                                                onTapped: {
                                                    toneComposer.defaultSelected = false;
                                                    toneComposer.firstTone = index + 1;
                                                }
                                            }

                                            HoverHandler {
                                                cursorShape: Qt.PointingHandCursor
                                            }

                                        }

                                    }

                                }

                                Row {
                                    width: parent.width
                                    height: 30
                                    spacing: 7

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 40
                                        text: "Right"
                                        color: Theme.muted
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 12
                                    }

                                    Repeater {
                                        id: secondToneChoices

                                        model: 5

                                        Rectangle {
                                            required property int index

                                            activeFocusOnTab: true
                                            width: 28
                                            height: 28
                                            radius: 14
                                            color: root.toneColours[index + 1]
                                            border.width: !toneComposer.defaultSelected && toneComposer.secondTone === index + 1 ? 3 : 1
                                            border.color: !toneComposer.defaultSelected && toneComposer.secondTone === index + 1 || activeFocus ? Theme.accent : Theme.border
                                            Keys.onReturnPressed: {
                                                toneComposer.defaultSelected = false;
                                                toneComposer.secondTone = index + 1;
                                            }
                                            Keys.onEnterPressed: {
                                                toneComposer.defaultSelected = false;
                                                toneComposer.secondTone = index + 1;
                                            }
                                            Keys.onSpacePressed: {
                                                toneComposer.defaultSelected = false;
                                                toneComposer.secondTone = index + 1;
                                            }

                                            TapHandler {
                                                onTapped: {
                                                    toneComposer.defaultSelected = false;
                                                    toneComposer.secondTone = index + 1;
                                                }
                                            }

                                            HoverHandler {
                                                cursorShape: Qt.PointingHandCursor
                                            }

                                        }

                                    }

                                }

                                Row {
                                    width: parent.width
                                    height: 34
                                    spacing: 7

                                    BloxButton {
                                        width: (parent.width - parent.spacing) / 2
                                        height: 34
                                        compact: true
                                        checked: toneComposer.defaultSelected
                                        text: "Default"
                                        onClicked: toneComposer.defaultSelected = true
                                    }

                                    BloxButton {
                                        width: (parent.width - parent.spacing) / 2
                                        height: 34
                                        compact: true
                                        enabled: toneComposer.previewValue.length > 0
                                        text: "Copy"
                                        onClicked: {
                                            if (toneComposer.defaultSelected)
                                                controller.activateDefaultVariant(modelData.itemIndex);
                                            else
                                                controller.activateToneVariant(modelData.itemIndex, toneComposer.firstTone, toneComposer.secondTone);
                                            toneComposer.close();
                                        }
                                    }

                                }

                            }

                            background: Rectangle {
                                radius: 10
                                color: Theme.surfaceAlt
                                border.color: Theme.border
                            }

                        }

                    }

                }

            }

        }

        MouseArea {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 7
            z: 100
            cursorShape: Qt.SizeHorCursor
            onPressed: root.contentItem.QsWindow.window.startSystemResize(Qt.RightEdge)
        }

        MouseArea {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 7
            z: 101
            cursorShape: Qt.SizeVerCursor
            onPressed: root.contentItem.QsWindow.window.startSystemResize(Qt.BottomEdge)
        }

        MouseArea {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 7
            z: 102
            cursorShape: Qt.SizeHorCursor
            onPressed: root.contentItem.QsWindow.window.startSystemResize(Qt.LeftEdge)
        }

        MouseArea {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 7
            z: 103
            cursorShape: Qt.SizeVerCursor
            onPressed: root.contentItem.QsWindow.window.startSystemResize(Qt.TopEdge)
        }

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
