import qs.shared
import QtQuick
import QtQuick.Controls

// Shared context menu and multi-tone skin-tone composer for EmojiPicker.
// Instantiated once per picker window rather than inside every GridView delegate.
Item {
    id: root

    required property EmojiController controller
    required property Item hostContentItem
    required property var toneColours
    property string emojiFontFamily: ""
    property int itemIndex: -1
    property point anchorPoint: Qt.point(0, 0)
    property real cellHeight: 48
    readonly property var item: itemIndex >= 0 ? controller.itemAt(itemIndex) : null

    signal popupOpened()
    signal popupClosed()

    function openContextMenu(index, anchor) {
        itemIndex = index;
        anchorPoint = anchor;
        emojiMenu.open();
    }

    function openToneComposer(index, anchor) {
        itemIndex = index;
        anchorPoint = anchor;
        toneComposer.openForItem();
    }

    function closeAll() {
        emojiMenu.close();
        toneComposer.close();
    }

    Popup {
        id: emojiMenu

        parent: root.hostContentItem
        popupType: Popup.Item
        modal: true
        dim: false
        x: Math.max(6, Math.min(root.hostContentItem.width - width - 6, root.anchorPoint.x - width))
        y: root.anchorPoint.y + height <= root.hostContentItem.height - 6
            ? root.anchorPoint.y
            : Math.max(6, root.anchorPoint.y - root.cellHeight - height)
        width: 168
        padding: Theme.scaledSpacing(4)
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: root.popupOpened()
        onClosed: root.popupClosed()

        contentItem: Column {
            spacing: Theme.scaledSpacing(3)

            BloxButton {
                visible: Boolean(root.item && root.item.hasMixedTones)
                width: emojiMenu.availableWidth
                height: visible ? 34 : 0
                compact: true
                text: "Choose tones"
                onClicked: {
                    emojiMenu.close();
                    toneComposer.openForItem();
                }
            }

            BloxButton {
                width: emojiMenu.availableWidth
                height: 34
                compact: true
                text: root.item && root.item.pinned ? "Unpin" : "Pin"
                onClicked: {
                    root.controller.togglePin(root.itemIndex);
                    emojiMenu.close();
                }

                PhosphorIcon {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.scaledSpacing(9)
                    anchors.verticalCenter: parent.verticalCenter
                    width: 15
                    height: 15
                    iconName: "push-pin"
                    iconColor: Theme.foreground
                }
            }
        }

        background: Rectangle {
            radius: Theme.scaledRadius(9)
            color: Theme.surfaceAlt
            border.color: Theme.border
        }
    }

    component ToneChoiceRow: Row {
        property string label: ""
        property int selectedTone: 3
        property bool defaultSelected: false
        signal tonePicked(int tone)

        width: parent.width
        height: 30
        spacing: Theme.scaledSpacing(7)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            text: parent.label
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 12
        }

        Repeater {
            id: swatchRepeater
            model: 5

            Rectangle {
                required property int index
                readonly property bool isCurrent: !parent.defaultSelected && parent.selectedTone === index + 1

                activeFocusOnTab: true
                width: 28
                height: 28
                radius: Theme.scaledRadius(14)
                color: root.toneColours[index + 1]
                border.width: isCurrent ? 3 : 1
                border.color: isCurrent || activeFocus ? Theme.accent : Theme.border
                Keys.onReturnPressed: parent.tonePicked(index + 1)
                Keys.onEnterPressed: parent.tonePicked(index + 1)
                Keys.onSpacePressed: parent.tonePicked(index + 1)

                TapHandler { onTapped: parent.parent.tonePicked(index + 1) }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }

        function focusTone(tone) {
            const choice = swatchRepeater.itemAt(tone - 1);
            if (choice)
                choice.forceActiveFocus();
        }
    }

    Popup {
        id: toneComposer

        property int firstTone: 3
        property int secondTone: 3
        property bool defaultSelected: false
        readonly property string previewValue: !root.item ? ""
            : defaultSelected ? root.item.baseValue
            : root.controller.variantValue(root.item, firstTone, secondTone)

        function openForItem() {
            if (!root.item || !root.item.hasMixedTones)
                return;
            const pair = root.controller.preferredTonePair(root.item);
            firstTone = pair[0] > 0 ? pair[0] : 3;
            secondTone = pair[1] > 0 ? pair[1] : 3;
            defaultSelected = root.controller.prefersDefaultVariant(root.item);
            open();
            Qt.callLater(() => leftRow.focusTone(firstTone));
        }

        parent: root.hostContentItem
        popupType: Popup.Item
        modal: true
        dim: false
        x: Math.max(6, Math.min(root.hostContentItem.width - width - 6, root.anchorPoint.x - width))
        y: root.anchorPoint.y + height <= root.hostContentItem.height - 6
            ? root.anchorPoint.y
            : Math.max(6, root.anchorPoint.y - root.cellHeight - height)
        width: 264
        height: 226
        padding: Theme.scaledSpacing(10)
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: root.popupOpened()
        onClosed: root.popupClosed()

        contentItem: Column {
            spacing: Theme.scaledSpacing(8)

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
                radius: Theme.scaledRadius(8)
                color: Theme.withAlpha(Theme.foreground, 0.06)

                Text {
                    anchors.centerIn: parent
                    text: toneComposer.previewValue || (root.item ? root.item.baseValue : "")
                    font.family: root.emojiFontFamily
                    font.pixelSize: 32
                }
            }

            ToneChoiceRow {
                id: leftRow
                label: "Left"
                selectedTone: toneComposer.firstTone
                defaultSelected: toneComposer.defaultSelected
                onTonePicked: tone => {
                    toneComposer.defaultSelected = false;
                    toneComposer.firstTone = tone;
                }
            }

            ToneChoiceRow {
                label: "Right"
                selectedTone: toneComposer.secondTone
                defaultSelected: toneComposer.defaultSelected
                onTonePicked: tone => {
                    toneComposer.defaultSelected = false;
                    toneComposer.secondTone = tone;
                }
            }

            Row {
                width: parent.width
                height: 34
                spacing: Theme.scaledSpacing(7)

                BloxButton {
                    width: (parent.width - parent.spacing) / 2
                    height: 34
                    compact: true
                    checked: toneComposer.defaultSelected
                    text: "Default"
                    onClicked: toneComposer.defaultSelected = true
                }

                Item {
                    id: copyReasonWrapper

                    width: (parent.width - parent.spacing) / 2
                    height: 34
                    activeFocusOnTab: !copyButton.enabled || activeFocus

                    BloxButton {
                        id: copyButton

                        anchors.fill: parent
                        compact: true
                        enabled: toneComposer.previewValue.length > 0
                        text: "Copy"
                        onEnabledChanged: {
                            if (enabled && copyReasonWrapper.activeFocus)
                                forceActiveFocus();
                        }
                        onClicked: {
                            if (toneComposer.defaultSelected)
                                root.controller.activateDefaultVariant(root.itemIndex);
                            else
                                root.controller.activateToneVariant(root.itemIndex, toneComposer.firstTone, toneComposer.secondTone);
                            toneComposer.close();
                        }
                    }

                    HoverHandler { id: copyReasonHover }

                    Item {
                        anchors.fill: parent
                        BloxToolTip {
                            shown: !copyButton.enabled && (copyReasonHover.hovered || copyReasonWrapper.activeFocus)
                            text: "No emoji for these tones."
                        }
                    }
                }
            }
        }

        background: Rectangle {
            radius: Theme.scaledRadius(10)
            color: Theme.surfaceAlt
            border.color: Theme.border
        }
    }
}
