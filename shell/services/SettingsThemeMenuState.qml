import QtQuick

// Keeps one theme card menu open and returns keyboard focus to its trigger.
QtObject {
    id: root

    property string cardId: ""
    property Item anchor: null
    property bool keyboardOpened: false
    readonly property bool open: cardId.length > 0

    function openMenu(id, trigger, fromKeyboard, firstMenuAction) {
        if (!id || !trigger)
            return false;
        cardId = id;
        anchor = trigger;
        keyboardOpened = fromKeyboard === true;
        if (keyboardOpened && firstMenuAction)
            Qt.callLater(() => firstMenuAction.forceActiveFocus());
        return true;
    }

    function closeMenu(shelfVisible) {
        const returnTarget = keyboardOpened ? anchor : null;
        cardId = "";
        anchor = null;
        keyboardOpened = false;
        if (returnTarget && shelfVisible)
            Qt.callLater(() => returnTarget.forceActiveFocus());
    }

    function positionFor(anchor, anchorSize, menuSize, frameSize) {
        let x = anchor.x + anchorSize.width - menuSize.width;
        let y = anchor.y + anchorSize.height + 4;
        if (y + menuSize.height > frameSize.height - 8)
            y = anchor.y - menuSize.height - 4;
        return {
            x: Math.max(8, Math.min(frameSize.width - menuSize.width - 8, x)),
            y: Math.max(8, Math.min(frameSize.height - menuSize.height - 8, y))
        };
    }
}
