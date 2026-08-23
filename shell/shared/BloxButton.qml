import QtQuick

Rectangle {
    id: buttonRoot

    property string text: ""
    property string iconName: ""
    property int iconSize: 16
    property color accent: Theme.blue
    property bool destructive: false
    property bool checked: false
    property bool compact: false
    property bool elideText: false
    property bool activationEnabled: true
    readonly property bool hovered: hover.hovered
    readonly property bool down: tap.pressed

    signal clicked()
    signal hoverExited()

    implicitHeight: 36
    implicitWidth: compact ? Math.max(34, buttonContent.implicitWidth + 18) : elideText ? 76 : Math.max(76, buttonContent.implicitWidth + 30)
    radius: Theme.scaledRadius(9)
    color: !enabled ? Theme.withAlpha(Theme.surface, 0.42) : down ? Theme.withAlpha(accent, 0.26) : checked ? Theme.withAlpha(accent, 0.18) : hovered ? Theme.surfaceAlt : Theme.surface
    border.color: activeFocus || checked ? accent : hovered ? Theme.withAlpha(Theme.foreground, 0.34) : Theme.border
    border.width: activeFocus || checked ? 2 : 1
    opacity: enabled ? 1 : 0.68
    clip: elideText
    activeFocusOnTab: enabled
    Keys.onSpacePressed: {
        if (enabled && activationEnabled)
            clicked();

    }
    Keys.onReturnPressed: {
        if (enabled && activationEnabled)
            clicked();

    }

    Row {
        id: buttonContent

        anchors.centerIn: parent
        spacing: buttonRoot.iconName.length > 0 && buttonRoot.text.length > 0 ? Theme.scaledSpacing(7) : 0

        PhosphorIcon {
            id: icon

            visible: buttonRoot.iconName.length > 0
            anchors.verticalCenter: parent.verticalCenter
            width: buttonRoot.iconSize
            height: buttonRoot.iconSize
            iconName: buttonRoot.iconName
            iconColor: label.color
        }

        Text {
            id: label

            anchors.verticalCenter: parent.verticalCenter
            width: buttonRoot.elideText ? Math.max(0, buttonRoot.width - 30 - (icon.visible ? icon.width + buttonContent.spacing : 0)) : implicitWidth
            text: buttonRoot.text
            color: !buttonRoot.enabled ? Theme.muted : buttonRoot.destructive ? Theme.red : buttonRoot.checked ? buttonRoot.accent : Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 12
            font.bold: buttonRoot.checked
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }

    }

    HoverHandler {
        id: hover

        cursorShape: buttonRoot.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onHoveredChanged: {
            if (!hovered)
                buttonRoot.hoverExited();

        }
    }

    TapHandler {
        id: tap

        enabled: buttonRoot.enabled && buttonRoot.activationEnabled
        onTapped: buttonRoot.clicked()
    }

}
