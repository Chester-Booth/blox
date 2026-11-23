import QtQuick
import QtQuick.Layouts
import qs.shared
import qs.services

ColumnLayout {
    id: root
    required property SettingsShellState state

    readonly property var results: state.searchResults()
    readonly property var categoryOrder: {
        const values = [];
        results.forEach(entry => {
            if (values.indexOf(entry.category) < 0)
                values.push(entry.category);
        });
        return values;
    }
    readonly property var visibleCategories: state.activeSearchCategory === "all"
        ? categoryOrder : categoryOrder.filter(category => category === state.activeSearchCategory)

    width: parent ? parent.width : 800
    spacing: Theme.scaledSpacing(14)

    function resultsFor(category) {
        return results.filter(entry => entry.category === category);
    }

    function categoryLabel(category) {
        const match = state.categories.find(entry => entry.id === category);
        return match ? match.label : category;
    }

    function iconForCategory(category) {
        const match = state.categories.find(entry => entry.id === category);
        return match ? match.icon : "squares-four";
    }

    function focusFirstResult() {
        for (let index = 0; index < categoryGroups.count; index++) {
            const group = categoryGroups.itemAt(index);
            if (group && group.focusFirstResult())
                return;
        }
    }

    Text {
        Layout.fillWidth: true
        text: "Search results for \"" + root.state.settingsSearch + "\""
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 22
        font.bold: true
    }

    Flow {
        Layout.fillWidth: true
        spacing: 6

        Repeater {
            model: [{id: "all", label: "All", count: root.results.length}].concat(root.categoryOrder.map(category => ({
                id: category,
                label: root.categoryLabel(category),
                count: root.resultsFor(category).length
            })))

            Rectangle {
                required property var modelData
                objectName: "search-filter-" + modelData.id
                readonly property bool selected: root.state.activeSearchCategory === modelData.id
                activeFocusOnTab: true
                Keys.onReturnPressed: root.state.activeSearchCategory = modelData.id
                Keys.onSpacePressed: root.state.activeSearchCategory = modelData.id
                width: pillContent.implicitWidth + 20
                height: 36
                radius: Theme.scaledRadius(9)
                color: selected ? Theme.withAlpha(Theme.blue, 0.18)
                    : pillHover.hovered ? Theme.surfaceAlt : Theme.surface
                border.color: activeFocus || selected ? Theme.blue : Theme.border
                border.width: activeFocus || selected ? 2 : 1

                Row {
                    id: pillContent
                    anchors.centerIn: parent
                    spacing: 7
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: selected ? Theme.blue : Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        font.bold: selected
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 1
                        height: 13
                        color: selected ? Theme.withAlpha(Theme.blue, 0.65) : Theme.border
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.count
                        color: selected ? Theme.blue : Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                        font.bold: selected
                    }
                }
                HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.state.activeSearchCategory = modelData.id }
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Theme.border
    }

    Text {
        visible: root.results.length === 0
        Layout.fillWidth: true
        Layout.topMargin: 24
        text: "No results"
        color: Theme.muted
        font.family: Theme.bodyFontFamily
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
    }

    Repeater {
        id: categoryGroups
        model: root.visibleCategories

        ColumnLayout {
            id: categoryGroup
            required property string modelData
            property bool expanded: true
            readonly property var categoryResults: root.resultsFor(modelData)
            function focusFirstResult() {
                const first = resultRepeater.itemAt(0);
                if (!first)
                    return false;
                first.forceActiveFocus();
                return true;
            }
            Layout.fillWidth: true
            spacing: 0

            Rectangle {
                objectName: "search-group-" + categoryGroup.modelData
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                activeFocusOnTab: true
                Keys.onReturnPressed: categoryGroup.expanded = !categoryGroup.expanded
                Keys.onSpacePressed: categoryGroup.expanded = !categoryGroup.expanded
                color: categoryHover.hovered ? Theme.surfaceAlt : "transparent"
                radius: Theme.scaledRadius(7)
                border.color: activeFocus ? Theme.blue : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 8
                    PhosphorIcon {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        iconName: root.iconForCategory(categoryGroup.modelData)
                        iconColor: Theme.foreground
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.categoryLabel(categoryGroup.modelData)
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 14
                        font.bold: true
                    }
                    PhosphorIcon {
                        Layout.preferredWidth: 14
                        Layout.preferredHeight: 14
                        iconName: categoryGroup.expanded ? "caret-up" : "caret-down"
                        iconColor: Theme.muted
                    }
                }
                HoverHandler { id: categoryHover }
                TapHandler { onTapped: categoryGroup.expanded = !categoryGroup.expanded }
            }

            Rectangle {
                visible: categoryGroup.expanded
                Layout.fillWidth: true
                Layout.preferredHeight: categoryRows.implicitHeight
                color: Theme.surface
                border.color: Theme.border
                border.width: 1
                radius: Theme.scaledRadius(8)

                ColumnLayout {
                    id: categoryRows
                    width: parent.width
                    spacing: 0
                    Repeater {
                        id: resultRepeater
                        model: categoryGroup.categoryResults
                        Rectangle {
                            required property var modelData
                            objectName: "search-result-" + modelData.category + "-" + modelData.page
                                + "-" + modelData.section + "-" + modelData.label.toLowerCase().replace(/[^a-z0-9]+/g, "-")
                            Layout.fillWidth: true
                            Layout.preferredHeight: 60
                            activeFocusOnTab: true
                            Keys.onReturnPressed: root.state.openSearchResult(modelData)
                            Keys.onSpacePressed: root.state.openSearchResult(modelData)
                            color: resultHover.hovered ? Theme.surfaceAlt : "transparent"
                            radius: Theme.scaledRadius(7)
                            border.color: activeFocus ? Theme.blue : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 3
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.label
                                        color: Theme.foreground
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 12
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: (modelData.page === "advanced" ? "Advanced  ›  " : "") + modelData.detail
                                        color: Theme.muted
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                }
                                PhosphorIcon {
                                    Layout.preferredWidth: 18
                                    Layout.preferredHeight: 18
                                    iconName: "arrow-right"
                                    iconColor: Theme.foreground
                                }
                            }
                            HoverHandler { id: resultHover }
                            TapHandler { onTapped: root.state.openSearchResult(modelData) }
                        }
                    }
                }
            }
        }
    }
}
