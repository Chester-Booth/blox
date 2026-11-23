import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared

// Left navigation sidebar for Settings: search box with live suggestions,
// category/section tree, feedback text, and active theme card toggle.
Rectangle {
    id: sidebar

    required property var windowOwner
    required property var shellState
    required property var frameItem

    readonly property alias searchField: settingsSearchField
    readonly property alias suggestionPopup: suggestionPopup
    readonly property alias activeThemeCard: activeThemeCard

    color: Theme.surface
    border.color: Theme.border
    border.width: 1
    radius: Theme.scaledRadius(8)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(10)
        spacing: Theme.scaledSpacing(8)

        Item {
            Layout.fillWidth: true
            implicitHeight: settingsSearchField.implicitHeight
            z: 100

            BloxTextField {
                id: settingsSearchField
                objectName: "settings-search"
                anchors.fill: parent
                placeholderText: "Search settings…"
                text: sidebar.shellState.settingsSearch
                trailingInset: allResultsButton.visible ? 34 : 0
                onTextEdited: value => {
                    sidebar.shellState.settingsSearch = value;
                    sidebar.shellState.searchResultsOpen = false;
                    sidebar.shellState.suggestionIndex = 0;
                    if (value.trim().length > 0)
                        suggestionPopup.open();
                    else
                        suggestionPopup.close();
                }
                onAccepted: sidebar.windowOwner.acceptSearch()
                Keys.onEscapePressed: event => {
                    suggestionPopup.close();
                    sidebar.frameItem.forceActiveFocus();
                    event.accepted = true;
                }
                Keys.onDownPressed: event => {
                    const count = sidebar.shellState.suggestionResults().length;
                    if (count > 0) {
                        sidebar.shellState.suggestionIndex = Math.min(count - 1, sidebar.shellState.suggestionIndex + 1);
                        suggestionPopup.open();
                    }
                    event.accepted = true;
                }
                Keys.onUpPressed: event => {
                    sidebar.shellState.suggestionIndex = Math.max(0, sidebar.shellState.suggestionIndex - 1);
                    event.accepted = true;
                }
            }

            Popup {
                id: suggestionPopup
                parent: settingsSearchField
                z: 1000
                x: 0
                y: settingsSearchField.height + Theme.scaledSpacing(5)
                width: settingsSearchField.width
                height: Math.min(248, suggestionColumn.implicitHeight + 12)
                padding: Theme.scaledSpacing(6)
                modal: false
                focus: false
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                background: Rectangle {
                    color: Theme.surface
                    border.color: Theme.blue
                    border.width: 1
                    radius: Theme.scaledRadius(9)
                }
                contentItem: Column {
                    id: suggestionColumn
                    spacing: Theme.scaledSpacing(2)

                    Repeater {
                        model: sidebar.shellState.suggestionResults()
                        Rectangle {
                            required property var modelData
                            required property int index
                            width: suggestionPopup.availableWidth
                            height: 48
                            radius: Theme.scaledRadius(6)
                            color: index === sidebar.shellState.suggestionIndex
                                ? Theme.withAlpha(Theme.blue, 0.16)
                                : suggestionHover.hovered ? Theme.surfaceAlt : "transparent"
                            border.color: index === sidebar.shellState.suggestionIndex ? Theme.blue : "transparent"
                            border.width: index === sidebar.shellState.suggestionIndex ? 1 : 0

                            Column {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.scaledSpacing(8)
                                anchors.rightMargin: Theme.scaledSpacing(8)
                                spacing: Theme.scaledSpacing(2)
                                Text {
                                    width: parent.width
                                    text: modelData.label
                                    color: Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 12
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: sidebar.shellState.categoryLabel(modelData.category) + "  ›  "
                                        + sidebar.shellState.sectionLabel(modelData.category, modelData.section)
                                    color: Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                }
                            }
                            HoverHandler { id: suggestionHover }
                            MouseArea {
                                anchors.fill: parent
                                preventStealing: true
                                propagateComposedEvents: false
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    suggestionPopup.close();
                                    sidebar.windowOwner.openSearchResult(modelData);
                                }
                            }
                        }
                    }

                    Text {
                        width: suggestionPopup.availableWidth
                        height: sidebar.shellState.suggestionResults().length === 0 ? 34 : 0
                        visible: sidebar.shellState.suggestionResults().length === 0
                        text: "No matching settings"
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 10
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Rectangle {
                id: allResultsButton
                objectName: "all-search-results"
                anchors.right: parent.right
                anchors.rightMargin: Theme.scaledSpacing(4)
                anchors.verticalCenter: parent.verticalCenter
                width: 30
                height: 30
                visible: sidebar.shellState.settingsSearch.trim().length > 0
                activeFocusOnTab: visible
                Keys.onReturnPressed: sidebar.windowOwner.openAllSearchResults()
                Keys.onSpacePressed: sidebar.windowOwner.openAllSearchResults()
                radius: Theme.scaledRadius(7)
                color: activeFocus || arrowHover.hovered
                    ? Theme.withAlpha(Theme.foreground, 0.12) : "transparent"
                border.color: activeFocus ? Theme.blue : "transparent"

                PhosphorIcon {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    iconName: "arrow-right"
                    iconColor: Theme.foreground
                }
                HoverHandler { id: arrowHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: sidebar.windowOwner.openAllSearchResults() }
                BloxToolTip {
                    shown: arrowHover.hovered
                    text: sidebar.shellState.searchResults().length === 1
                        ? "Go to result" : "Show all search results"
                    delay: 400
                }
            }
        }

        Flickable {
            id: sidebarScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width - (sidebarScroll.contentHeight > sidebarScroll.height ? 10 : 0)
            contentHeight: sidebarCategories.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            BloxWheelHandler { flickable: sidebarScroll }

            ColumnLayout {
                id: sidebarCategories
                width: sidebarScroll.contentWidth
                spacing: Theme.scaledSpacing(2)

                Repeater {
                    model: sidebar.shellState.visibleCategories()
                    ColumnLayout {
                        id: categoryDelegate
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 38 + nestedSections.height
                        spacing: Theme.scaledSpacing(1)

                        Rectangle {
                            objectName: "category-" + categoryDelegate.modelData.id
                            Layout.fillWidth: true
                            Layout.preferredHeight: 38
                            activeFocusOnTab: true
                            Keys.onReturnPressed: sidebar.shellState.openCategory(categoryDelegate.modelData.id)
                            Keys.onSpacePressed: sidebar.shellState.openCategory(categoryDelegate.modelData.id)
                            radius: Theme.scaledRadius(9)
                            color: sidebar.shellState.category === categoryDelegate.modelData.id
                                ? Theme.withAlpha(Theme.blue, 0.14)
                                : categoryHover.hovered ? Theme.withAlpha(Theme.surfaceAlt, 0.6) : "transparent"
                            border.color: activeFocus || sidebar.shellState.category === categoryDelegate.modelData.id
                                ? Theme.blue : categoryHover.hovered ? Theme.border : "transparent"
                            border.width: activeFocus ? 2 : sidebar.shellState.category === categoryDelegate.modelData.id ? 1 : 0

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.scaledSpacing(8)
                                anchors.rightMargin: Theme.scaledSpacing(8)
                                spacing: Theme.scaledSpacing(9)
                                PhosphorIcon {
                                    Layout.preferredWidth: 18
                                    Layout.preferredHeight: 18
                                    iconName: categoryDelegate.modelData.icon
                                    iconColor: sidebar.shellState.category === categoryDelegate.modelData.id ? Theme.blue : Theme.foreground
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: categoryDelegate.modelData.label
                                    color: sidebar.shellState.category === categoryDelegate.modelData.id ? Theme.blue : Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 14
                                    font.bold: sidebar.shellState.category === categoryDelegate.modelData.id
                                    elide: Text.ElideRight
                                }
                            }
                            HoverHandler { id: categoryHover }
                            TapHandler { onTapped: sidebar.shellState.openCategory(categoryDelegate.modelData.id) }
                        }

                        ColumnLayout {
                            id: nestedSections
                            visible: sidebar.shellState.category === categoryDelegate.modelData.id
                            Layout.fillWidth: true
                            Layout.preferredHeight: visible ? sectionRepeater.count * 31 : 0
                            height: visible ? sectionRepeater.count * 31 : 0
                            implicitHeight: visible ? sectionRepeater.count * 31 : 0
                            Layout.leftMargin: Theme.scaledSpacing(27)
                            spacing: Theme.scaledSpacing(1)

                            Repeater {
                                id: sectionRepeater
                                model: sidebar.shellState.sectionsFor(categoryDelegate.modelData.id)
                                Rectangle {
                                    required property var modelData
                                    objectName: "section-" + categoryDelegate.modelData.id + "-" + modelData.id
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 30
                                    height: 30
                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: sidebar.shellState.openSection(categoryDelegate.modelData.id, modelData.id)
                                    Keys.onSpacePressed: sidebar.shellState.openSection(categoryDelegate.modelData.id, modelData.id)
                                    radius: Theme.scaledRadius(7)
                                    color: sidebar.shellState.section === modelData.id
                                        ? Theme.withAlpha(Theme.blue, 0.10)
                                        : sectionHover.hovered ? Theme.withAlpha(Theme.surfaceAlt, 0.52) : "transparent"
                                    border.color: activeFocus ? Theme.blue : "transparent"
                                    Text {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.scaledSpacing(9)
                                        anchors.rightMargin: Theme.scaledSpacing(5)
                                        text: modelData.label
                                        color: sidebar.shellState.section === modelData.id ? Theme.blue : Theme.foreground
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 11
                                        font.bold: sidebar.shellState.section === modelData.id
                                        elide: Text.ElideRight
                                    }
                                    HoverHandler { id: sectionHover }
                                    TapHandler { onTapped: sidebar.shellState.openSection(categoryDelegate.modelData.id, modelData.id) }
                                }
                            }
                        }
                    }
                }
            }

            ScrollBar.vertical: ScrollBar {
                id: sidebarScrollbar
                width: 8
                policy: sidebarScroll.contentHeight > sidebarScroll.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                background: Rectangle { radius: Theme.scaledRadius(3); color: Theme.withAlpha(Theme.foreground, 0.04) }
                contentItem: Rectangle { implicitWidth: 6; radius: Theme.scaledRadius(3); color: sidebarScrollbar.hovered || sidebarScrollbar.pressed ? Theme.foreground : Theme.muted }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        Text {
            objectName: "settings-feedback"
            Layout.fillWidth: true
            visible: sidebar.windowOwner.feedbackText.length > 0
            text: sidebar.windowOwner.feedbackText
            color: sidebar.windowOwner.settingsController.conflict ? Theme.yellow
                : sidebar.windowOwner.settingsController.error || (sidebar.windowOwner.themeEditorController && sidebar.windowOwner.themeEditorController.errorMessage.length > 0)
                    ? Theme.red : Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 10
            wrapMode: Text.Wrap
        }

        SettingsThemeCard {
            id: activeThemeCard
            objectName: "active-theme-card"
            Layout.fillWidth: true
            compact: true
            themeData: sidebar.windowOwner.currentThemeCard || ({id: "", name: "Theme", palette: []})
            selected: true
            active: true
            toggleOpen: sidebar.windowOwner.shelfOpen
            onChosen: themeId => sidebar.windowOwner.selectTheme(themeId)
            onToggleRequested: {
                sidebar.windowOwner.closeThemeCardMenu();
                sidebar.windowOwner.shelfOpen = !sidebar.windowOwner.shelfOpen;
            }
        }
    }
}
