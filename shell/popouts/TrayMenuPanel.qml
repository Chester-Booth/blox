import qs.shared
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Services.SystemTray
import "TrayMenuIcons.js" as MenuIcons

Rectangle {
    id: root

    property var menuHandle: null
    property real maximumHeight: 420
    property int selectedIndex: -1
    property int hoverBlockedIndex: -1
    property point lastPointerPosition: Qt.point(-1, -1)
    property int submenuIndex: -1
    property bool submenuOpensLeft: false
    readonly property real margin: Theme.scaledSpacing(8)
    readonly property alias scroll: menuScroll
    readonly property alias rowCount: entries.count
    readonly property bool pointerHovered: panelHover.hovered

    signal submenuRequested(var entry, int index)
    signal rowHovered(int index)
    signal pointerMoved()
    signal keyboardUsed()
    signal closeRequested()
    signal parentRequested()
    signal triggered()
    signal viewportMoved()

    width: 240
    height: Math.min(maximumHeight, Math.max(44, rows.implicitHeight + 2 * margin))
    radius: Theme.scaledRadius(8)
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1

    function rowAt(index) { return entries.itemAt(index); }
    function rowY(index) {
        const row = rowAt(index);
        return row ? menuScroll.y + row.y - menuScroll.contentY : 0;
    }
    function focusRow(index) {
        const row = rowAt(index);
        if (!row || !row.enabled) return false;
        selectedIndex = index;
        row.forceActiveFocus();
        return true;
    }
    function moveSelection(step) {
        for (let offset = 1; offset <= entries.count; offset++) {
            const start = selectedIndex < 0 ? (step > 0 ? -1 : 0) : selectedIndex;
            const index = (start + step * offset + entries.count * 2) % entries.count;
            if (focusRow(index)) return;
        }
        root.forceActiveFocus();
    }

    Keys.onPressed: event => {
        root.keyboardUsed();
        if (event.key === Qt.Key_Down) moveSelection(1);
        else if (event.key === Qt.Key_Up) moveSelection(-1);
        else if (event.key === Qt.Key_Left) parentRequested();
        else if (event.key === Qt.Key_Escape) closeRequested();
        else return;
        event.accepted = true;
    }

    QsMenuOpener {
        id: opener
        menu: root.menuHandle
    }

    HoverHandler { id: panelHover }

    Flickable {
        id: menuScroll
        objectName: "tray-menu-scroll"
        x: root.margin
        y: root.margin
        width: root.width - 2 * root.margin
        height: Math.max(0, root.height - y - root.margin)
        contentWidth: width
        contentHeight: rows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        activeFocusOnTab: contentHeight > height
        onContentYChanged: root.viewportMoved()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_End) contentY = Math.max(0, contentHeight - height);
            else if (event.key === Qt.Key_Home) contentY = 0;
            else if (event.key === Qt.Key_PageDown) contentY = Math.min(Math.max(0, contentHeight - height), contentY + height);
            else if (event.key === Qt.Key_PageUp) contentY = Math.max(0, contentY - height);
            else return;
            event.accepted = true;
        }
        ScrollBar.vertical: BloxScrollBar {
            id: bar
            objectName: "tray-menu-scrollbar"
            policy: ScrollBar.AsNeeded
            visible: menuScroll.contentHeight > menuScroll.height
        }

        Column {
            id: rows
            width: menuScroll.width - (bar.visible ? bar.width + Theme.scaledSpacing(4) : 0)
            spacing: Theme.scaledSpacing(2)
            Repeater {
                id: entries
                model: opener.children
                Rectangle {
                    id: row
                    objectName: "tray-menu-entry-" + index
                    readonly property var entry: modelData
                    readonly property bool hasSubmenu: !!modelData.hasChildren
                    readonly property bool checkable: modelData.buttonType === QsMenuButtonType.CheckBox
                        || modelData.buttonType === QsMenuButtonType.RadioButton
                    enabled: modelData.enabled && !modelData.isSeparator
                    activeFocusOnTab: enabled
                    width: parent.width
                    height: modelData.isSeparator ? 7 : 28
                    radius: Theme.scaledRadius(5)
                    color: !modelData.isSeparator && root.selectedIndex === index
                        ? Theme.surfaceAlt : "transparent"
                    opacity: modelData.enabled ? 1 : 0.45
                    onActiveFocusChanged: {
                        if (!activeFocus) return;
                        root.selectedIndex = index;
                        if (y < menuScroll.contentY) menuScroll.contentY = y;
                        else if (y + height > menuScroll.contentY + menuScroll.height)
                            menuScroll.contentY = y + height - menuScroll.height;
                    }
                    function activate() {
                        if (!enabled) return;
                        if (hasSubmenu) root.submenuRequested(modelData, index);
                        else {
                            modelData.triggered();
                            if (!checkable) root.triggered();
                        }
                    }
                    Keys.onPressed: event => {
                        root.keyboardUsed();
                        if (event.key === Qt.Key_Right && hasSubmenu) activate();
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) activate();
                        else return;
                        event.accepted = true;
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 1
                        color: Theme.surfaceAlt
                        visible: modelData.isSeparator
                    }
                    PhosphorIcon {
                        id: indicator
                        objectName: "tray-menu-indicator-" + index
                        visible: row.checkable
                        x: 5
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        iconName: modelData.buttonType === QsMenuButtonType.RadioButton
                            ? (modelData.checkState === Qt.Checked ? "radio-button" : "circle")
                            : modelData.checkState === Qt.PartiallyChecked ? "minus-square"
                            : modelData.checkState === Qt.Checked ? "check-square" : "square"
                    }
                    PhosphorIcon {
                        id: actionIcon
                        objectName: "tray-menu-icon-" + index
                        x: row.checkable ? 26 : 5
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        iconName: MenuIcons.iconForEntry(modelData)
                        visible: iconName.length > 0 && !modelData.isSeparator
                    }
                    Image {
                        id: appIcon
                        objectName: "tray-menu-app-icon-" + index
                        x: row.checkable ? 26 : 5
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        source: modelData.icon || ""
                        visible: !actionIcon.visible && source.toString().length > 0 && !modelData.isSeparator
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                    Text {
                        id: label
                        objectName: "tray-menu-label-" + index
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.scaledSpacing(row.checkable && (actionIcon.visible || appIcon.visible) ? 48 : 30)
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.scaledSpacing(row.hasSubmenu ? 24 : 8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.text || ""
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        visible: !modelData.isSeparator
                    }
                    BloxToolTip {
                        objectName: "tray-menu-tooltip-" + index
                        parent: label
                        shown: label.truncated && root.selectedIndex === index
                            && (mouse.containsMouse || row.activeFocus) && !menuScroll.moving
                            && row.y + row.height > menuScroll.contentY
                            && row.y < menuScroll.contentY + menuScroll.height
                        text: label.text
                    }
                    PhosphorIcon {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.scaledSpacing(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        iconName: root.submenuOpensLeft ? "caret-left" : "caret-right"
                        visible: row.hasSubmenu && !modelData.isSeparator
                    }
                    MouseArea {
                        id: mouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: row.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onEntered: root.rowHovered(index)
                        onPositionChanged: mouse => {
                            const point = row.mapToGlobal(mouse.x, mouse.y);
                            if (Math.abs(point.x - root.lastPointerPosition.x) + Math.abs(point.y - root.lastPointerPosition.y) > 1) {
                                const wasBlocked = root.hoverBlockedIndex === index;
                                root.hoverBlockedIndex = -1;
                                root.focusRow(index);
                                root.pointerMoved();
                                if (wasBlocked) hoverDelay.restart();
                            }
                            root.lastPointerPosition = point;
                        }
                        onExited: hoverDelay.stop()
                        onClicked: {
                            hoverDelay.stop();
                            root.focusRow(index);
                            row.activate();
                        }
                        Timer {
                            id: hoverDelay
                            interval: 180
                            onTriggered: {
                                if (mouse.containsMouse && row.enabled && root.selectedIndex === index && root.hoverBlockedIndex !== index)
                                    root.submenuRequested(row.hasSubmenu ? modelData : null, index);
                            }
                        }
                    }
                    Connections {
                        target: root
                        function onRowHovered(hoveredIndex) {
                            if (hoveredIndex === index) hoverDelay.restart();
                            else hoverDelay.stop();
                        }
                    }
                }
            }
        }
    }
}
