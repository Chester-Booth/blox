import QtQuick
import QtQuick.Layouts
import qs.shared

Rectangle {
    id: root

    required property var windowOwner
    property string key: ""
    property string target: ""
    property string value: Theme.background
    property string fallbackValue: ""
    property int labelPixelSize: 9
    signal picked(string value)

    implicitWidth: 126
    implicitHeight: 38
    radius: Theme.scaledRadius(9)
    readonly property bool inherited: target.length > 0 && !/^#[0-9a-fA-F]{6}$/.test(value)
    color: !inherited && /^#[0-9a-fA-F]{6}$/.test(value) ? value : Theme.background
    border.color: activeFocus || hover.hovered ? Theme.foreground : Theme.border
    border.width: activeFocus || hover.hovered ? 2 : 1
    activeFocusOnTab: true
    Keys.onReturnPressed: root.openPicker()
    Keys.onSpacePressed: root.openPicker()

    function openPicker() {
        const controller = windowOwner.themeEditorController;
        if (!controller || !controller.candidate)
            return;
        windowOwner.openSettingsColourPicker(key, target, root, fallbackValue || value,
            colour => root.picked(colour));
    }

    Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.scaledSpacing(6)
        text: root.inherited ? "inherit" : root.value
        color: root.windowOwner.themeEditorController
            ? root.windowOwner.themeEditorController.swatchText(parent.color) : Theme.foreground
        font.family: Theme.fontFamily
        font.pixelSize: root.labelPixelSize
        elide: Text.ElideRight
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler { onTapped: root.openPicker() }
}
