import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared

// Floating theme shelf, new-theme menu, and theme card context menu overlays.
Item {
    id: overlay

    required property var windowOwner
    required property var themeLibrary
    required property var frameItem

    readonly property alias themeSearchField: themeSearchField
    readonly property alias themeList: themeList
    readonly property alias newThemeToggleButton: newThemeToggleButton
    readonly property alias newFromBlankButton: newFromBlankButton
    readonly property alias themeCardMenuOverlay: themeCardMenuOverlay
    readonly property alias themeMenuExportButton: themeMenuExportButton

    MouseArea {
        id: shelfDismiss
        anchors.fill: parent
        visible: overlay.windowOwner.shelfOpen
        z: 19
        acceptedButtons: Qt.AllButtons
        onClicked: {
            overlay.windowOwner.shelfOpen = false;
            overlay.windowOwner.newMenuOpen = false;
            overlay.windowOwner.closeThemeCardMenu();
        }
    }

    Rectangle {
        id: themeShelf
        visible: overlay.windowOwner.shelfOpen
        z: 20
        x: overlay.windowOwner.themeShelfX
        y: overlay.windowOwner.themeShelfY
        width: overlay.windowOwner.themeShelfWidth
        height: overlay.windowOwner.themeShelfHeight
        color: Theme.surface
        border.color: Theme.border
        border.width: 1
        radius: Theme.scaledRadius(9)

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            preventStealing: true
            onClicked: overlay.windowOwner.closeThemeCardMenu()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(8)
            spacing: Theme.scaledSpacing(6)

            RowLayout {
                Layout.fillWidth: true
                Layout.minimumHeight: 38
                z: 2
                spacing: Theme.scaledSpacing(6)
                BloxTextField {
                    id: themeSearchField
                    Layout.fillWidth: true
                    placeholderText: "Search themes"
                    text: overlay.themeLibrary.searchText
                    onTextEdited: value => overlay.themeLibrary.searchText = value
                }
                Item {
                    id: newThemeButton
                    Layout.preferredWidth: 38
                    Layout.preferredHeight: 38
                    z: overlay.windowOwner.newMenuOpen ? 100 : 0
                    BloxButton {
                        id: newThemeToggleButton
                        objectName: "new-theme-toggle"
                        exclusiveTap: true
                        anchors.fill: parent
                        compact: true
                        iconName: "plus"
                        iconSize: 18
                        onClicked: {
                            overlay.windowOwner.closeThemeCardMenu();
                            overlay.windowOwner.newMenuOpen = !overlay.windowOwner.newMenuOpen;
                        }
                    }
                }
            }

            ListView {
                id: themeList
                Text {
                    parent: themeList
                    z: 2
                    visible: overlay.themeLibrary.filteredThemes().length === 0
                    anchors.centerIn: themeList
                    text: "No themes match the search."
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                }
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Theme.scaledSpacing(5)
                model: overlay.themeLibrary.filteredThemes()
                boundsBehavior: Flickable.StopAtBounds
                BloxWheelHandler { flickable: themeList }
                delegate: SettingsThemeCard {
                    required property var modelData
                    width: themeList.width - (themeList.contentHeight > themeList.height ? 10 : 0)
                    pointerCoordinateItem: overlay.frameItem
                    globalPointer: overlay.windowOwner.shelfCursor
                    themeData: overlay.themeLibrary.cardFor(modelData.id)
                    active: modelData.id === overlay.themeLibrary.appliedThemeId
                    selected: modelData.id === overlay.themeLibrary.selectedThemeId
                    menuOpen: overlay.windowOwner.themeCardMenuOpen && overlay.windowOwner.themeCardMenuCardId === modelData.id
                    onContextMenuRequested: (anchor, keyboardOpened) => overlay.windowOwner.openThemeCardMenu(modelData, anchor, keyboardOpened)
                    onMenuDismissRequested: overlay.windowOwner.closeThemeCardMenu(modelData.id)
                    onChosen: themeId => {
                        overlay.windowOwner.closeThemeCardMenu();
                        overlay.windowOwner.selectTheme(themeId);
                        overlay.windowOwner.shelfOpen = false;
                    }
                }
                ScrollBar.vertical: ScrollBar {
                    id: themeScrollbar
                    width: 8
                    policy: themeList.contentHeight > themeList.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    background: Rectangle { radius: Theme.scaledRadius(3); color: Theme.withAlpha(Theme.foreground, 0.04) }
                    contentItem: Rectangle { implicitWidth: 6; radius: Theme.scaledRadius(3); color: themeScrollbar.hovered || themeScrollbar.pressed ? Theme.foreground : Theme.muted }
                }
            }
        }

        MouseArea {
            id: newMenuDismiss
            anchors.fill: parent
            visible: overlay.windowOwner.newMenuOpen
            z: 30
            acceptedButtons: Qt.AllButtons
            onClicked: overlay.windowOwner.newMenuOpen = false
        }
    }

    Rectangle {
        id: newThemeMenuOverlay
        objectName: "new-theme-menu"
        visible: overlay.windowOwner.shelfOpen && overlay.windowOwner.newMenuOpen
        z: 40
        x: themeShelf.x + themeShelf.width - Theme.scaledSpacing(8) - width
        y: themeShelf.y + Theme.scaledSpacing(8) + 38 + Theme.scaledSpacing(4)
        width: 220
        height: 126
        radius: Theme.scaledRadius(9)
        color: Theme.surfaceAlt
        border.color: Theme.border

        // Empty padding and disabled actions must also consume pointer events.
        MouseArea {
            objectName: "new-menu-pointer-shield"
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            preventStealing: true
            onPressed: mouse => mouse.accepted = true
            onClicked: mouse => mouse.accepted = true
            onWheel: wheel => wheel.accepted = true
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(4)
            spacing: Theme.scaledSpacing(2)
            BloxButton {
                id: newFromBlankButton
                objectName: "new-theme-from-blank"
                Layout.fillWidth: true
                text: "From blank"
                elideText: true
                onClicked: {
                    overlay.windowOwner.newMenuOpen = false;
                    overlay.windowOwner.requestThemeAction("new-blank", "");
                }
            }
            BloxButton {
                Layout.fillWidth: true
                text: "From wallpaper"
                elideText: true
                onClicked: {
                    overlay.windowOwner.newMenuOpen = false;
                    overlay.windowOwner.requestThemeAction("new-wallpaper", "");
                }
            }
            BloxButton {
                Layout.fillWidth: true
                text: "Import theme"
                elideText: true
                onClicked: {
                    overlay.windowOwner.newMenuOpen = false;
                    overlay.windowOwner.requestThemeAction("import", "");
                }
            }
        }
    }

    Rectangle {
        id: themeCardMenuOverlay
        objectName: "theme-card-context-menu"
        visible: overlay.windowOwner.themeCardMenuOpen
        z: 51
        x: overlay.windowOwner.themeCardMenuX
        y: overlay.windowOwner.themeCardMenuY
        width: 164
        height: themeCardMenuActions.implicitHeight + Theme.scaledSpacing(8)
        radius: Theme.scaledRadius(10)
        color: Theme.surfaceAlt
        border.color: Theme.border

        // Empty padding and disabled actions must also consume pointer events.
        MouseArea {
            objectName: "theme-menu-pointer-shield"
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            preventStealing: true
            onPressed: mouse => mouse.accepted = true
            onClicked: mouse => mouse.accepted = true
            onWheel: wheel => wheel.accepted = true
        }

        Column {
            id: themeCardMenuActions
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(4)
            spacing: Theme.scaledSpacing(4)

            BloxButton {
                id: themeMenuExportButton
                objectName: "theme-menu-export"
                width: parent.width
                text: "Export"
                onClicked: {
                    const card = overlay.windowOwner.themeCardMenuData;
                    overlay.windowOwner.closeThemeCardMenu();
                    overlay.windowOwner.requestThemeAction("export", card.id);
                }
            }
            BloxButton {
                width: parent.width
                text: "Duplicate"
                onClicked: {
                    const card = overlay.windowOwner.themeCardMenuData;
                    overlay.windowOwner.closeThemeCardMenu();
                    overlay.windowOwner.requestThemeAction("duplicate", card.id);
                }
            }
            BloxButton {
                width: parent.width
                objectName: "theme-menu-rename"
                text: "Rename"
                enabled: overlay.windowOwner.themeCardMenuData.id !== "blox-panel"
                    && String(overlay.windowOwner.themeCardMenuData.meta || "").toLowerCase().indexOf("built in") < 0
                    && String(overlay.windowOwner.themeCardMenuData.meta || "").indexOf("unsaved") < 0
                onClicked: {
                    const card = overlay.windowOwner.themeCardMenuData;
                    overlay.windowOwner.closeThemeCardMenu();
                    overlay.windowOwner.requestThemeAction("rename", card.id);
                }
            }
            BloxButton {
                width: parent.width
                objectName: "theme-menu-delete"
                text: "Delete"
                destructive: true
                enabled: overlay.windowOwner.themeCardMenuData.id !== "blox-panel"
                    && String(overlay.windowOwner.themeCardMenuData.meta || "").toLowerCase().indexOf("built in") < 0
                    && overlay.windowOwner.themeCardMenuData.id !== overlay.themeLibrary.appliedThemeId
                onClicked: {
                    const card = overlay.windowOwner.themeCardMenuData;
                    overlay.windowOwner.closeThemeCardMenu();
                    overlay.windowOwner.requestThemeAction("delete", card.id);
                }
            }
        }
    }
}
