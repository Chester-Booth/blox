import "."
import "../shared"
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

FloatingWindow {
    id: root

    property alias dialogs: fileDialogs

    function focusModal() {
        modal.focusInitial();
    }

    function focusColourPicker() {
        colourPicker.focusEditor();
    }

    title: "Blox Theme Picker"
    implicitWidth: 1320
    implicitHeight: 860
    minimumSize: Qt.size(960, 680)
    visible: pickerController.open && !pickerController.widgetEditModePending
    color: "transparent"
    onClosed: {
        if (pickerController.open && !pickerController.widgetEditModePending)
            pickerController.closePicker();

    }

    ThemePickerController {
        id: pickerController

        host: root
        editorScrollItem: editorScroll
        pickerRootItem: pickerRoot
        barDragProxyItem: barDragProxy
    }

    ThemePickerFileDialogs {
        id: fileDialogs

        controller: pickerController
        parentWindow: root._backingWindow
    }

    Rectangle {
        id: pickerRoot

        anchors.fill: parent
        color: "transparent"
        focus: pickerController.open
        Keys.onEscapePressed: (event) => {
            if (pickerController.colourPickerOpen)
                pickerController.dismissColourPicker();
            else if (pickerController.modalKind.length > 0 && !(pickerController.modalKind === "new" && pickerController.creationBusy) && !(pickerController.modalKind === "progress" && !pickerController.applyProgressComplete))
                pickerController.dismissModal();
            else
                pickerController.requestClose();
            event.accepted = true;
        }
        Keys.onPressed: (event) => {
            if (!pickerController.open || !pickerController.candidateValid || !(event.modifiers & Qt.ControlModifier))
                return ;

            if (event.key === Qt.Key_S) {
                pickerController.saveCandidate("");
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                pickerController.applyCandidate();
                event.accepted = true;
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: 8
            clip: true
            color: Theme.background
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: pickerContent

                anchors.fill: parent
                anchors.margins: 18
                spacing: 12
                enabled: pickerController.modalKind.length === 0 && !pickerController.colourPickerOpen && (!pickerController.busy || pickerController.action === "preview-edit")

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    DragHandler {
                        target: null
                        acceptedButtons: Qt.LeftButton
                        onActiveChanged: {
                            if (active)
                                root.contentItem.QsWindow.window.startSystemMove();

                        }
                    }

                    Label {
                        text: "Theme Picker"
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 24
                        font.bold: true

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.SizeAllCursor
                            onPressed: root.contentItem.QsWindow.window.startSystemMove()
                        }

                    }

                    Label {
                        text: pickerController.dirty ? "UNSAVED" : pickerController.candidateValid ? "VALID" : "CHECKING"
                        color: pickerController.dirty ? Theme.yellow : pickerController.candidateValid ? Theme.green : Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.SizeAllCursor
                            onPressed: root.contentItem.QsWindow.window.startSystemMove()
                        }

                    }

                    BloxButton {
                        text: "Simple"
                        checked: pickerController.editorMode === "overview"
                        onClicked: pickerController.editorMode = "overview"
                    }

                    BloxButton {
                        text: "Advanced"
                        checked: pickerController.editorMode === "advanced"
                        onClicked: pickerController.editorMode = "advanced"
                    }

                    Rectangle {
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 24
                        color: Theme.border
                    }

                    BloxButton {
                        text: "Widgets"
                        checked: pickerController.editorMode === "widgets"
                        onClicked: pickerController.editorMode = "widgets"
                    }

                    Rectangle {
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 24
                        color: Theme.border
                    }

                    BloxButton {
                        iconName: "x"
                        text: "Close"
                        onClicked: pickerController.requestClose()
                    }

                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: Theme.border
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 14

                    ThemePickerLibrary {
                        controller: pickerController
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: Theme.surface
                        border.color: Theme.border

                        Flickable {
                            id: editorScroll

                            anchors.fill: parent
                            anchors.margins: 14
                            clip: true
                            contentWidth: width
                            contentHeight: editorContent.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds

                            WheelHandler {
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onWheel: (event) => {
                                    const pixelDelta = event.pixelDelta.y || 0;
                                    const angleDelta = event.angleDelta.y || 0;
                                    const delta = pixelDelta !== 0 ? pixelDelta : angleDelta / 2;
                                    const maximumContentY = Math.max(editorScroll.originY, editorScroll.originY + editorScroll.contentHeight - editorScroll.height);
                                    editorScroll.contentY = Math.max(editorScroll.originY, Math.min(maximumContentY, editorScroll.contentY - delta * 4));
                                    event.accepted = true;
                                }
                            }

                            ColumnLayout {
                                id: editorContent

                                width: editorScroll.width - 16
                                spacing: 14

                                ThemePickerOverview {
                                    controller: pickerController
                                }

                                ThemePickerAdvanced {
                                    controller: pickerController
                                }

                                ThemePickerWidgets {
                                    controller: pickerController
                                }

                            }

                            ScrollBar.vertical: ScrollBar {
                                id: editorScrollbar

                                policy: ScrollBar.AlwaysOn
                                width: 8
                                interactive: true

                                background: Rectangle {
                                    implicitWidth: 8
                                    radius: 999
                                    color: editorScrollbar.hovered || editorScrollbar.pressed ? Theme.withAlpha(Theme.foreground, 0.09) : Theme.withAlpha(Theme.foreground, 0.04)
                                }

                                contentItem: Rectangle {
                                    implicitWidth: 4
                                    radius: 999
                                    color: editorScrollbar.pressed ? Theme.blue : editorScrollbar.hovered ? Theme.foreground : Theme.muted

                                    Behavior on color {
                                        ColorAnimation {
                                            duration: 110
                                            easing.type: Easing.OutCubic
                                        }

                                    }

                                }

                            }

                        }

                    }

                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: Theme.border
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 5

                    Repeater {
                        model: pickerController.validationErrors

                        Text {
                            required property string modelData

                            Layout.fillWidth: true
                            text: modelData
                            color: Theme.red
                            wrapMode: Text.Wrap
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 11
                        }

                    }

                    Text {
                        visible: pickerController.errorMessage.length > 0
                        Layout.fillWidth: true
                        text: pickerController.errorMessage
                        color: Theme.red
                        wrapMode: Text.Wrap
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                    Text {
                        visible: pickerController.statusMessage.length > 0
                        Layout.fillWidth: true
                        text: pickerController.statusMessage
                        color: Theme.muted
                        elide: Text.ElideRight
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                }

                RowLayout {
                    Layout.fillWidth: true

                    Item {
                        Layout.fillWidth: true
                    }

                    BusyIndicator {
                        running: pickerController.busy
                        visible: pickerController.busy
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                    }

                    BloxButton {
                        text: "Revert"
                        visible: pickerController.candidate && pickerController.dirty && pickerController.baselineJson.length > 0
                        enabled: !pickerController.busy
                        onClicked: pickerController.revertCandidate()
                    }

                    BloxButton {
                        iconName: "floppy-disk"
                        text: "Save"
                        enabled: pickerController.candidate && pickerController.dirty && pickerController.candidateValid && !pickerController.busy
                        onClicked: pickerController.saveCandidate("")
                    }

                    BloxButton {
                        text: "Apply"
                        enabled: pickerController.candidate && pickerController.candidateValid && !pickerController.busy
                        onClicked: pickerController.applyCandidate()
                    }

                }

            }

            Rectangle {
                id: barDragProxy

                property string barItemId: pickerController.barDragItemId

                z: 1000
                visible: pickerController.barDragActive
                radius: 8
                color: Theme.withAlpha(Theme.surface, 0.98)
                border.color: Theme.blue
                border.width: 2
                Drag.active: pickerController.barDragActive
                Drag.source: barDragProxy
                Drag.hotSpot.x: width / 2
                Drag.hotSpot.y: height / 2

                Text {
                    anchors.centerIn: parent
                    text: pickerController.barDragLabel
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                }

            }

            Timer {
                interval: 16
                repeat: true
                running: pickerController.barDragActive
                onTriggered: pickerController.scrollBarDrag()
            }

            ThemePickerModal {
                id: modal

                anchors.fill: parent
                controller: pickerController
            }

            ThemePickerColourPicker {
                id: colourPicker

                anchors.fill: parent
                controller: pickerController
            }

        }

    }

}
