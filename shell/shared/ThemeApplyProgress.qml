import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    required property string themeName
    required property var stages
    required property var targets
    required property real progress
    required property string message
    required property bool showTargets
    required property bool complete
    property string error: ""
    property bool showCloseButton: false
    readonly property int completedTargets: targets.filter((target) => {
        return target.state !== "queued" && target.state !== "active";
    }).length
    readonly property int followUpCount: targets.filter((target) => {
        return target.state === "restart" || target.state === "failed" || target.state === "manual";
    }).length
    readonly property int targetRowCount: Math.ceil(targets.length / 2)

    signal retryRequested(string target)
    signal guideRequested(string target)
    signal closeRequested()

    function stateColour(state) {
        if (state === "done" || state === "applied")
            return Theme.green;

        if (state === "restart")
            return Theme.yellow;

        if (state === "failed" || state === "manual")
            return Theme.red;

        if (state === "active")
            return Theme.blue;

        return Theme.muted;
    }

    function stateIcon(state) {
        if (state === "done" || state === "applied")
            return "check-circle";

        if (state === "restart")
            return "arrows-clockwise";

        if (state === "active")
            return "spinner-gap";

        if (state === "failed")
            return "warning-circle";

        if (state === "manual")
            return "arrow-square-out";

        return "dots-three-circle";
    }

    function resultLabel(target) {
        if (target.message)
            return target.message;

        if (target.state === "active")
            return "Applying…";

        if (target.state === "applied")
            return "Applied";

        if (target.state === "restart")
            return "Restart needed";

        if (target.state === "failed")
            return "Could not apply automatically";

        if (target.state === "manual")
            return "Apply manually";

        return "Queued";
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.scaledSpacing(12)

        RowLayout {
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(2)

                Text {
                    text: root.complete ? root.themeName + " applied" : "Applying " + root.themeName
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 22
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: root.error.length ? root.error : root.message
                    color: root.error.length ? Theme.red : Theme.muted
                    elide: Text.ElideRight
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                }

            }

            Text {
                text: Math.round(root.progress * 100) + "%"
                color: root.complete && !root.error.length ? Theme.green : Theme.blue
                font.family: Theme.bodyFontFamily
                font.pixelSize: 22
                font.bold: true
            }

        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 10
            radius: Theme.scaledRadius(5)
            color: Theme.surfaceAlt

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, root.progress))
                height: parent.height
                radius: parent.radius
                color: root.complete && !root.error.length ? Theme.green : Theme.blue
            }

        }

        Text {
            text: root.showTargets ? root.completedTargets + " of " + root.targets.length + " enabled targets" : root.stages.filter((stage) => {
                return stage.state === "done";
            }).length + " of " + root.stages.length + " stages"
            color: Theme.muted
            font.family: Theme.monoFontFamily
            font.pixelSize: 10
        }

        GridLayout {
            visible: !root.showTargets
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            columns: 2
            columnSpacing: 10
            rowSpacing: 10

            Repeater {
                model: root.stages

                Rectangle {
                    required property var modelData

                    Layout.fillWidth: true
                    Layout.preferredHeight: 82
                    radius: Theme.scaledRadius(8)
                    color: modelData.state === "active" ? Theme.surfaceAlt : Theme.surface
                    border.color: modelData.state === "active" ? Theme.blue : Theme.border
                    border.width: modelData.state === "active" ? 2 : 1

                    Rectangle {
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 30
                        height: 30
                        radius: Theme.scaledRadius(15)
                        color: Theme.withAlpha(root.stateColour(modelData.state), 0.16)

                        PhosphorIcon {
                            id: stageStateIcon

                            anchors.centerIn: parent
                            width: 17
                            height: 17
                            iconName: root.stateIcon(modelData.state)
                            iconColor: root.stateColour(modelData.state)
                            transformOrigin: Item.Center

                            NumberAnimation {
                                target: stageStateIcon
                                property: "rotation"
                                running: modelData.state === "active"
                                loops: Animation.Infinite
                                from: 0
                                to: 360
                                duration: 850
                            }

                        }

                    }

                    Text {
                        x: 52
                        y: 16
                        text: modelData.name
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 14
                        font.bold: true
                    }

                    Text {
                        x: 52
                        y: 45
                        width: parent.width - 64
                        text: modelData.message
                        color: Theme.muted
                        elide: Text.ElideRight
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                }

            }

        }

        ScrollView {
            id: targetScroll

            visible: root.showTargets
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy: contentHeight > availableHeight ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

            GridLayout {
                width: targetScroll.availableWidth
                columns: 2
                columnSpacing: 10
                rowSpacing: 7

                Repeater {
                    model: root.targets

                    Rectangle {
                        required property var modelData

                        Layout.fillWidth: true
                        Layout.preferredHeight: 49
                        radius: Theme.scaledRadius(7)
                        color: modelData.state === "active" ? Theme.surfaceAlt : Theme.surface
                        border.color: modelData.state === "active" ? Theme.blue : Theme.border
                        border.width: modelData.state === "active" ? 2 : 1

                        Rectangle {
                            x: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26
                            height: 26
                            radius: Theme.scaledRadius(13)
                            color: Theme.withAlpha(root.stateColour(modelData.state), 0.16)

                            PhosphorIcon {
                                id: targetStateIcon

                                anchors.centerIn: parent
                                width: 15
                                height: 15
                                iconName: root.stateIcon(modelData.state)
                                iconColor: root.stateColour(modelData.state)
                                transformOrigin: Item.Center

                                NumberAnimation {
                                    target: targetStateIcon
                                    property: "rotation"
                                    running: modelData.state === "active"
                                    loops: Animation.Infinite
                                    from: 0
                                    to: 360
                                    duration: 850
                                }

                            }

                        }

                        Text {
                            x: 45
                            y: 6
                            width: parent.width - 120
                            text: modelData.target.replace("cursor_editor", "cursor")
                            color: Theme.foreground
                            elide: Text.ElideRight
                            font.family: Theme.monoFontFamily
                            font.pixelSize: 12
                            font.bold: true
                        }

                        Text {
                            x: 45
                            y: 26
                            width: parent.width - 120
                            text: root.resultLabel(modelData)
                            color: root.stateColour(modelData.state)
                            elide: Text.ElideRight
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 10
                        }

                        BloxButton {
                            visible: modelData.state === "manual" || root.complete && modelData.state === "failed"
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaledSpacing(8)
                            anchors.verticalCenter: parent.verticalCenter
                            height: 27
                            text: modelData.state === "failed" ? "Retry" : "Guide"
                            onClicked: {
                                if (modelData.state === "failed")
                                    root.retryRequested(modelData.target);
                                else
                                    root.guideRequested(modelData.target);
                            }
                        }

                    }

                }

            }

        }

        RowLayout {
            visible: root.complete
            Layout.fillWidth: true

            Text {
                text: root.followUpCount ? root.followUpCount + " follow-up actions remain" : "Theme application complete"
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 11
            }

            Item {
                Layout.fillWidth: true
            }

            BloxButton {
                visible: root.showCloseButton
                text: "Close"
                onClicked: root.closeRequested()
            }

        }

    }

}
