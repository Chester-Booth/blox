import QtQuick
import QtQuick.Controls
import qs.shared

Item {
    id: root

    property alias text: descriptionField.text

    signal tabPressed(var event)
    signal backtabPressed(var event)

    Rectangle {
        anchors.fill: parent
        radius: Theme.scaledRadius(8)
        color: Theme.background
        border.color: Theme.border
    }

    ScrollView {
        id: descriptionScroll
        objectName: "calendar-event-description-scroll"
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(1)
        background: null
        clip: true
        contentWidth: availableWidth

        ScrollBar.horizontal: BloxScrollBar {
            policy: ScrollBar.AlwaysOff
        }

        ScrollBar.vertical: BloxScrollBar {
            objectName: "calendar-event-description-scrollbar"
            parent: descriptionScroll
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            policy: descriptionScroll.contentHeight > descriptionScroll.availableHeight
                ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        }

        TextArea {
            id: descriptionField
            objectName: "calendar-event-description"
            width: descriptionScroll.availableWidth
            height: Math.max(descriptionScroll.availableHeight,
                contentHeight + topPadding + bottomPadding)
            placeholderText: "Add description"
            placeholderTextColor: Theme.muted
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 12
            padding: Theme.scaledSpacing(10)
            wrapMode: TextEdit.Wrap
            background: null
            Keys.onTabPressed: event => root.tabPressed(event)
            Keys.onBacktabPressed: event => root.backtabPressed(event)
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.scaledRadius(8)
        color: "transparent"
        border.color: Theme.border
        z: 1
    }
}
