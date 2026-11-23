import QtQuick
import QtQuick.Controls
import ".."

// Completed stdout is ordinary Qt text. Measure wrapped errors at the host's
// independent width limit so content sizing cannot feed height back into width.
NativeView {
    id: root
    readonly property real contentPadding: (settings && settings.padding !== undefined ? settings.padding : 24) * density
    // Spacing density scales padding and gaps, never explicit font size.
    readonly property real textSize: settings && settings.fontSize ? settings.fontSize : 15
    readonly property string textFamily: settings && settings.fontFamily ? settings.fontFamily : bodyFont
    readonly property string outputText: typeof observation.text === "string" ? observation.text : ""
    readonly property string outputError: snapshot && snapshot.error ? snapshot.error : ""
    implicitWidth: Math.max(output.implicitWidth, outputError ? errorMetrics.advanceWidth : 0) + 2 * contentPadding
    implicitHeight: output.implicitHeight + 2 * contentPadding + (outputError ? errorMeasure.implicitHeight + 8 : 0)
    readonly property real errorSpace: outputError ? errorLabel.implicitHeight + 8 : 0
    readonly property real innerWidth: Math.max(0, width - 2 * contentPadding)
    readonly property real innerHeight: Math.max(0, height - 2 * contentPadding)
    contentReady: dataReady && typeof observation.text === "string" && width > 0 && height > 0

    function hasBinding(button) {
        return !!settings && !!settings.actions && !!settings.actions[button];
    }
    function activate(button) {
        if (hasBinding(button)) actionRequested("activate", {button: button});
    }
    function tap(point, button, paddingOnly) {
        const local = root.mapFromItem(null, point.scenePosition.x, point.scenePosition.y);
        if (local.x < 0 || local.y < 0 || local.x >= width || local.y >= height) return;
        if (paddingOnly && local.x >= viewport.x && local.y >= viewport.y
                && local.x < viewport.x + viewport.width && local.y < viewport.y + viewport.height) return;
        const controls = [viewport.ScrollBar.horizontal, viewport.ScrollBar.vertical,
            root.children.find(child => child.objectName === "widgetFullscreenAction")];
        for (const control of controls) {
            if (!control || !control.visible) continue;
            const position = root.mapToItem(control, local.x, local.y);
            if (position.x >= 0 && position.y >= 0 && position.x < control.width && position.y < control.height) return;
        }
        activate(button === Qt.RightButton ? "right" : "left");
    }
    readonly property int actionButtons: (hasBinding("left") ? Qt.LeftButton : Qt.NoButton)
        | (hasBinding("right") ? Qt.RightButton : Qt.NoButton)
    // Passive handlers leave wheel input alone and lose their grab to a Flickable drag.
    TapHandler {
        acceptedButtons: root.actionButtons
        gesturePolicy: TapHandler.DragThreshold
        onTapped: (point, button) => root.tap(point, button, true)
    }
    Keys.onPressed: event => {
        let button = "";
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].indexOf(event.key) >= 0 && event.modifiers === Qt.NoModifier) button = "left";
        else if (event.key === Qt.Key_Menu || event.key === Qt.Key_F10 && event.modifiers === Qt.ShiftModifier) button = "right";
        if (button) {
            event.accepted = true;
            if (!event.isAutoRepeat) root.activate(button);
        } else if (event.key === Qt.Key_Escape) {
            event.accepted = true;
            root.actionRequested("releaseFocus", {});
        } else {
            const step = root.textSize * 2;
            if (event.key === Qt.Key_Down) viewport.contentY = Math.min(Math.max(0, viewport.contentHeight - viewport.height), viewport.contentY + step);
            else if (event.key === Qt.Key_Up) viewport.contentY = Math.max(0, viewport.contentY - step);
            else if (event.key === Qt.Key_Right) viewport.contentX = Math.min(Math.max(0, viewport.contentWidth - viewport.width), viewport.contentX + step);
            else if (event.key === Qt.Key_Left) viewport.contentX = Math.max(0, viewport.contentX - step);
            else if (event.key === Qt.Key_PageDown) viewport.contentY = Math.min(Math.max(0, viewport.contentHeight - viewport.height), viewport.contentY + viewport.height);
            else if (event.key === Qt.Key_PageUp) viewport.contentY = Math.max(0, viewport.contentY - viewport.height);
            else if (event.key === Qt.Key_Home) viewport.contentY = 0;
            else if (event.key === Qt.Key_End) viewport.contentY = Math.max(0, viewport.contentHeight - viewport.height);
            else { event.accepted = false; return; }
            event.accepted = true;
        }
    }

    TextMetrics {
        id: errorMetrics
        text: root.outputError
        font: errorLabel.font
    }
    Text {
        id: errorMeasure
        visible: false
        width: Math.max(1, (root.context && root.context.availableWidth !== undefined
            ? root.context.availableWidth : root.implicitWidth) - 2 * root.contentPadding)
        text: root.outputError
        font: errorLabel.font
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    Flickable {
        id: viewport
        objectName: "commandViewport"
        x: Math.min(root.contentPadding, root.width / 2)
        y: Math.min(root.contentPadding, root.height / 2)
        width: root.innerWidth
        height: Math.max(0, root.innerHeight - root.errorSpace)
        clip: true
        contentWidth: output.implicitWidth
        contentHeight: output.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        TapHandler {
            acceptedButtons: root.actionButtons
            gesturePolicy: TapHandler.DragThreshold
            onTapped: (point, button) => root.tap(point, button, false)
        }
        ScrollBar.horizontal: ScrollBar {
            policy: root.scrollbarMode === "hide" ? ScrollBar.AlwaysOff : root.scrollbarMode === "show" ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
        }
        ScrollBar.vertical: ScrollBar {
            policy: root.scrollbarMode === "hide" ? ScrollBar.AlwaysOff : root.scrollbarMode === "show" ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
        }
        Text {
            id: output
            objectName: "commandText"
            text: root.outputText
            color: root.foreground
            font.family: root.textFamily
            font.pixelSize: root.textSize
            textFormat: Text.PlainText
            wrapMode: Text.NoWrap
            lineHeight: 1
        }
    }
    Text {
        id: errorLabel
        objectName: "commandError"
        x: Math.min(root.contentPadding, root.width / 2)
        y: Math.max(Math.min(root.contentPadding, root.height / 2), root.height - root.contentPadding - height)
        width: root.innerWidth
        height: Math.min(implicitHeight, root.innerHeight)
        clip: true
        visible: root.outputError !== ""
        text: root.outputError
        color: root.muted
        font.family: root.bodyFont
        font.pixelSize: root.baseSize
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
}
