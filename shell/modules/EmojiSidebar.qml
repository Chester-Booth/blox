import qs.shared
import QtQuick
import QtQuick.Controls

// Left category rail and global skin-tone selector for EmojiPicker.
Item {
    id: root

    required property EmojiController controller
    required property var categoryIcons
    required property var toneColours
    readonly property bool toneMenuOpen: toneMenu.opened

    signal categorySelected(string categoryName)
    signal popupOpened()
    signal popupClosed()

    function closeToneMenu() {
        toneMenu.close();
    }

    width: 44

    ListView {
        id: categoryList

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: categoryToneSeparator.top
        anchors.bottomMargin: Theme.scaledSpacing(5)
        model: root.controller.categories
        spacing: Theme.scaledSpacing(5)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
                const delta = event.pixelDelta.y || event.angleDelta.y / 2;
                categoryList.contentY = Math.max(
                    categoryList.originY,
                    Math.min(categoryList.originY + categoryList.contentHeight - categoryList.height, categoryList.contentY - delta * 4)
                );
                event.accepted = true;
            }
        }

        delegate: Rectangle {
            required property string modelData
            required property int index

            width: 40
            height: 40
            radius: Theme.scaledRadius(8)
            color: root.controller.category === modelData ? Theme.surfaceAlt
                : categoryHover.hovered ? Theme.withAlpha(Theme.foreground, 0.1) : "transparent"
            border.width: root.controller.category === modelData || categoryHover.hovered ? 1 : 0
            border.color: root.controller.category === modelData ? Theme.accent : Theme.withAlpha(Theme.foreground, 0.4)

            PhosphorIcon {
                anchors.centerIn: parent
                width: 20
                height: 20
                iconName: root.categoryIcons[index]
                opacity: root.controller.category === modelData ? 1 : 0.62
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
                    root.controller.category = modelData;
                    root.categorySelected(modelData);
                }
            }
        }
    }

    Rectangle {
        id: categoryToneSeparator

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: toneButton.top
        anchors.bottomMargin: Theme.scaledSpacing(5)
        height: 1
        color: Theme.border
    }

    Rectangle {
        id: toneButton

        anchors.left: parent.left
        anchors.bottom: parent.bottom
        width: 40
        height: 40
        radius: Theme.scaledRadius(8)
        color: toneHover.hovered ? Theme.surfaceAlt : "transparent"

        Rectangle {
            anchors.centerIn: parent
            width: 20
            height: 20
            radius: Theme.scaledRadius(10)
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
            padding: Theme.scaledSpacing(6)
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            onOpened: root.popupOpened()
            onClosed: root.popupClosed()

            contentItem: Row {
                id: toneRow
                spacing: Theme.scaledSpacing(5)

                Repeater {
                    model: root.toneColours

                    Rectangle {
                        required property color modelData
                        required property int index

                        width: 30
                        height: 30
                        radius: Theme.scaledRadius(15)
                        color: modelData
                        border.width: LauncherState.emojiTone === index || toneChoiceHover.hovered ? 3 : 1
                        border.color: LauncherState.emojiTone === index || toneChoiceHover.hovered ? Theme.accent : Theme.border

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onPressed: mouse => mouse.accepted = true
                            onClicked: mouse => {
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
                radius: Theme.scaledRadius(9)
                color: Theme.surfaceAlt
                border.color: Theme.border
            }
        }
    }
}
