import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root

    property var event: null
    readonly property string actionDisabledReason: !root.event ? ""
        : root.event.busy ? "Event update in progress."
        : !root.event.can_edit ? String(root.event.capability_reason || "") : ""

    signal editRequested(var event)
    signal colourRequested(var event, string colourId)
    signal deleteRequested(var event)

    popupType: Popup.Item
    modal: true
    focus: true
    dim: false
    width: 174
    padding: Theme.scaledSpacing(8)
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        radius: Theme.scaledRadius(12)
        color: Theme.surface
        border.color: Theme.border
    }

    contentItem: ColumnLayout {
        spacing: Theme.scaledSpacing(8)

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.scaledSpacing(6)

            Item {
                Layout.preferredWidth: 64
                Layout.preferredHeight: 36
                HoverHandler { id: editHover }
                BloxToolTip {
                    objectName: "calendar-event-edit-reason"
                    shown: editHover.hovered && !editButton.enabled && root.actionDisabledReason.length > 0
                    text: root.actionDisabledReason
                }
                BloxButton {
                    id: editButton
                    objectName: "calendar-event-edit"
                    anchors.fill: parent
                    text: "Edit"
                    iconName: "pencil-simple"
                    enabled: root.event && root.event.can_edit && !root.event.busy
                    onClicked: {
                        var selectedEvent = root.event;
                        Qt.callLater(function() {
                            root.close();
                            root.editRequested(selectedEvent);
                        });
                    }
                }
            }

            Item {
                Layout.preferredWidth: 76
                Layout.preferredHeight: 36
                HoverHandler { id: deleteHover }
                BloxToolTip {
                    objectName: "calendar-event-delete-reason"
                    shown: deleteHover.hovered && !deleteButton.enabled && root.actionDisabledReason.length > 0
                    text: root.actionDisabledReason
                }
                BloxButton {
                    id: deleteButton
                    objectName: "calendar-event-delete"
                    anchors.fill: parent
                    text: "Delete"
                    iconName: "trash"
                    destructive: true
                    enabled: root.event && root.event.can_edit && !root.event.busy
                    onClicked: {
                        var selectedEvent = root.event;
                        Qt.callLater(function() {
                            root.close();
                            root.deleteRequested(selectedEvent);
                        });
                    }
                }
            }

        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Theme.border
        }

        GridLayout {
            Layout.alignment: Qt.AlignHCenter
            columns: 5
            rowSpacing: 5
            columnSpacing: 5

            Repeater {
                model: [{
                    "id": "9",
                    "c": "#5484ed"
                }, {
                    "id": "3",
                    "c": "#dbadff"
                }, {
                    "id": "7",
                    "c": "#46d6db"
                }, {
                    "id": "5",
                    "c": "#fbd75b"
                }, {
                    "id": "11",
                    "c": "#dc2127"
                }, {
                    "id": "1",
                    "c": "#a4bdfc"
                }, {
                    "id": "10",
                    "c": "#51b749"
                }, {
                    "id": "2",
                    "c": "#7ae7bf"
                }, {
                    "id": "6",
                    "c": "#ffb878"
                }, {
                    "id": "4",
                    "c": "#ff887c"
                }]

                Item {
                    id: colourTarget
                    required property var modelData
                    property alias reasonTooltip: colourReasonTooltip

                    objectName: "calendar-event-colour-target-" + modelData.id
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24

                    HoverHandler {
                        id: colourHover
                        cursorShape: Qt.PointingHandCursor
                    }

                    BloxToolTip {
                        id: colourReasonTooltip
                        objectName: "calendar-event-colour-reason-" + colourTarget.modelData.id
                        shown: colourHover.hovered && !colourSwatch.enabled && root.actionDisabledReason.length > 0
                        text: root.actionDisabledReason
                    }

                    Rectangle {
                        id: colourSwatch

                        objectName: "calendar-event-colour-" + colourTarget.modelData.id
                        anchors.fill: parent
                        enabled: !!root.event && root.event.can_edit && !root.event.busy
                        activeFocusOnTab: enabled
                        function activate() {
                            if (!enabled) return;
                            const selectedEvent = root.event;
                            const selectedColour = colourTarget.modelData.id;
                            Qt.callLater(() => { root.close(); root.colourRequested(selectedEvent, selectedColour); });
                        }
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                activate();
                                event.accepted = true;
                            }
                        }
                        radius: Theme.scaledRadius(12)
                        color: colourTarget.modelData.c
                        border.color: activeFocus ? Theme.blue : root.event && root.event.colour && root.event.colour.event_id === colourTarget.modelData.id ? Theme.foreground : Theme.withAlpha(Theme.foreground, 0.18)
                        border.width: root.event && root.event.colour && root.event.colour.event_id === colourTarget.modelData.id ? 3 : 1

                        TapHandler {
                            enabled: root.event && root.event.can_edit && !root.event.busy
                            onTapped: colourSwatch.activate()
                        }

                    }

                }

            }

        }

    }

}
