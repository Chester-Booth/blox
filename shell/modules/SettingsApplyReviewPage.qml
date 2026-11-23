import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.shared as Shared

SettingsPageContent {
    id: root

    required property var flowState
    readonly property bool inProgress: ["running", "retrying", "rolling-back"].indexOf(flowState.applyState) >= 0
    readonly property bool stableResult: !inProgress && flowState.applyState !== "ready"
    readonly property bool successResult: ["success", "success-restart", "success-manual", "success-mixed", "success-reload", "retry-success", "rolled-back"].indexOf(flowState.applyState) >= 0
    readonly property bool hasFailures: ["failure-before-write", "failure-cursor", "failure-activate-restored", "failure-activate-retained", "failure-target-rolledback", "failure-target-retained", "retry-failure", "rollback-failure", "restart-failure"].indexOf(flowState.applyState) >= 0
    readonly property bool hasRestart: flowState.applyTargets.some(target => target.state === "restart")
    readonly property bool hasManual: flowState.applyTargets.some(target => target.state === "manual")
    readonly property bool canRollback: flowState.actions.rollBack === true || flowState.recoveryAvailable
    readonly property bool pendingReload: flowState.applyState === "success-reload" || flowState.applyTargets.some(row => row.target === "quickshell" && row.state === "restart")
    readonly property bool hasFollowup: !hasFailures || flowState.actions.retryFailedTargets.length > 0
        || flowState.recoveryAvailable || hasRestart || hasManual || pendingReload
    readonly property bool narrow: width < 620
    property bool showTargetDetails: false

    objectName: "apply-review-page"
    sectionMap: [{id: "apply-review", item: root}]
    searchTargetMap: [{section: "apply-review", label: "Apply & review",
        objectName: root.flowState.guideTarget.length ? "apply-guide-back" : root.inProgress ? "apply-progress" : root.flowState.actions.abandonSuperseded === true ? "apply-dismiss-superseded" : root.stableResult ? "apply-complete" : "apply-start"}]

    function focusPrimaryAction() {
        if (applyButton.visible && applyButton.enabled)
            applyButton.forceActiveFocus();
        else
            focusFirstControl();
    }

    ColumnLayout {
        id: applySection
        Layout.fillWidth: true
        spacing: Shared.Theme.scaledSpacing(12)

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "Apply & review"
                color: Shared.Theme.foreground
                font.family: Shared.Theme.bodyFontFamily
                font.pixelSize: 27
                font.bold: true
            }
            Item { Layout.fillWidth: true }
        }

        Rectangle {
            visible: !root.stableResult && !root.inProgress && !root.flowState.guideTarget.length
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            radius: Shared.Theme.scaledRadius(8)
            color: Shared.Theme.withAlpha(Shared.Theme.yellow, 0.09)
            border.color: Shared.Theme.withAlpha(Shared.Theme.yellow, 0.42)

            RowLayout {
                anchors.fill: parent
                anchors.margins: Shared.Theme.scaledSpacing(12)
                spacing: Shared.Theme.scaledSpacing(10)
                Shared.PhosphorIcon { Layout.preferredWidth: 19; Layout.preferredHeight: 19; iconName: "file-text"; iconColor: Shared.Theme.yellow }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    spacing: 3
                    Text {
                        Layout.fillWidth: true
                        text: root.flowState.generatedFilesTitle
                        color: Shared.Theme.foreground
                        font.family: Shared.Theme.bodyFontFamily
                        font.pixelSize: 12
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.flowState.generatedFilesDetail
                        color: Shared.Theme.muted
                        font.family: Shared.Theme.bodyFontFamily
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                Item { Layout.fillWidth: true }
                Shared.BloxButton {
                    text: "View files"
                    compact: true
                    Layout.alignment: Qt.AlignRight
                    onClicked: {
                        root.windowOwner.navigateTo("targets", "landing", "generated-files");
                    }
                }
            }
        }

        RowLayout {
            visible: !root.stableResult && !root.inProgress && !root.flowState.guideTarget.length
            Layout.fillWidth: true
            spacing: Shared.Theme.scaledSpacing(8)
            Shared.BloxButton {
                id: applyButton
                objectName: "apply-start"
                text: "Apply " + root.flowState.selectedThemeName
                iconName: "check-circle"
                accent: Shared.Theme.blue
                enabled: root.windowOwner && root.flowState.dirty && root.flowState.reviewTargetCount > 0 && !root.windowOwner.settingsMutationPending
                onClicked: root.flowState.startApply()
            }
            Shared.BloxButton {
                objectName: "apply-discard-edits"
                enabled: root.windowOwner && root.windowOwner.hasUnappliedChanges === true && !root.windowOwner.settingsMutationPending
                text: "Discard edits"
                iconName: "arrow-counter-clockwise"
                destructive: true
                onClicked: root.flowState.discardEdits()
            }
            Text {
                visible: !root.flowState.reviewTargetCount
                text: "Select targets in Targets before applying."
                color: Shared.Theme.yellow
                font.family: Shared.Theme.bodyFontFamily
                font.pixelSize: 10
            }
            Item { Layout.fillWidth: true }
        }
    }

    ColumnLayout {
        id: progressSection
        visible: root.inProgress && !root.flowState.guideTarget.length
        Layout.fillWidth: true
        Layout.preferredHeight: 492
        spacing: Shared.Theme.scaledSpacing(10)

        Shared.ThemeApplyProgress {
            objectName: "apply-progress"
            Layout.fillWidth: true
            Layout.fillHeight: true
            themeName: root.flowState.selectedThemeName
            stages: root.flowState.applyStages
            targets: root.flowState.applyTargets
            progress: root.flowState.applyProgress / 100
            message: root.flowState.applyState === "retrying" ? "Retrying failed targets only" : root.flowState.applyState === "rolling-back" ? "Restoring the previous generation and loaders" : "Generating target files and applying saved targets"
            showTargets: false
            complete: false
            error: ""
        }

    }

    ColumnLayout {
        id: resultSection
        visible: root.stableResult && !root.flowState.guideTarget.length
        Layout.fillWidth: true
        spacing: Shared.Theme.scaledSpacing(10)

        SettingsApplyProgress {
            resultTitle: root.flowState.applyState === "rolled-back" ? "Previous state restored" : ""
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            themeName: root.flowState.selectedThemeName
            stages: root.flowState.applyStages
            targets: root.flowState.applyTargets
            progress: root.flowState.applyProgress / 100
            message: root.flowState.applyMessage
            showTargets: false
            complete: true
            error: root.hasFailures ? root.flowState.failureMessage : ""
            enableTargetToggle: true
            targetDetailsExpanded: root.showTargetDetails
            onTargetVisibilityRequested: expanded => root.showTargetDetails = expanded
        }

        Rectangle {
            visible: root.showTargetDetails
            Layout.fillWidth: true
            Layout.preferredHeight: targetDetailsColumn.implicitHeight + 18
            radius: Shared.Theme.scaledRadius(8)
            color: Shared.Theme.surface
            border.color: Shared.Theme.border

            ColumnLayout {
                id: targetDetailsColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Shared.Theme.scaledSpacing(9)
                spacing: Shared.Theme.scaledSpacing(6)

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "Target results"
                        color: Shared.Theme.foreground
                        font.family: Shared.Theme.bodyFontFamily
                        font.pixelSize: 11
                        font.bold: true
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.narrow ? 1 : 2
                    columnSpacing: Shared.Theme.scaledSpacing(7)
                    rowSpacing: Shared.Theme.scaledSpacing(6)
                    Repeater {
                        model: root.flowState.applyTargets
                        Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 39
                            radius: Shared.Theme.scaledRadius(6)
                            color: Shared.Theme.background
                            border.color: Shared.Theme.border
                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: Shared.Theme.scaledSpacing(6)
                                spacing: Shared.Theme.scaledSpacing(6)
                                Shared.PhosphorIcon { Layout.preferredWidth: 15; Layout.preferredHeight: 15; iconName: root.statusIcon(modelData.state); iconColor: root.statusColour(modelData.state) }
                                Text { Layout.fillWidth: true; Layout.minimumWidth: 0; text: root.targetLabel(modelData.target); color: Shared.Theme.foreground; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 9; elide: Text.ElideRight }
                                Text { Layout.preferredWidth: 104; horizontalAlignment: Text.AlignRight; text: root.statusLabel(modelData.state); color: root.statusColour(modelData.state); font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 9; elide: Text.ElideRight }
                            }
                        }
                    }
                }

                Text {
                    visible: root.hasFailures
                    Layout.fillWidth: true
                    activeFocusOnTab: visible
                    Keys.onReturnPressed: root.flowState.copyApplyError()
                    Keys.onSpacePressed: root.flowState.copyApplyError()
                    text: "Error details: " + root.flowState.failureMessage + "  ·  Copy error details"
                    color: activeFocus ? Shared.Theme.blue : Shared.Theme.muted
                    font.family: Shared.Theme.monoFontFamily
                    font.pixelSize: 9
                    wrapMode: Text.Wrap
                    TapHandler { onTapped: root.flowState.copyApplyError() }
                }
            }
        }


        Text {
            objectName: "apply-followup-heading"
            visible: root.hasFollowup
            text: root.hasFailures ? "What to do" : "What you need to do"
            color: Shared.Theme.foreground
            font.family: Shared.Theme.bodyFontFamily
            font.pixelSize: 16
            font.bold: true
        }

        ColumnLayout {
            visible: root.hasFollowup
            Layout.fillWidth: true
            spacing: Shared.Theme.scaledSpacing(7)

            Rectangle {
                visible: root.hasFailures && root.flowState.actions.retryFailedTargets.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: 84
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.withAlpha(Shared.Theme.red, 0.42)

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    spacing: Shared.Theme.scaledSpacing(9)
                    Shared.PhosphorIcon { Layout.preferredWidth: 20; Layout.preferredHeight: 20; iconName: "warning-circle"; iconColor: Shared.Theme.red }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3
                        Text {
                            text: "Retry failed targets"
                            color: Shared.Theme.foreground
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 12
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.flowState.failureSummary
                            color: Shared.Theme.muted
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 10
                            wrapMode: Text.Wrap
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Shared.BloxButton {
                        text: "Retry failed targets"
                        iconName: "arrows-clockwise"
                        Layout.alignment: Qt.AlignRight
                        onClicked: root.flowState.retryFailedTargets()
                    }
                }
            }

            Rectangle {
                visible: root.flowState.recoveryAvailable
                Layout.fillWidth: true
                Layout.preferredHeight: 76
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.withAlpha(Shared.Theme.yellow, 0.46)

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    spacing: Shared.Theme.scaledSpacing(9)
                    Shared.PhosphorIcon { Layout.preferredWidth: 20; Layout.preferredHeight: 20; iconName: "arrow-counter-clockwise"; iconColor: Shared.Theme.yellow }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3
                        Text { text: "Apply recovery is required"; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 12; font.bold: true }
                        Text { text: "Restore the previous state before continuing."; color: Shared.Theme.muted; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 10; wrapMode: Text.Wrap }
                    }
                    Item { Layout.fillWidth: true }
                    Shared.BloxButton {
                        text: "Roll back"
                        iconName: "arrow-counter-clockwise"
                        destructive: true
                        Layout.alignment: Qt.AlignRight
                        onClicked: root.flowState.rollBackApply()
                    }
                }
            }

            Rectangle {
                visible: root.hasRestart
                Layout.fillWidth: true
                Layout.preferredHeight: 57
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    spacing: Shared.Theme.scaledSpacing(8)
                    Shared.PhosphorIcon { Layout.preferredWidth: 18; Layout.preferredHeight: 18; iconName: "arrows-clockwise"; iconColor: Shared.Theme.yellow }
                    Text { Layout.fillWidth: true; text: "Restart " + root.targetsFor("restart").join(", "); color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 11; wrapMode: Text.Wrap }
                    Text { text: "Restart needed"; color: Shared.Theme.yellow; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 9 }
                }
            }

            Rectangle {
                visible: root.hasManual
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    spacing: Shared.Theme.scaledSpacing(8)
                    Shared.PhosphorIcon { Layout.preferredWidth: 18; Layout.preferredHeight: 18; iconName: "arrow-square-out"; iconColor: Shared.Theme.red }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text { text: "Finish manual setup"; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 11; font.bold: true }
                        Text { Layout.fillWidth: true; text: root.targetsFor("manual").join(", ") + (root.flowState.applyTargets.some(entry => entry.target === "stylus" && entry.state === "manual") ? " · install or reinstall the generated user style" : " · install the generated files"); color: Shared.Theme.muted; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 10; wrapMode: Text.Wrap }
                    }
                    Item { Layout.fillWidth: true }
                    Shared.BloxButton {
                        text: "Guide"
                        compact: true
                        Layout.alignment: Qt.AlignRight
                        Layout.preferredWidth: 68
                        Layout.minimumWidth: 68
                        Layout.maximumWidth: 68
                        onClicked: root.flowState.openApplyGuide(root.flowState.applyTargets.find(entry => entry.state === "manual").target)
                    }
                }
            }

            Rectangle {
                visible: root.pendingReload
                Layout.fillWidth: true
                Layout.preferredHeight: 58
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    spacing: Shared.Theme.scaledSpacing(8)
                    Shared.PhosphorIcon { Layout.preferredWidth: 18; Layout.preferredHeight: 18; iconName: "arrows-clockwise"; iconColor: Shared.Theme.blue }
                    Text { Layout.fillWidth: true; text: "Restart Quickshell to use the new shell theme"; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 11; wrapMode: Text.Wrap }
                }
            }

            Rectangle {
                visible: !root.hasFailures && !root.hasRestart && !root.hasManual && !root.pendingReload
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    Shared.PhosphorIcon { Layout.preferredWidth: 17; Layout.preferredHeight: 17; iconName: "check-circle"; iconColor: Shared.Theme.green }
                    Text { Layout.fillWidth: true; text: "No follow-up needed"; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 11 }
                }
            }
        }


        RowLayout {
            Layout.fillWidth: true
            spacing: Shared.Theme.scaledSpacing(8)
            Item { Layout.fillWidth: true }
            Shared.BloxButton {
                visible: root.flowState.canRetryApply === true
                objectName: "apply-retry"
                text: "Retry"
                iconName: "arrows-clockwise"
                onClicked: root.flowState.retryApply()
            }
            Shared.BloxButton {
                visible: root.canRollback && !root.flowState.recoveryAvailable
                text: "Roll back"
                iconName: "arrow-counter-clockwise"
                destructive: true
                onClicked: root.flowState.rollBackApply()
            }
            Shared.BloxButton {
                visible: root.flowState.actions.keepSuccessfulChanges
                text: "Keep successful changes"
                onClicked: root.flowState.keepSuccessfulChanges()
            }
            Shared.BloxButton {
                visible: root.flowState.actions.abandonSuperseded === true
                objectName: "apply-dismiss-superseded"
                text: "Dismiss superseded Apply"
                onClicked: root.flowState.abandonSupersededApply()
            }
            Shared.BloxButton {
                enabled: root.flowState.actions.abandonSuperseded !== true && !root.flowState.actions.keepSuccessfulChanges && root.flowState.actions.retryFailedTargets.length === 0
                    && !(root.flowState.recoveryAvailable && !root.flowState.journalReleased)
                objectName: "apply-complete"
                text: root.pendingReload ? "Restart Quickshell" : "Done"
                iconName: root.pendingReload ? "arrows-clockwise" : "check-circle"
                accent: root.pendingReload ? Shared.Theme.blue : Shared.Theme.foreground
                checked: root.pendingReload
                onClicked: {
                    if (root.pendingReload)
                        root.flowState.completeQuickshellReload();
                    root.flowState.finishApply();
                }
            }
        }
    }

    ColumnLayout {
        id: guideSection
        visible: root.flowState.guideTarget.length > 0
        Layout.fillWidth: true
        spacing: Shared.Theme.scaledSpacing(10)

        RowLayout {
            Layout.fillWidth: true
            Shared.BloxButton {
                objectName: "apply-guide-back"
                text: "Back to result"
                iconName: "arrow-left"
                compact: true
                onClicked: root.flowState.guideTarget = ""
            }
            Item { Layout.fillWidth: true }
        }

        Text {
            text: "Stylus guide"
            color: Shared.Theme.foreground
            font.family: Shared.Theme.bodyFontFamily
            font.pixelSize: 23
            font.bold: true
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 168
            radius: Shared.Theme.scaledRadius(9)
            color: Shared.Theme.surface
            border.color: Shared.Theme.border
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Shared.Theme.scaledSpacing(14)
                spacing: Shared.Theme.scaledSpacing(8)
                Text {
                    text: "Install the generated user style"
                    color: Shared.Theme.foreground
                    font.family: Shared.Theme.bodyFontFamily
                    font.pixelSize: 14
                    font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    text: "Open the file in a browser with Stylus. Choose Install style the first time, or Reinstall style if it is already listed. Remove older duplicate Blox Web Theme entries."
                    color: Shared.Theme.muted
                    font.family: Shared.Theme.bodyFontFamily
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                RowLayout {
                    Layout.fillWidth: true
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        radius: Shared.Theme.scaledRadius(5)
                        color: Shared.Theme.background
                        border.color: Shared.Theme.border
                        Text {
                            anchors.fill: parent
                            anchors.margins: Shared.Theme.scaledSpacing(7)
                            text: root.flowState.guidePath
                            color: Shared.Theme.muted
                            font.family: Shared.Theme.monoFontFamily
                            font.pixelSize: 9
                            elide: Text.ElideMiddle
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Shared.BloxButton { text: "Copy path"; compact: true; onClicked: root.flowState.copyGuidePath() }
                    Shared.BloxButton { text: "Download file"; compact: true; onClicked: root.windowOwner.downloadGuideFile(root.flowState.guideTarget) }
                }
            }
        }
    }

    function targetsFor(state) {
        return flowState.applyTargets.filter(target => target.state === state).map(target => root.targetLabel(target.target))
    }

    function targetLabel(target) {
        if (target === "cursor_editor") return "Cursor editor"
        if (target === "powerlevel10k") return "Powerlevel10k"
        return target.charAt(0).toUpperCase() + target.slice(1)
    }

    function statusLabel(state) {
        if (state === "restart") return "Restart needed"
        if (state === "manual") return "Finish manual setup"
        if (state === "failed") return "Failed"
        if (state === "unapplied") return "Unapplied"
        if (state === "unchanged") return "Unchanged"
        if (state === "active") return "Applying"
        if (state === "queued") return "Queued"
        return "Applied"
    }

    function statusColour(state) {
        if (state === "restart" || state === "unapplied") return Shared.Theme.yellow
        if (state === "manual" || state === "failed") return Shared.Theme.red
        if (state === "applied") return Shared.Theme.green
        if (state === "active") return Shared.Theme.blue
        return Shared.Theme.muted
    }

    function statusIcon(state) {
        if (state === "restart" || state === "unapplied") return "arrows-clockwise"
        if (state === "manual") return "arrow-square-out"
        if (state === "failed") return "warning-circle"
        if (state === "active") return "spinner-gap"
        return "check-circle"
    }
}
