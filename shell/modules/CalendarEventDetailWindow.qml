import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

// Floating detail view for a selected calendar event.
FloatingWindow {
    id: details

    required property var controller
    required property var targetScreen
    required property var hostOwner

    screen: targetScreen
    visible: controller.detailsOpen
    title: "Blox Calendar Event Details"
    implicitWidth: 320
    implicitHeight: Math.min(
        420,
        176 + (detailsDescription.visible ? Math.min(120, detailsDescription.contentHeight) : 0) + (detailsLocation.visible ? 24 : 0)
    )
    minimumSize: Qt.size(280, 176)
    color: "transparent"
    onClosed: controller.closeChildren()
    onVisibleChanged: {
        if (visible)
            hostOwner.floatWindow("Blox Calendar Event Details", 320, implicitHeight);
    }

    Shortcut {
        sequence: "Escape"
        onActivated: details.controller.closeChildren()
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(1)
        radius: Theme.scaledRadius(12)
        color: Theme.surface
        border.color: Theme.border
        clip: true
        opacity: details.controller.childPositionReady ? 1 : 0

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(14)
            spacing: Theme.scaledSpacing(10)

            RowLayout {
                Layout.fillWidth: true
                Layout.minimumHeight: 34
                Layout.preferredHeight: 34
                Layout.maximumHeight: 34

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34

                    Text {
                        anchors.fill: parent
                        text: details.controller.activeEvent ? details.controller.activeEvent.title : "Event details"
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 18
                        font.bold: true
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.SizeAllCursor
                        onPressed: details.contentItem.QsWindow.window.startSystemMove()
                    }
                }

                Item {
                    Layout.preferredWidth: 64
                    Layout.maximumWidth: 64
                    Layout.preferredHeight: 34
                    Layout.maximumHeight: 34
                    HoverHandler { id: detailsEditHover }
                    BloxToolTip {
                        objectName: "calendar-details-edit-reason"
                        shown: detailsEditHover.hovered && !detailsEditButton.enabled
                            && details.hostOwner.eventEditDisabledReason(details.controller.activeEvent).length > 0
                        text: details.hostOwner.eventEditDisabledReason(details.controller.activeEvent)
                    }
                    BloxButton {
                        id: detailsEditButton
                        objectName: "calendar-details-edit"
                        anchors.fill: parent
                        text: "Edit"
                        iconName: "pencil-simple"
                        accent: Theme.accent
                        enabled: !!details.controller.activeEvent && details.controller.activeEvent.can_edit && !details.controller.activeEvent.busy
                        onClicked: details.controller.editEvent(details.controller.activeEvent)
                    }
                }

                BloxButton {
                    compact: true
                    iconName: "x"
                    onClicked: details.controller.closeChildren()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.minimumHeight: 1
                Layout.preferredHeight: 1
                Layout.maximumHeight: 1
                color: Theme.border
            }

            RowLayout {
                Layout.fillWidth: true

                PhosphorIcon {
                    Layout.preferredWidth: 17; Layout.preferredHeight: 17
                    Layout.maximumWidth: 17; Layout.maximumHeight: 17
                    iconName: "calendar-blank"
                    iconColor: Theme.accent
                }

                Text {
                    Layout.fillWidth: true
                    text: details.controller.activeEvent
                        ? (details.controller.activeEvent.time.kind === "all_day"
                            ? details.controller.activeEvent.time.start_date
                            : Qt.formatDateTime(details.hostOwner.startDate(), "dddd d MMMM · h:mm ap") + "–" + Qt.formatTime(details.hostOwner.endDate(), "h:mm ap"))
                        : ""
                    color: Theme.accent
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            RowLayout {
                id: detailsLocation
                Layout.fillWidth: true
                visible: !!(details.controller.activeEvent && details.controller.activeEvent.location)

                PhosphorIcon {
                    Layout.preferredWidth: 17; Layout.preferredHeight: 17
                    Layout.maximumWidth: 17; Layout.maximumHeight: 17
                    iconName: "map-pin"
                    iconColor: Theme.muted
                }

                Text {
                    Layout.fillWidth: true
                    text: details.controller.activeEvent ? details.controller.activeEvent.location : ""
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: !!(details.controller.activeEvent && details.controller.activeEvent.recurrence && details.controller.activeEvent.recurrence.summary)

                PhosphorIcon {
                    Layout.preferredWidth: 17; Layout.preferredHeight: 17
                    Layout.maximumWidth: 17; Layout.maximumHeight: 17
                    iconName: "arrows-clockwise"
                    iconColor: Theme.muted
                }

                Text {
                    Layout.fillWidth: true
                    text: details.controller.activeEvent && details.controller.activeEvent.recurrence ? details.controller.activeEvent.recurrence.summary : ""
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                }
            }

            ScrollView {
                id: detailsDescriptionScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true

                Text {
                    id: detailsDescription
                    width: detailsDescriptionScroll.availableWidth
                    text: details.controller.activeEvent ? details.controller.activeEvent.description : ""
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.minimumHeight: implicitHeight
                Layout.preferredHeight: implicitHeight
                Layout.maximumHeight: implicitHeight

                Rectangle {
                    width: 8; height: 8; radius: Theme.scaledRadius(4)
                    color: details.controller.activeEvent && details.controller.activeEvent.colour ? details.controller.activeEvent.colour.display : Theme.accent
                }

                Text {
                    Layout.fillWidth: true
                    text: details.controller.activeEvent && details.controller.activeEvent.calendar ? details.controller.activeEvent.calendar.summary : ""
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                }
            }
        }

        CalendarDeleteConfirmOverlay {
            anchors.fill: parent
            visible: details.controller.confirmDeleteOpen && !details.controller.deleteStandalone
            controller: details.controller
            embedded: true
        }

        WindowResizeHandles { targetWindow: details; baseZ: 90 }
    }
}
