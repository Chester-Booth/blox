import qs.shared
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property bool overlayOpen: false
    property string updateSummary: "Check updates"
    property bool actionBusy: false
    property string actionError: ""
    property var actionAlert: null
    property var powerBlockers: ({"sleep": [], "shutdown": [], "micro": []})
    property int openAnimationDuration: 900

    readonly property bool hasAlert: root.actionAlert !== null || root.actionError.length > 0
    readonly property string alertTone: root.actionAlert && root.actionAlert.tone ? String(root.actionAlert.tone) : "error"
    readonly property color alertToneColor: root.alertTone === "warning" ? Theme.yellow : Theme.red
    readonly property string alertTitle: root.actionAlert && root.actionAlert.title ? String(root.actionAlert.title) : "Power action failed"
    readonly property string alertBody: root.actionAlert && root.actionAlert.body ? String(root.actionAlert.body) : root.actionError
    readonly property var alertItems: root.actionAlert && Array.isArray(root.actionAlert.items) ? root.actionAlert.items : []
    readonly property string alertPrimaryLabel: root.actionAlert && root.actionAlert.primaryLabel ? String(root.actionAlert.primaryLabel) : ""
    readonly property string alertPrimaryKind: root.actionAlert && root.actionAlert.primaryKind ? String(root.actionAlert.primaryKind) : ""
    readonly property color alertPrimaryAccent: root.actionAlert && root.actionAlert.primaryTone === "warning" ? Theme.yellow : Theme.blue
    readonly property string alertSecondaryLabel: root.actionAlert && root.actionAlert.secondaryLabel ? String(root.actionAlert.secondaryLabel) : "Close"

    signal action(string command)
    signal dismissAlert()
    signal close()

    function tileIsBlocked(command) {
        const blockers = root.powerBlockers || ({});
        const microCount = Array.isArray(blockers.micro) ? blockers.micro.length : 0;
        if (command === "sleep" || command === "hibernate") {
            const sleepCount = Array.isArray(blockers.sleep) ? blockers.sleep.length : 0;
            return sleepCount > 0 || microCount > 0;
        }
        if (command === "reboot" || command === "shutdown" || command === "update-shutdown") {
            const shutdownCount = Array.isArray(blockers.shutdown) ? blockers.shutdown.length : 0;
            return shutdownCount > 0 || microCount > 0;
        }
        return false;
    }

    function clearAlert() {
        root.dismissAlert();
    }

    Keys.onEscapePressed: event => {
        if (root.hasAlert) {
            root.clearAlert();
            Qt.callLater(() => {
                if (root.overlayOpen)
                    root.forceActiveFocus(Qt.OtherFocusReason);
            });
            event.accepted = true;
            return;
        }
        root.close();
        event.accepted = true;
    }

    onOverlayOpenChanged: {
        if (overlayOpen)
            Qt.callLater(() => {
                if (root.overlayOpen)
                    root.forceActiveFocus(Qt.OtherFocusReason);
            });
    }

    onHasAlertChanged: {
        if (hasAlert && overlayOpen) {
            Qt.callLater(() => {
                if (root.hasAlert && root.overlayOpen)
                    root.forceActiveFocus(Qt.OtherFocusReason);
            });
        }
    }

    color: "transparent"

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.6)
        opacity: root.overlayOpen ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: root.overlayOpen ? 200 : 300
                easing.type: Easing.InSine
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 160, 820)
        height: Math.min(parent.height - 160, 420)
        spacing: Theme.scaledSpacing(18)

        Text {
            Layout.fillWidth: true
            text: "Power"
            color: Theme.foreground
            opacity: root.overlayOpen ? 1 : 0
            font.family: Theme.bodyFontFamily
            font.pixelSize: 22
            font.bold: true
            horizontalAlignment: Text.AlignHCenter

            Behavior on opacity {
                NumberAnimation {
                    duration: root.openAnimationDuration
                    easing.type: Easing.InCubic
                }
            }
        }

        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 3
            rowSpacing: 12
            columnSpacing: 12

            Repeater {
                id: powerTiles

                model: [{
                    "icon": "󰌾",
                    "label": "Lock",
                    "command": "lock"
                }, {
                    "icon": "󰒲",
                    "label": "Sleep",
                    "command": "sleep"
                }, {
                    "icon": "󰤄",
                    "label": "Hibernate",
                    "command": "hibernate"
                }, {
                    "icon": "󰚰",
                    "label": "Update + shutdown",
                    "command": "update-shutdown",
                    "danger": true
                }, {
                    "icon": "󰜉",
                    "label": "Reboot",
                    "command": "reboot",
                    "danger": true
                }, {
                    "icon": "󰤆",
                    "label": "Shut down",
                    "command": "shutdown",
                    "danger": true
                }]

                Rectangle {
                    id: buttonCard
                    objectName: "power-action-" + modelData.command
                    readonly property bool blocked: root.tileIsBlocked(modelData.command)

                    function show() {
                        hideAnimation.stop();
                        opacity = 0;
                        scale = 0.96;
                        buttonSlide.y = 18;
                        showAnimation.restart();
                    }

                    function hide() {
                        showAnimation.stop();
                        hideAnimation.restart();
                    }

                    radius: Theme.scaledRadius(8)
                    color: powerMouse.containsMouse ? Theme.withAlpha(Theme.surfaceAlt, 0.93) : Theme.withAlpha(Theme.surface, 0.87)
                    border.color: activeFocus ? Theme.blue : modelData.danger ? Theme.red : blocked ? Theme.withAlpha(Theme.yellow, 0.6) : Theme.surfaceAlt
                    border.width: activeFocus ? 2 : 1
                    enabled: root.overlayOpen && !root.actionBusy && !root.hasAlert
                    activeFocusOnTab: !root.hasAlert
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.label
                    Keys.onReturnPressed: activateAction()
                    Keys.onEnterPressed: activateAction()
                    Keys.onSpacePressed: activateAction()

                    function activateAction() {
                        if (!root.overlayOpen || root.hasAlert)
                            return;
                        root.action(modelData.command);
                    }
                    opacity: 0
                    scale: 0.96
                    transformOrigin: Item.Center
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 112
                    Component.onCompleted: {
                        if (root.overlayOpen)
                            show();
                    }

                    Connections {
                        function onOverlayOpenChanged() {
                            if (root.overlayOpen)
                                buttonCard.show();
                            else
                                buttonCard.hide();
                        }

                        target: root
                    }

                    PhosphorIcon {
                        objectName: "power-badge-" + modelData.command
                        visible: buttonCard.blocked
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: Theme.scaledSpacing(10)
                        width: 20
                        height: 20
                        iconName: "warning-circle-fill"
                        iconColor: Theme.yellow
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.scaledSpacing(8)

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.icon
                            color: modelData.danger ? Theme.red : Theme.foreground
                            font.family: Theme.fontFamily
                            font.pixelSize: 32
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.command === "update-shutdown" ? modelData.label + "\n" + root.updateSummary : modelData.label
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 13
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    SequentialAnimation {
                        id: showAnimation

                        PauseAnimation {
                            duration: 200 + index * 64
                        }

                        ParallelAnimation {
                            NumberAnimation {
                                target: buttonCard
                                property: "opacity"
                                from: buttonCard.opacity
                                to: 1
                                duration: 150
                                easing.type: Easing.OutCubic
                            }

                            NumberAnimation {
                                target: buttonCard
                                property: "scale"
                                from: buttonCard.scale
                                to: 1
                                duration: 150
                                easing.type: Easing.OutCubic
                            }

                            NumberAnimation {
                                target: buttonSlide
                                property: "y"
                                from: buttonSlide.y
                                to: 0
                                duration: 150
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    ParallelAnimation {
                        id: hideAnimation

                        NumberAnimation {
                            target: buttonCard
                            property: "opacity"
                            from: buttonCard.opacity
                            to: 0
                            duration: 110
                            easing.type: Easing.InCubic
                        }

                        NumberAnimation {
                            target: buttonCard
                            property: "scale"
                            from: buttonCard.scale
                            to: 0.96
                            duration: 130
                            easing.type: Easing.InCubic
                        }

                        NumberAnimation {
                            target: buttonSlide
                            property: "y"
                            from: buttonSlide.y
                            to: 18
                            duration: 130
                            easing.type: Easing.InCubic
                        }
                    }

                    MouseArea {
                        id: powerMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: buttonCard.activateAction()
                    }

                    transform: Translate {
                        id: buttonSlide

                        y: 18
                    }
                }
            }
        }
    }

    // Centred C2 modal popup (no stripe) over the untouched power grid.
    Item {
        id: alertModalLayer
        objectName: "power-alert-modal"
        anchors.fill: parent
        visible: root.overlayOpen && root.hasAlert
        z: 20

        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.background, 0.56)
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.clearAlert()
        }

        Rectangle {
            id: alertCard
            objectName: "power-alert-card"
            anchors.centerIn: parent
            width: Math.min(400, parent.width - 48)
            height: Math.min(parent.height - 48, alertColumn.implicitHeight + Theme.scaledSpacing(32))
            radius: Theme.scaledRadius(10)
            color: Theme.surface
            border.color: Theme.border
            border.width: 1

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
            }

            ColumnLayout {
                id: alertColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.scaledSpacing(16)
                spacing: Theme.scaledSpacing(10)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(8)

                    PhosphorIcon {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        iconName: "warning-circle-fill"
                        iconColor: root.alertToneColor
                    }

                    Text {
                        objectName: "power-alert-title"
                        Layout.fillWidth: true
                        text: root.alertTitle
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 15
                        font.bold: true
                        elide: Text.ElideRight
                    }
                }

                Text {
                    objectName: "power-action-status"
                    Layout.fillWidth: true
                    visible: root.alertBody.length > 0
                    text: root.alertBody
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                ColumnLayout {
                    visible: root.alertItems.length > 0
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(6)

                    Repeater {
                        model: root.alertItems

                        Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: itemColumn.implicitHeight + Theme.scaledSpacing(16)
                            radius: Theme.scaledRadius(7)
                            color: Theme.surfaceAlt
                            border.color: Theme.border
                            border.width: 1

                            ColumnLayout {
                                id: itemColumn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.scaledSpacing(10)
                                anchors.rightMargin: Theme.scaledSpacing(10)
                                spacing: Theme.scaledSpacing(2)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.scaledSpacing(8)

                                    Text {
                                        Layout.fillWidth: true
                                        text: String(modelData.who || "")
                                        color: Theme.foreground
                                        font.family: Theme.bodyFontFamily
                                        font.pixelSize: 12
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        visible: String(modelData.meta || "").length > 0
                                        text: String(modelData.meta || "")
                                        color: Theme.muted
                                        font.family: Theme.monoFontFamily
                                        font.pixelSize: 10
                                    }
                                }

                                Text {
                                    visible: String(modelData.why || "").length > 0
                                    Layout.fillWidth: true
                                    text: String(modelData.why || "")
                                    color: Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 12
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.scaledSpacing(4)
                    spacing: Theme.scaledSpacing(8)

                    Item { Layout.fillWidth: true }

                    BloxButton {
                        id: alertSecondaryButton
                        objectName: "power-alert-secondary"
                        text: root.alertSecondaryLabel
                        onClicked: root.clearAlert()
                    }

                    BloxButton {
                        id: alertPrimaryButton
                        objectName: "power-alert-primary"
                        visible: root.alertPrimaryLabel.length > 0 && root.alertPrimaryKind.length > 0
                        text: root.alertPrimaryLabel
                        accent: root.alertPrimaryAccent
                        checked: true
                        enabled: !root.actionBusy
                        onClicked: root.action(root.alertPrimaryKind)
                    }
                }
            }
        }
    }
}
