import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

Singleton {
    property alias clipboardWidth: state.clipboardWidth
    property alias clipboardHeight: state.clipboardHeight
    property alias clipboardX: state.clipboardX
    property alias clipboardY: state.clipboardY
    property alias emojiWidth: state.emojiWidth
    property alias emojiHeight: state.emojiHeight
    property alias emojiX: state.emojiX
    property alias emojiY: state.emojiY
    property alias emojiTone: state.emojiTone
    property alias emojiVariants: state.emojiVariants
    property alias recentEmoji: state.recentEmoji
    property alias pinnedEmoji: state.pinnedEmoji
    property alias emojiUsage: state.emojiUsage
    property alias applicationUsage: state.applicationUsage

    FileView {
        path: Quickshell.statePath("launcher-state.json")
        preload: true
        blockLoading: true
        atomicWrites: true
        printErrors: false
        onAdapterUpdated: writeAdapter()

        JsonAdapter {
            id: state

            property int clipboardWidth: 420
            property int clipboardHeight: 500
            property int clipboardX: -1
            property int clipboardY: -1
            property int emojiWidth: 520
            property int emojiHeight: 560
            property int emojiX: -1
            property int emojiY: -1
            property int emojiTone: 0
            property var emojiVariants: ({
            })
            property var recentEmoji: []
            property var pinnedEmoji: []
            property var emojiUsage: ({
            })
            property var applicationUsage: ({
            })
        }

    }

}
