import QtQuick

Rectangle {
    id: root

    property alias text: editor.text
    property string placeholderText: ""
    property string suffix: ""
    property bool readOnly: false
    readonly property bool hovered: hover.hovered
    readonly property bool editorFocused: editor.activeFocus

    signal editingFinished()
    signal accepted()
    signal textEdited(string value)

    function focusEditor(selectAllText) {
        editor.forceActiveFocus();
        if (selectAllText)
            editor.selectAll();

    }

    implicitHeight: 38
    implicitWidth: 180
    radius: Theme.scaledRadius(9)
    color: readOnly ? Theme.withAlpha(Theme.background, 0.58) : Theme.background
    border.color: editor.activeFocus ? Theme.blue : hovered ? Theme.withAlpha(Theme.foreground, 0.34) : Theme.border
    border.width: editor.activeFocus ? 2 : 1
    opacity: enabled ? 1 : 0.62

    TextInput {
        id: editor

        activeFocusOnTab: root.enabled && !root.readOnly
        anchors.fill: parent
        anchors.leftMargin: Theme.scaledSpacing(11)
        anchors.rightMargin: root.suffix.length > 0 ? suffixLabel.implicitWidth + Theme.scaledSpacing(18) : Theme.scaledSpacing(11)
        color: root.enabled ? Theme.foreground : Theme.muted
        selectionColor: Theme.withAlpha(Theme.blue, 0.5)
        selectedTextColor: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 12
        verticalAlignment: TextInput.AlignVCenter
        readOnly: root.readOnly || !root.enabled
        selectByMouse: true
        clip: true
        onTextChanged: {
            if (!activeFocus)
                cursorPosition = 0;

        }
        onEditingFinished: root.editingFinished()
        onTextEdited: root.textEdited(text)
        Keys.onReturnPressed: (event) => {
            root.editingFinished();
            root.accepted();
            event.accepted = true;
        }
    }

    Text {
        id: suffixLabel

        anchors.right: parent.right
        anchors.rightMargin: Theme.scaledSpacing(10)
        anchors.verticalCenter: parent.verticalCenter
        visible: root.suffix.length > 0
        text: root.suffix
        color: Theme.muted
        font.family: Theme.bodyFontFamily
        font.pixelSize: 11
    }

    Text {
        anchors.fill: editor
        visible: editor.text.length === 0 && !editor.activeFocus
        text: root.placeholderText
        color: Theme.withAlpha(Theme.muted, 0.72)
        font: editor.font
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    HoverHandler {
        id: hover

        cursorShape: root.readOnly ? Qt.ArrowCursor : Qt.IBeamCursor
    }

    TapHandler {
        enabled: root.enabled && !root.readOnly
        onTapped: editor.forceActiveFocus()
    }

}
