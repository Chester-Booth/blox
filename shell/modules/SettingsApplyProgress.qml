import qs.shared as Shared
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
    property string resultTitle: ""
    property bool showCompleteButton: false
    property bool pendingQuickshellReload: false
    property bool enableTargetToggle: false
    property bool targetDetailsExpanded: false
    readonly property bool narrow: width < 620
    readonly property int enabledTargetCount: targets.filter((target) => {
        return target.state !== "unapplied";
    }).length
    readonly property int completedTargets: targets.filter((target) => {
        return target.state !== "queued" && target.state !== "active" && target.state !== "unapplied";
    }).length
    readonly property int unappliedCount: targets.filter((target) => {
        return target.state === "unapplied";
    }).length
    readonly property int followUpCount: targets.filter((target) => {
        return target.state === "restart" || target.state === "failed" || target.state === "manual";
    }).length
    readonly property int targetRowCount: Math.ceil(targets.length / 2)
    implicitHeight: progressContent.implicitHeight

    signal retryRequested(string target)
    signal guideRequested(string target)
    signal closeRequested()
    signal completeRequested()
    signal targetVisibilityRequested(bool expanded)

    function stateColour(state) {
        if (state === "done" || state === "applied")
            return Shared.Theme.green;

        if (state === "restart")
            return Shared.Theme.yellow;

        if (state === "unapplied")
            return Shared.Theme.yellow;

        if (state === "failed" || state === "manual")
            return Shared.Theme.red;

        if (state === "active")
            return Shared.Theme.blue;

        if (state === "unchanged")
            return Shared.Theme.muted;

        return Shared.Theme.muted;
    }

    function stateIcon(state) {
        if (state === "done" || state === "applied")
            return "check-circle";

        if (state === "restart")
            return "arrows-clockwise";

        if (state === "unapplied")
            return "arrows-clockwise";

        if (state === "active")
            return "spinner-gap";

        if (state === "unchanged")
            return "check-circle";

        if (state === "failed")
            return "warning-circle";

        if (state === "manual")
            return "arrow-square-out";

        return "dots-three-circle";
    }

    function resultLabel(target) {
        if (target.state === "unapplied")
            return "Unapplied";

        if (target.state === "manual")
            return "Finish manual setup";

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

        return "Queued";
    }

    ColumnLayout {
        id: progressContent
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.showTargets ? root.height : implicitHeight
        spacing: Shared.Theme.scaledSpacing(12)

        RowLayout {
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Shared.Theme.scaledSpacing(2)

                Text {
                    objectName: "apply-progress-heading"
                    text: root.resultTitle.length ? root.resultTitle : root.error.length ? "Could not apply " + root.themeName : root.complete ? root.themeName + " applied" : "Applying " + root.themeName
                    color: Shared.Theme.foreground
                    font.family: Shared.Theme.bodyFontFamily
                    font.pixelSize: 22
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: root.error.length ? root.error : root.message
                    color: root.error.length ? Shared.Theme.red : Shared.Theme.muted
                    elide: Text.ElideRight
                    font.family: Shared.Theme.bodyFontFamily
                    font.pixelSize: 12
                }

            }

            Text {
                text: Math.round(root.progress * 100) + "%"
                color: root.complete && !root.error.length ? Shared.Theme.green : Shared.Theme.blue
                font.family: Shared.Theme.bodyFontFamily
                font.pixelSize: 22
                font.bold: true
            }

        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 10
            radius: Shared.Theme.scaledRadius(5)
            color: Shared.Theme.surfaceAlt

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, root.progress))
                height: parent.height
                radius: parent.radius
                color: root.complete && !root.error.length ? Shared.Theme.green : Shared.Theme.blue
            }

        }

        RowLayout {
            visible: root.showTargets
            Layout.fillWidth: true

            Text {
                text: root.completedTargets + " of " + root.enabledTargetCount + " enabled targets"
                color: Shared.Theme.muted
                font.family: Shared.Theme.monoFontFamily
                font.pixelSize: 10
            }

            Item {
                Layout.fillWidth: true
            }

            Text {
                visible: root.unappliedCount > 0
                text: root.unappliedCount + " unapplied"
                color: Shared.Theme.yellow
                font.family: Shared.Theme.monoFontFamily
                font.pixelSize: 10
            }

        }

        Text {
            visible: !root.showTargets || root.enableTargetToggle
            text: root.stages.filter((stage) => {
                return stage.state === "done";
            }).length + " of " + root.stages.length + " stages"
            color: Shared.Theme.muted
            font.family: Shared.Theme.monoFontFamily
            font.pixelSize: 10
        }

        GridLayout {
            visible: !root.showTargets || root.enableTargetToggle
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            columns: root.narrow ? 1 : 2
            columnSpacing: 10
            rowSpacing: 10

            Repeater {
                model: root.stages

                Rectangle {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.preferredHeight: 82
                    radius: Shared.Theme.scaledRadius(8)
                    color: modelData.state === "active" ? Shared.Theme.surfaceAlt : Shared.Theme.surface
                    border.color: modelData.state === "active" ? Shared.Theme.blue : Shared.Theme.border
                    border.width: modelData.state === "active" ? 2 : 1

                    Rectangle {
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 30
                        height: 30
                        radius: Shared.Theme.scaledRadius(15)
                        color: Shared.Theme.withAlpha(root.stateColour(modelData.state), 0.16)

                        Shared.PhosphorIcon {
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
                        width: parent.width - (root.enableTargetToggle && index === root.stages.length - 1 && modelData.state !== "queued" ? 142 : 64)
                        text: modelData.name
                        color: Shared.Theme.foreground
                        font.family: Shared.Theme.bodyFontFamily
                        font.pixelSize: 14
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Text {
                        x: 52
                        y: 45
                        width: parent.width - (root.enableTargetToggle && index === root.stages.length - 1 && modelData.state !== "queued" ? 142 : 64)
                        text: modelData.message
                        color: Shared.Theme.muted
                        elide: Text.ElideRight
                        font.family: Shared.Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                    Shared.BloxButton {
                        visible: root.enableTargetToggle && index === root.stages.length - 1 && modelData.state !== "queued"
                        anchors.right: parent.right
                        anchors.rightMargin: Shared.Theme.scaledSpacing(9)
                        anchors.verticalCenter: parent.verticalCenter
                        compact: true
                        text: root.targetDetailsExpanded ? "Hide" : "Show"
                        iconName: root.targetDetailsExpanded ? "caret-up" : "caret-down"
                        onClicked: root.targetVisibilityRequested(!root.targetDetailsExpanded)
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

            ScrollBar.horizontal: Shared.BloxScrollBar {
                policy: ScrollBar.AlwaysOff
            }

            ScrollBar.vertical: Shared.BloxScrollBar {
                policy: targetScroll.contentHeight > targetScroll.availableHeight ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            }

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
                        radius: Shared.Theme.scaledRadius(7)
                        color: modelData.state === "active" ? Shared.Theme.surfaceAlt : Shared.Theme.surface
                        border.color: modelData.state === "active" ? Shared.Theme.blue : Shared.Theme.border
                        border.width: modelData.state === "active" ? 2 : 1

                        Rectangle {
                            x: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26
                            height: 26
                            radius: Shared.Theme.scaledRadius(13)
                            color: Shared.Theme.withAlpha(root.stateColour(modelData.state), 0.16)

                            Shared.PhosphorIcon {
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
                            color: Shared.Theme.foreground
                            elide: Text.ElideRight
                            font.family: Shared.Theme.monoFontFamily
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
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 10
                        }

                        Shared.BloxButton {
                            visible: modelData.state === "manual" || root.complete && modelData.state === "failed"
                            anchors.right: parent.right
                            anchors.rightMargin: Shared.Theme.scaledSpacing(8)
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
            visible: root.complete && root.showCompleteButton
            Layout.fillWidth: true

            Item {
                Layout.fillWidth: true
            }

            Shared.BloxButton {
                visible: root.showCompleteButton
                text: root.pendingQuickshellReload ? "Restart Quickshell" : "Complete"
                onClicked: root.completeRequested()
            }

        }

    }

}
