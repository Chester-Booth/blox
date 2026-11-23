import QtQuick
import QtQuick.Controls

// The public Controls icon renderer tints the shell's SVGs on software and GPU backends.
Item {
    id: root
    property string name: ""
    property url iconRoot: ""
    property color tint: "#cdd6f4"
    Button {
        anchors.fill: parent
        enabled: false
        Accessible.ignored: true
        background: null
        padding: 0
        display: AbstractButton.IconOnly
        icon.source: root.name && String(root.iconRoot) ? String(root.iconRoot) + root.name + ".svg" : ""
        icon.color: root.tint
        icon.width: width
        icon.height: height
    }
}
