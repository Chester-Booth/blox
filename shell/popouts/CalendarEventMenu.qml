import "../shared"
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root

    property var event: null

    signal editRequested(var event)
    signal colourRequested(var event, string colourId)
    signal deleteRequested(var event)

    popupType: Popup.Item
    modal: true
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

            BloxButton {
                Layout.preferredWidth: 64
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

            BloxButton {
                Layout.preferredWidth: 76
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

                Rectangle {
                    required property var modelData

                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    radius: Theme.scaledRadius(12)
                    color: modelData.c
                    border.color: root.event && root.event.colour && root.event.colour.event_id === modelData.id ? Theme.foreground : Theme.withAlpha(Theme.foreground, 0.18)
                    border.width: root.event && root.event.colour && root.event.colour.event_id === modelData.id ? 3 : 1

                    HoverHandler {
                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        enabled: root.event && root.event.can_edit && !root.event.busy
                        onTapped: {
                            var selectedEvent = root.event;
                            var selectedColour = parent.modelData.id;
                            Qt.callLater(function() {
                                root.close();
                                root.colourRequested(selectedEvent, selectedColour);
                            });
                        }
                    }

                }

            }

        }

    }

}
