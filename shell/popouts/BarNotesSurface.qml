import qs.services
import qs.shared
import QtQuick

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property BarContentController contentController

    HoverPopupWindow {
        id: notesWindow

        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(notesPopout.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(notesPopout.height, root.geometry.openPanelY)
        contentWidth: notesPopout.width
        contentHeight: notesPopout.height
        persistentKeyboardFocus: notesPopout.editing
        open: root.geometry.active && root.surfaceController.openPanel === "todo"
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()
        onVisibleChanged: {
            if (!visible && root.geometry.active)
                root.surfaceController.setInputPopupLocked(false);

        }

        NotesPopout {
            id: notesPopout

            headerActionsOnRight: Theme.barPosition === "right" || ((Theme.barPosition === "top" || Theme.barPosition === "bottom") && root.geometry.openPanelX > root.geometry.screenWidth / 2)
            title: root.contentController.todo.json && root.contentController.todo.json.name ? root.contentController.todo.json.name : "notes.md"
            body: root.contentController.todo.json && root.contentController.todo.json.raw ? root.contentController.todo.json.raw : ""
            file: root.contentController.todo.json && root.contentController.todo.json.file ? root.contentController.todo.json.file : ""
            index: root.contentController.todo.json && root.contentController.todo.json.index !== undefined ? root.contentController.todo.json.index : 0
            count: root.contentController.todo.json && root.contentController.todo.json.count !== undefined ? root.contentController.todo.json.count : 1
            saveRevision: root.contentController.actions.notesSaveRevision
            saveBusy: root.contentController.actions.notesSaveBusy
            saveError: root.contentController.actions.notesSaveError
            statusError: root.contentController.statusError("todo")
            refreshBusy: root.contentController.actions.generatedRefreshBusy
            refreshError: root.contentController.actions.generatedRefreshError
            maxPopoutWidth: root.geometry.screenWidth > 0 ? root.geometry.screenWidth * 0.75 : 680
            maxPopoutHeight: root.geometry.screenHeight > 0 ? root.geometry.screenHeight * 0.75 : 760
            onPrevious: root.contentController.previousTodo()
            onNext: root.contentController.nextTodo()
            onRefresh: root.contentController.actions.refreshGeneratedNotes()
            onSave: (file, body) => {
                root.contentController.actions.saveNotes(file, body);
            }
            onEditingChanged: root.surfaceController.setInputPopupLocked(editing)
            onFocusRequested: {
                root.surfaceController.setInputPopupLocked(true);
                notesWindow.requestKeyboardFocus();
            }
        }

    }

}
