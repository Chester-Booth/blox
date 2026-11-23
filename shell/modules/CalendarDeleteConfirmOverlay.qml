import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Confirmation overlay shared between embedded event detail/editor views and
// the standalone delete confirmation window.
Rectangle {
    id: confirmation

    required property var controller
    property bool embedded: true
    readonly property bool recurring: !!(controller && controller.deleteEvent && controller.deleteEvent.recurrence && controller.deleteEvent.recurrence.master_id)

    color: embedded ? Theme.withAlpha(Theme.background, 0.86) : Theme.surface
    radius: embedded ? 0 : Theme.scaledRadius(12)
    border.color: embedded ? "transparent" : Theme.border
    z: 100

    Rectangle {
        anchors.centerIn: parent
        width: confirmation.embedded ? parent.width - 28 : parent.width
        height: confirmation.embedded
            ? (confirmation.recurring ? 184 : 142) + (confirmation.controller.deleteNotice ? 74 : 0)
            : parent.height
        radius: confirmation.embedded ? Theme.scaledRadius(10) : confirmation.radius
        color: confirmation.embedded ? Theme.surface : "transparent"
        border.color: confirmation.embedded ? Theme.border : "transparent"

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(14)
            spacing: Theme.scaledSpacing(9)

            Text {
                Layout.fillWidth: true
                text: "Delete \"" + (confirmation.controller.deleteEvent ? confirmation.controller.deleteEvent.title : "event") + "\"?"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 14
                font.bold: true
                wrapMode: Text.Wrap
            }

            CalendarNotice {
                Layout.fillWidth: true
                visible: !!confirmation.controller.deleteNotice
                notice: confirmation.controller.deleteNotice
                actionText: confirmation.controller.deleteNotice && confirmation.controller.deleteNotice.retryable ? "Retry" : ""
                onActionTriggered: confirmation.controller.retrySurfaceNotice("delete")
            }

            Text {
                Layout.fillWidth: true
                text: "This cannot be undone here."
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 11
            }

            RowLayout {
                Layout.fillWidth: true
                visible: confirmation.recurring

                BloxButton {
                    Layout.fillWidth: true
                    text: "This event"
                    checked: confirmation.controller.deleteScope === "instance"
                    onClicked: confirmation.controller.deleteScope = "instance"
                }

                BloxButton {
                    Layout.fillWidth: true
                    text: "Following"
                    checked: confirmation.controller.deleteScope === "following"
                    onClicked: confirmation.controller.deleteScope = "following"
                }

                BloxButton {
                    Layout.fillWidth: true
                    text: "Series"
                    checked: confirmation.controller.deleteScope === "series"
                    onClicked: confirmation.controller.deleteScope = "series"
                }
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true

                Item { Layout.fillWidth: true }

                BloxButton {
                    text: "Cancel"
                    enabled: !confirmation.controller.deleteSaving
                    onClicked: confirmation.controller.cancelDelete()
                }

                BloxButton {
                    text: confirmation.controller.deleteSaving ? "Deleting…" : "Delete"
                    enabled: !confirmation.controller.deleteSaving
                        && !(confirmation.controller.deleteNotice && confirmation.controller.deleteNotice.code === "reconciliation_failed")
                    destructive: true
                    onClicked: confirmation.controller.confirmDelete()
                }
            }
        }
    }
}
