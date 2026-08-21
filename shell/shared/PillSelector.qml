import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    property string title: ""
    property string currentId: ""
    property var options: []
    property bool optimistic: false
    property int rollbackDelay: 1500
    property bool showHeader: title.length > 0 || currentText.length > 0
    property color selectedAccent: Theme.yellow
    property string visualId: currentId
    property bool selectionPending: false
    property string currentText: labelFor(visualId)
    readonly property int selectedIndex: indexFor(visualId)

    signal selected(string id)

    function indexFor(id) {
        for (let i = 0; i < options.length; i++) {
            if ((options[i].id || "") === id)
                return i;

        }
        return -1;
    }

    function labelFor(id) {
        const index = indexFor(id);
        return index >= 0 && options.length > index ? options[index].label || "" : "";
    }

    spacing: showHeader ? 4 : 0
    implicitHeight: (showHeader ? header.implicitHeight + spacing : 0) + control.implicitHeight
    opacity: enabled ? 1 : 0.55
    onCurrentIdChanged: {
        rollback.stop();
        selectionPending = false;
        visualId = currentId;
    }

    Timer {
        id: rollback

        interval: root.rollbackDelay
        repeat: false
        onTriggered: {
            root.selectionPending = false;
            root.visualId = root.currentId;
        }
    }

    RowLayout {
        id: header

        Layout.fillWidth: true
        Layout.preferredHeight: root.showHeader ? 14 : 0
        visible: root.showHeader

        Text {
            Layout.fillWidth: true
            text: root.title
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 11
            font.bold: true
            elide: Text.ElideRight
        }

        Text {
            text: root.currentText
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 10
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
        }

    }

    Rectangle {
        id: control

        Layout.fillWidth: true
        Layout.preferredHeight: 32
        implicitHeight: 32
        radius: 16
        color: Theme.surface
        border.color: Theme.surfaceAlt
        border.width: 1
        clip: true

        Rectangle {
            x: 3 + Math.max(0, root.selectedIndex) * ((parent.width - 6) / Math.max(1, root.options.length))
            y: 3
            width: (parent.width - 6) / Math.max(1, root.options.length)
            height: parent.height - 6
            radius: 13
            color: Theme.withAlpha(Theme.surfaceAlt, 0.4)
            visible: root.selectedIndex >= 0

            Behavior on x {
                NumberAnimation {
                    duration: 150
                    easing.type: Easing.OutCubic
                }

            }

        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 3
            spacing: 0

            Repeater {
                model: root.options

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 13
                    color: optionMouse.containsMouse ? Theme.withAlpha(Theme.surfaceAlt, 0.2) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: modelData.icon || modelData.label || ""
                        color: (modelData.id || "") === root.visualId ? root.selectedAccent : Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: 14
                    }

                    MouseArea {
                        id: optionMouse

                        anchors.fill: parent
                        enabled: root.enabled && !root.selectionPending
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const id = modelData.id || "";
                            if (id === root.visualId)
                                return ;

                            if (root.optimistic) {
                                root.visualId = id;
                                root.selectionPending = true;
                                rollback.restart();
                            }
                            root.selected(id);
                        }
                    }

                }

            }

        }

    }

}
