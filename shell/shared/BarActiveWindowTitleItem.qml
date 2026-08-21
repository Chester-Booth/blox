import QtQuick
import Quickshell.Hyprland

Item {
    id: root

    required property BarItemContext context
    readonly property var activeWindow: Hyprland.activeToplevel
    readonly property bool activeWindowIsHere: activeWindow && activeWindow.workspace && Hyprland.focusedWorkspace && activeWindow.workspace.id === Hyprland.focusedWorkspace.id
    readonly property string title: activeWindowIsHere ? activeWindow.title : ""
    readonly property var itemConfig: Theme.barItems.find((item) => {
        return item.id === "active-window-title";
    }) || ({
    })
    readonly property string titleOrientation: itemConfig.orientation || "inward"
    readonly property bool showFullTitle: itemConfig.titleLength === "full"
    readonly property real preferredTitleExtent: root.context.horizontal ? Math.max(Theme.buttonSize, titleText.implicitWidth + 16) : Math.max(Theme.buttonSize, (staysHorizontal ? titleText.implicitHeight : titleText.implicitWidth) + 16)
    readonly property real configuredTitleExtent: showFullTitle ? preferredTitleExtent : Math.min(root.context.horizontal ? 360 : 240, preferredTitleExtent)
    readonly property bool staysHorizontal: !root.context.horizontal && titleOrientation === "horizontal"
    readonly property real titleRotation: {
        if (root.context.horizontal || staysHorizontal)
            return 0;

        const inward = titleOrientation === "inward";
        return Theme.barPosition === "right" ? (inward ? -90 : 90) : (inward ? 90 : -90);
    }

    clip: staysHorizontal
    implicitWidth: root.context.horizontal ? Math.min(configuredTitleExtent, root.context.maximumExtent) : Theme.buttonSize
    implicitHeight: root.context.horizontal ? Theme.buttonSize : Math.min(configuredTitleExtent, root.context.maximumExtent)

    Text {
        id: titleText

        anchors.centerIn: parent
        width: root.context.horizontal ? Math.max(0, parent.width - 16) : root.staysHorizontal ? Math.max(0, parent.width - 8) : Math.max(0, parent.height - 16)
        text: root.staysHorizontal ? (root.title || "Desktop").replace(/ /g, "\n\n") : root.title || "Desktop"
        color: Theme.foreground
        elide: Text.ElideRight
        wrapMode: root.staysHorizontal ? Text.WrapAnywhere : Text.NoWrap
        lineHeightMode: Text.ProportionalHeight
        lineHeight: root.staysHorizontal ? 0.75 : 1
        font.family: Theme.fontFamily
        font.pixelSize: 14
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        rotation: root.titleRotation
    }

}
