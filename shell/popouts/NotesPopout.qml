import qs.shared
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property string title: "notes.md"
    property string body: ""
    property string file: ""
    property int index: 0
    property int count: 1
    property int saveRevision: 0
    property bool saveBusy: false
    property string saveError: ""
    property bool refreshBusy: false
    property string refreshError: ""
    property string statusError: ""
    property bool editing: false
    property real maxPopoutWidth: 680
    property real maxPopoutHeight: 760
    readonly property string fileName: file.substring(file.lastIndexOf("/") + 1)
    readonly property bool generated: ["2-gcal.md", "80-today.md", "81-week.md", "99-gcal.md", "99-gcal_week.md"].indexOf(fileName) >= 0
    readonly property string contentText: editing ? editor.text : body
    property bool headerActionsOnRight: false
    readonly property string actionError: saveError.length > 0 ? saveError : refreshError.length > 0 ? refreshError : statusError
    readonly property int lineCount: Math.max(1, contentText.split("\n").length + (editing ? 1 : 0))
    readonly property real longestLineWidth: {
        const lines = contentText.split("\n");
        let longest = 0;
        for (let i = 0; i < lines.length; i++) longest = Math.max(longest, editorMetrics.advanceWidth(lines[i]))
        return longest;
    }

    signal previous()
    signal next()
    signal refresh(string file)
    signal save(string file, string body)
    signal focusRequested()

    function focusEditor() {
        if (!editing)
            return ;

        focusRequested();
        Qt.callLater(() => {
            return editor.forceActiveFocus();
        });
    }

    onEditingChanged: {
        focusEditor();
    }
    onGeneratedChanged: {
        if (generated)
            editing = false;

    }
    onSaveRevisionChanged: {
        if (saveRevision > 0)
            editing = false;

    }
    // Keep the base width until the text reaches the editor's right padding.
    // After that, grow by the measured line width until the screen limit.
    width: Math.min(maxPopoutWidth, Math.max(320, Math.ceil(longestLineWidth) + 30))
    height: Math.min(maxPopoutHeight, Math.max(96, (editing ? lineCount * 15 : editor.contentHeight) + 74 + (actionError.length > 0 ? 24 : 0)))
    radius: Theme.scaledRadius(8)
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1

    FontMetrics {
        id: editorMetrics

        font.family: Theme.bodyFontFamily
        font.pixelSize: 13
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(10)
        spacing: Theme.scaledSpacing(8)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)
            layoutDirection: root.headerActionsOnRight ? Qt.RightToLeft : Qt.LeftToRight

            Row {
                spacing: Theme.scaledSpacing(8)

                Repeater {
                    model: [{
                        "icon": "‹",
                        "action": "prev"
                    }, {
                        "icon": "›",
                        "action": "next"
                    }, {
                        "icon": root.generated ? (root.refreshBusy ? "…" : "󰑐") : root.editing ? "󰈈" : "󰏫",
                        "action": root.generated ? "refresh" : "edit"
                    }, {
                        "icon": root.editing ? (root.saveBusy ? "…" : "󰆓") : "",
                        "action": "save"
                    }]

                    Rectangle {
                        width: modelData.icon === "" ? 0 : 30
                        height: 30
                        visible: modelData.icon !== ""
                        radius: Theme.scaledRadius(5)
                        color: (root.editing && (modelData.action === "prev" || modelData.action === "next")) ? "transparent" : noteMouse.containsMouse ? Theme.surfaceAlt : Theme.surface
                        border.color: Theme.surfaceAlt
                        border.width: 1
                        opacity: (root.editing && (modelData.action === "prev" || modelData.action === "next")) ? 0.35 : 1

                        Text {
                            anchors.centerIn: parent
                            text: modelData.icon
                            color: Theme.foreground
                            font.family: Theme.fontFamily
                            font.pixelSize: 15
                        }

                        MouseArea {
                            id: noteMouse

                            anchors.fill: parent
                            enabled: !(modelData.action === "save" && root.saveBusy) && !(modelData.action === "refresh" && root.refreshBusy)
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                if (root.editing && (modelData.action === "prev" || modelData.action === "next"))
                                    return ;

                                if (modelData.action === "prev")
                                    root.previous();
                                else if (modelData.action === "next")
                                    root.next();
                                else if (modelData.action === "refresh")
                                    root.refresh(root.file);
                                else if (modelData.action === "save")
                                    root.save(root.file, editor.text);
                                else
                                    root.editing = !root.editing;
                            }
                        }

                    }

                }

            }

            Text {
                Layout.fillWidth: true
                text: root.title + "  " + (root.index + 1) + "/" + root.count
                color: Theme.blue
                font.family: Theme.bodyFontFamily
                font.pixelSize: 15
                font.bold: true
                horizontalAlignment: root.headerActionsOnRight ? Text.AlignLeft : Text.AlignRight
                elide: Text.ElideRight
            }

        }

        Text {
            Layout.fillWidth: true
            visible: root.actionError.length > 0
            text: root.actionError
            color: Theme.red
            font.family: Theme.bodyFontFamily
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.scaledRadius(6)
            color: Theme.surface
            border.color: Theme.surfaceAlt
            border.width: 1
            clip: true

            Flickable {
                id: notesScroll

                function ensureVisible(rect) {
                    if (rect.y < contentY)
                        contentY = rect.y;
                    else if (rect.y + rect.height > contentY + height)
                        contentY = rect.y + rect.height - height;
                    if (rect.x < contentX)
                        contentX = rect.x;
                    else if (rect.x + rect.width > contentX + width)
                        contentX = rect.x + rect.width - width;
                }

                anchors.fill: parent
                anchors.margins: Theme.scaledSpacing(4)
                contentWidth: Math.max(width, editor.contentWidth)
                contentHeight: Math.max(height, editor.contentHeight)
                clip: true

                TextEdit {
                    id: editor

                    width: Math.max(notesScroll.width, contentWidth)
                    height: Math.max(notesScroll.height, contentHeight)
                    text: root.body
                    readOnly: !root.editing
                    selectByMouse: true
                    wrapMode: TextEdit.NoWrap
                    textFormat: root.editing || root.generated ? TextEdit.PlainText : TextEdit.MarkdownText
                    color: Theme.foreground
                    selectedTextColor: Theme.background
                    selectionColor: Theme.blue
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 13
                    focus: root.editing
                    activeFocusOnPress: root.editing
                    onActiveFocusChanged: {
                        if (activeFocus && root.editing)
                            root.focusRequested();

                    }
                    onCursorRectangleChanged: {
                        if (!root.editing)
                            return ;

                        notesScroll.ensureVisible(cursorRectangle);
                    }

                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onTapped: root.focusEditor()
                    }

                }

            }

        }

    }

}
