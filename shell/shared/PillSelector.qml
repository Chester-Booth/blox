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
    property int focusedIndex: -1
    readonly property var safeOptions: root.options || []
    readonly property int selectedIndex: indexFor(visualId)
    readonly property int tabStopIndex: preferredFocusIndex()

    signal selected(string id)

    function indexFor(id) {
        for (let i = 0; i < safeOptions.length; i++) {
            if ((safeOptions[i].id || "") === id)
                return i;

        }
        return -1;
    }

    function labelFor(id) {
        const index = indexFor(id);
        return index >= 0 && safeOptions.length > index ? safeOptions[index].label || "" : "";
    }

    function optionEnabled(option) {
        return !!option && option.enabled !== false;
    }

    function preferredFocusIndex() {
        if (focusedIndex >= 0 && focusedIndex < safeOptions.length && optionEnabled(safeOptions[focusedIndex]))
            return focusedIndex;

        if (selectedIndex >= 0 && optionEnabled(safeOptions[selectedIndex]))
            return selectedIndex;

        for (let i = 0; i < safeOptions.length; i++) {
            if (optionEnabled(safeOptions[i]))
                return i;
        }

        return -1;
    }

    function activateOption(id) {
        if (!enabled || selectionPending)
            return false;

        const index = indexFor(id);
        if (index < 0 || !optionEnabled(safeOptions[index]) || id === visualId)
            return false;

        if (optimistic) {
            visualId = id;
            selectionPending = true;
            rollback.restart();
        }

        selected(id);
        return true;
    }

    function focusOption(index) {
        const item = optionsRepeater.itemAt(index);
        if (!item || !optionEnabled(safeOptions[index]) || !enabled || selectionPending)
            return false;

        item.forceActiveFocus();
        focusedIndex = index;
        return true;
    }

    function moveFocus(start, delta) {
        for (let step = 1; step <= safeOptions.length; step++) {
            const index = (start + delta * step + safeOptions.length) % safeOptions.length;
            if (optionEnabled(safeOptions[index]))
                return focusOption(index);
        }

        return false;
    }

    function focusFirstOrLast(last) {
        const start = last ? safeOptions.length - 1 : 0;
        const delta = last ? -1 : 1;
        for (let offset = 0; offset < safeOptions.length; offset++) {
            const index = start + delta * offset;
            if (optionEnabled(safeOptions[index]))
                return focusOption(index);
        }

        return false;
    }

    spacing: showHeader ? Theme.scaledSpacing(4) : 0
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
        radius: Theme.scaledRadius(16)
        color: Theme.surface
        border.color: Theme.surfaceAlt
        border.width: 1
        clip: true

        Rectangle {
            x: 3 + Math.max(0, root.selectedIndex) * ((parent.width - 6) / Math.max(1, root.safeOptions.length))
            y: 3
            width: (parent.width - 6) / Math.max(1, root.safeOptions.length)
            height: parent.height - 6
            radius: Theme.scaledRadius(13)
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
            anchors.margins: Theme.scaledSpacing(3)
            spacing: Theme.scaledSpacing(0)

            Repeater {
                id: optionsRepeater

                model: root.safeOptions

                Rectangle {
                    id: optionButton

                    required property int index
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Theme.scaledRadius(13)
                    objectName: "pill-option-" + index
                    color: optionMouse.containsMouse ? Theme.withAlpha(Theme.surfaceAlt, 0.2) : "transparent"
                    border.color: activeFocus ? Theme.blue : "transparent"
                    border.width: activeFocus ? 2 : 0
                    activeFocusOnTab: activeFocus || root.enabled && !root.selectionPending && root.optionEnabled(modelData) && index === root.tabStopIndex
                    Accessible.name: String(modelData.label || "")
                    Accessible.role: Accessible.RadioButton
                    Accessible.checked: (modelData.id || "") === root.visualId
                    Keys.onPressed: event => {
                        if (!root.enabled || root.selectionPending || !root.optionEnabled(modelData))
                            return;

                        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.activateOption(modelData.id || "");
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                            root.moveFocus(index, -1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                            root.moveFocus(index, 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Home) {
                            root.focusFirstOrLast(false);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_End) {
                            root.focusFirstOrLast(true);
                            event.accepted = true;
                        }
                    }
                    onActiveFocusChanged: {
                        if (activeFocus)
                            root.focusedIndex = index;
                        else if (root.focusedIndex === index)
                            root.focusedIndex = -1;
                    }

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
                        enabled: root.enabled && !root.selectionPending && root.optionEnabled(modelData)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: optionButton.forceActiveFocus()
                        onClicked: {
                            root.activateOption(modelData.id || "");
                        }
                    }

                    BloxToolTip {
                        text: String(modelData.label || "")
                        shown: text.length > 0 && optionMouse.containsMouse
                    }

                }

            }

        }

    }

}
