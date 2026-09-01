import qs.shared
import QtQuick
import QtQuick.Controls
import Quickshell

FloatingWindow {
    id: root

    required property ClipboardController controller
    required property bool positionReady
    required property bool watcherHealthy
    property bool open: false
    property var targetScreen
    property bool searchOpen: false

    function closeSearch() {
        focusTimer.stop();
        searchOpen = false;
        controller.query = "";
        Qt.callLater(() => {
            return clipboardList.forceActiveFocus();
        });
    }

    function formatBytes(bytes) {
        if (bytes < 1024)
            return bytes + " B";

        if (bytes < 1024 * 1024)
            return (bytes / 1024).toFixed(bytes < 10240 ? 1 : 0) + " KB";

        return (bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0) + " MB";
    }

    screen: targetScreen
    visible: open
    title: "Blox Clipboard"
    implicitWidth: LauncherState.clipboardWidth
    implicitHeight: LauncherState.clipboardHeight
    minimumSize: Qt.size(300, 240)
    color: "transparent"
    onWidthChanged: {
        if (visible && width >= minimumSize.width)
            LauncherState.clipboardWidth = width;

    }
    onHeightChanged: {
        if (visible && height >= minimumSize.height)
            LauncherState.clipboardHeight = height;

    }
    onOpenChanged: {
        if (open) {
            searchOpen = controller.query.length > 0;
            controller.refresh();
            if (searchOpen)
                focusTimer.restart();

        } else {
            focusTimer.stop();
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: controller.closeRequested()
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

        MouseArea {
            anchors.fill: parent
        }

        Column {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(10)
            spacing: Theme.scaledSpacing(8)

            Row {
                width: parent.width
                height: 38
                spacing: Theme.scaledSpacing(8)

                Text {
                    width: parent.width - searchButton.width - clearButton.width - 16
                    height: parent.height
                    text: root.watcherHealthy ? "Clipboard" : "Clipboard · history paused"
                    color: root.watcherHealthy ? Theme.foreground : Theme.yellow
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 17
                    font.bold: true
                    verticalAlignment: Text.AlignVCenter

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.SizeAllCursor
                        onPressed: root.contentItem.QsWindow.window.startSystemMove()
                    }

                }

                BloxButton {
                    id: searchButton

                    compact: true
                    text: ""
                    checked: root.searchOpen
                    onClicked: {
                        root.searchOpen = !root.searchOpen;
                        if (root.searchOpen)
                            focusTimer.restart();
                        else
                            root.closeSearch();
                    }

                    BloxToolTip {
                        shown: parent.hovered
                        text: "Search clipboard"
                    }

                    PhosphorIcon {
                        anchors.centerIn: parent
                        width: 17
                        height: 17
                        iconName: "magnifying-glass"
                        iconColor: Theme.foreground
                    }

                }

                BloxButton {
                    id: clearButton

                    compact: true
                    destructive: true
                    text: "       Clear"
                    iconName: ""
                    enabled: !controller.actionBusy
                    onClicked: controller.clearAll()

                    PhosphorIcon {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.scaledSpacing(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        iconName: "trash"
                        iconColor: Theme.red
                    }

                }

            }

            BloxTextField {
                id: search

                width: parent.width
                height: root.searchOpen ? implicitHeight : 0
                visible: root.searchOpen
                text: controller.query
                placeholderText: "Search clipboard"
                onTextEdited: (value) => {
                    return controller.query = value;
                }
                onAccepted: controller.activate()
            }

            ListView {
                id: clipboardList

                width: parent.width
                height: parent.height - 46 - (root.searchOpen ? search.height + 8 : 0)
                rightMargin: clipboardScrollbar.policy === ScrollBar.AlwaysOn ? 12 : 0
                model: controller.items
                clip: true
                currentIndex: controller.selectedIndex
                spacing: Theme.scaledSpacing(7)
                section.property: "group"
                section.criteria: ViewSection.FullString
                onContentYChanged: {
                    if (contentY + height >= contentHeight - 140)
                        controller.loadMore();

                }

                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (event) => {
                        const delta = event.pixelDelta.y || event.angleDelta.y / 2;
                        clipboardList.contentY = Math.max(clipboardList.originY, Math.min(clipboardList.originY + clipboardList.contentHeight - clipboardList.height, clipboardList.contentY - delta * 4));
                        event.accepted = true;
                    }
                }

                section.delegate: Text {
                    required property string section

                    width: ListView.view.width
                    height: 28
                    text: section
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    font.bold: true
                    verticalAlignment: Text.AlignVCenter
                }

                ScrollBar.vertical: ScrollBar {
                    id: clipboardScrollbar

                    width: 8
                    policy: clipboardList.contentHeight > clipboardList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

                    background: Rectangle {
                        radius: 999
                        color: Theme.withAlpha(Theme.foreground, 0.04)
                    }

                    contentItem: Rectangle {
                        implicitWidth: 4
                        radius: 999
                        color: clipboardScrollbar.hovered ? Theme.foreground : Theme.surfaceAlt
                    }

                }

                delegate: Rectangle {
                    id: itemCard

                    required property var modelData
                    required property int index

                    width: ListView.view.width - (clipboardScrollbar.policy === ScrollBar.AlwaysOn ? 12 : 0)
                    height: modelData.payload_uri.length > 0 ? 190 : modelData.file_path.length > 0 ? 102 : Math.max(44, Math.min(300, itemText.implicitHeight + 22))
                    radius: Theme.scaledRadius(9)
                    color: itemCard.activeFocus || (itemHover.hovered && !menuHover.hovered) ? Theme.surfaceAlt : Theme.background
                    border.color: itemCard.activeFocus ? Theme.accent : itemHover.hovered && !menuHover.hovered ? Theme.withAlpha(Theme.foreground, 0.32) : Theme.border
                    border.width: itemCard.activeFocus ? 2 : 1
                    activeFocusOnTab: true
                    onActiveFocusChanged: {
                        if (activeFocus)
                            controller.selectedIndex = index;

                    }
                    Keys.onReturnPressed: controller.activate()
                    Keys.onEnterPressed: controller.activate()
                    Keys.onSpacePressed: controller.activate()

                    Image {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: menuButton.bottom
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Theme.scaledSpacing(7)
                        anchors.rightMargin: Theme.scaledSpacing(7)
                        anchors.topMargin: Theme.scaledSpacing(7)
                        anchors.bottomMargin: Theme.scaledSpacing(7)
                        visible: modelData.payload_uri.length > 0
                        source: modelData.payload_uri
                        sourceSize.width: Math.min(1024, Math.ceil(width * Screen.devicePixelRatio))
                        sourceSize.height: Math.min(512, Math.ceil(height * Screen.devicePixelRatio))
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: false
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: menuButton.bottom
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.scaledSpacing(7)
                        visible: modelData.file_path.length > 0
                        radius: Theme.scaledRadius(7)
                        color: Theme.surface
                        border.color: Theme.border

                        PhosphorIcon {
                            id: fileIcon

                            anchors.left: parent.left
                            anchors.leftMargin: Theme.scaledSpacing(10)
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20
                            height: 20
                            iconName: modelData.file_icon || "file"
                            iconColor: Theme.foreground
                        }

                        Text {
                            anchors.left: fileIcon.right
                            anchors.leftMargin: Theme.scaledSpacing(8)
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaledSpacing(9)
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.file_path
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 13
                            elide: Text.ElideMiddle
                        }

                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.scaledSpacing(11)
                        anchors.right: menuButton.left
                        anchors.rightMargin: Theme.scaledSpacing(8)
                        anchors.verticalCenter: menuButton.verticalCenter
                        visible: modelData.payload_uri.length > 0 || modelData.file_path.length > 0
                        text: (modelData.payload_uri.length > 0 ? "Image" : "File") + "  •  " + root.formatBytes(modelData.payload_uri.length > 0 ? modelData.size : modelData.file_size)
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    Text {
                        id: itemText

                        anchors.left: parent.left
                        anchors.right: menuButton.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.scaledSpacing(11)
                        visible: modelData.payload_uri.length === 0 && modelData.file_path.length === 0
                        text: modelData.preview
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        maximumLineCount: 15
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: menuButton

                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.scaledSpacing(7)
                        width: 32
                        height: 30
                        radius: Theme.scaledRadius(7)
                        color: menuHover.hovered ? Theme.surfaceAlt : Theme.surface
                        border.color: Theme.border
                        activeFocusOnTab: true
                        Keys.onReturnPressed: itemMenu.open()
                        Keys.onEnterPressed: itemMenu.open()
                        Keys.onSpacePressed: itemMenu.open()

                        PhosphorIcon {
                            anchors.centerIn: parent
                            width: 20
                            height: 20
                            iconName: "dots-three"
                            iconColor: Theme.foreground
                        }

                        HoverHandler {
                            id: menuHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: itemMenu.open()
                        }

                    }

                    Popup {
                        id: itemMenu

                        readonly property point windowPosition: itemCard.mapToItem(root.contentItem, 0, 0)

                        parent: itemCard
                        popupType: Popup.Item
                        modal: true
                        dim: false
                        x: itemCard.width - width - 6
                        y: windowPosition.y + menuButton.y + menuButton.height + height <= root.height - 6 ? menuButton.y + menuButton.height : menuButton.y - height
                        width: 142
                        padding: Theme.scaledSpacing(4)
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                        contentItem: Column {
                            spacing: Theme.scaledSpacing(4)

                            BloxButton {
                                width: parent.width
                                text: modelData.pinned_at ? "Unpin" : "Pin"
                                onClicked: {
                                    controller.selectedIndex = index;
                                    controller.togglePin();
                                    itemMenu.close();
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

                            BloxButton {
                                width: parent.width
                                text: "Delete"
                                destructive: true
                                onClicked: {
                                    controller.selectedIndex = index;
                                    controller.remove();
                                    itemMenu.close();
                                }

                                PhosphorIcon {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.scaledSpacing(9)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 15
                                    height: 15
                                    iconName: "trash"
                                    iconColor: Theme.red
                                }

                            }

                        }

                        background: Rectangle {
                            radius: Theme.scaledRadius(10)
                            color: Theme.surfaceAlt
                            border.color: Theme.border
                        }

                    }

                    HoverHandler {
                        id: itemHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    MouseArea {
                        anchors.left: parent.left
                        anchors.right: menuButton.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            controller.selectedIndex = index;
                            controller.activate();
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

}
