import QtQuick
import QtQuick.Controls

Rectangle {
    id: root

    property string value: ""
    property var families: []
    property string query: ""
    property bool suppressEditingFinished: false

    signal accepted(string family)

    function filteredFamilies() {
        const needle = query.trim().toLowerCase();
        const matches = needle ? families.filter((family) => {
            return String(family).toLowerCase().indexOf(needle) >= 0;
        }) : families;
        return matches.slice(0, 100);
    }

    function choose(family) {
        suppressEditingFinished = true;
        editor.text = family;
        query = family;
        accepted(family);
        popup.close();
        editor.forceActiveFocus();
        Qt.callLater(() => {
            suppressEditingFinished = false;
        });
    }

    function resetHighlight() {
        const matches = filteredFamilies();
        const selected = matches.indexOf(value);
        fontList.currentIndex = selected >= 0 ? selected : (matches.length > 0 ? 0 : -1);
        if (fontList.currentIndex >= 0)
            fontList.positionViewAtIndex(fontList.currentIndex, ListView.Contain);

    }

    function moveHighlight(delta, focusList) {
        if (!popup.visible)
            popup.open();

        const count = filteredFamilies().length;
        if (count === 0)
            return ;

        const start = fontList.currentIndex >= 0 ? fontList.currentIndex : 0;
        fontList.currentIndex = Math.max(0, Math.min(count - 1, start + delta));
        fontList.positionViewAtIndex(fontList.currentIndex, ListView.Contain);
        if (focusList) {
            suppressEditingFinished = true;
            fontList.forceActiveFocus();
            Qt.callLater(() => {
                suppressEditingFinished = false;
            });
        }
    }

    function chooseHighlighted() {
        const matches = filteredFamilies();
        if (fontList.currentIndex >= 0 && fontList.currentIndex < matches.length)
            choose(matches[fontList.currentIndex]);

    }

    function dismissList() {
        popup.close();
        editor.text = value;
        query = "";
        editor.forceActiveFocus();
    }

    function openList() {
        editor.text = value;
        query = "";
        editor.forceActiveFocus();
        popup.open();
    }

    implicitHeight: 40
    implicitWidth: 250
    radius: 9
    color: Theme.background
    border.color: editor.activeFocus || popup.visible ? Theme.blue : hover.hovered ? Theme.withAlpha(Theme.foreground, 0.34) : Theme.border
    border.width: editor.activeFocus || popup.visible ? 2 : 1
    onVisibleChanged: {
        if (!visible)
            popup.close();

    }
    onValueChanged: {
        if (!editor.activeFocus)
            editor.text = value;

    }

    TextInput {
        id: editor

        anchors.left: parent.left
        anchors.right: indicator.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: 11
        anchors.rightMargin: 8
        text: root.value
        color: Theme.foreground
        selectionColor: Theme.withAlpha(Theme.blue, 0.5)
        selectedTextColor: Theme.foreground
        font.family: text.length > 0 ? text : Theme.bodyFontFamily
        font.pixelSize: 13
        verticalAlignment: TextInput.AlignVCenter
        selectByMouse: true
        clip: true
        onTextChanged: {
            if (!activeFocus)
                cursorPosition = 0;

        }
        onTextEdited: {
            root.query = text;
            if (!popup.visible)
                popup.open();

            Qt.callLater(() => {
                fontList.currentIndex = root.filteredFamilies().length > 0 ? 0 : -1;
            });
        }
        onEditingFinished: {
            const family = text.trim();
            if (!root.suppressEditingFinished && !popup.visible && family.length > 0 && family !== root.value)
                root.accepted(family);

        }
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Down) {
                root.moveHighlight(1, true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root.moveHighlight(-1, true);
                event.accepted = true;
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && popup.visible) {
                root.chooseHighlighted();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape && popup.visible) {
                root.dismissList();
                event.accepted = true;
            }
        }
    }

    Canvas {
        id: indicator

        property color strokeColour: hover.hovered || popup.visible ? Theme.foreground : Theme.muted

        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 18
        height: 18
        rotation: popup.visible ? 180 : 0
        onStrokeColourChanged: requestPaint()
        onPaint: {
            const context = getContext("2d");
            context.reset();
            context.strokeStyle = strokeColour;
            context.lineWidth = 2.2;
            context.lineCap = "round";
            context.lineJoin = "round";
            context.beginPath();
            context.moveTo(3.5, 6.5);
            context.lineTo(9, 11.5);
            context.lineTo(14.5, 6.5);
            context.stroke();
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openList()
        }

    }

    HoverHandler {
        id: hover

        cursorShape: Qt.IBeamCursor
    }

    TapHandler {
        onTapped: root.openList()
    }

    Popup {
        id: popup

        readonly property real fieldY: root.mapToItem(null, 0, 0).y
        readonly property real availableAbove: Math.max(100, fieldY - 12)
        readonly property real availableBelow: Math.max(100, (root.Window.window ? root.Window.window.height : 860) - fieldY - root.height - 12)
        readonly property bool opensBelow: availableAbove < Math.min(360, fontList.contentHeight + 8) && availableBelow > availableAbove

        popupType: Popup.Item
        // Keep the complete press/release sequence inside the popup overlay so
        // choosing a font cannot activate controls beneath the list.
        modal: true
        dim: false
        y: opensBelow ? root.height + 5 : -height - 5
        width: Math.max(root.width, 330)
        height: Math.min(360, fontList.contentHeight + 8, opensBelow ? availableBelow : availableAbove)
        padding: 4
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: Qt.callLater(root.resetHighlight)

        contentItem: ListView {
            id: fontList

            clip: true
            model: popup.visible ? root.filteredFamilies() : []
            currentIndex: -1
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Down) {
                    root.moveHighlight(1, false);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    root.moveHighlight(-1, false);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.chooseHighlighted();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    root.dismissList();
                    event.accepted = true;
                }
            }

            delegate: Rectangle {
                required property string modelData
                required property int index

                width: fontList.width
                height: 42
                radius: 7
                color: fontHover.hovered || index === fontList.currentIndex || modelData === root.value ? Theme.surfaceAlt : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 11
                    text: modelData
                    color: modelData === root.value ? Theme.blue : Theme.foreground
                    font.family: modelData
                    font.pixelSize: 15
                    elide: Text.ElideRight
                }

                HoverHandler {
                    id: fontHover

                    cursorShape: Qt.PointingHandCursor
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: fontList.currentIndex = index
                    onClicked: root.choose(modelData)
                }

            }

        }

        background: Rectangle {
            radius: 9
            color: Theme.surface
            border.color: Theme.border
        }

    }

}
