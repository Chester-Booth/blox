import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.shared as Shared

FloatingWindow {
    id: root

    required property var flowState
    property var settingsWindow: null
    readonly property Item captureItem: frame

    readonly property bool importing: flowState.bundleFlowKind === "import"
    readonly property bool open: flowState.dialogKind === "import-review"
        || (flowState.dialogKind === "export-review" && flowState.bundleStep === "contents")
    readonly property var importedCard: flowState.importedCard || {id: "", name: "Theme", palette: []}
    readonly property var exportCard: flowState.themeCards.find(entry => entry.id === flowState.exportThemeId) || flowState.themeCards[0] || {id: "", name: "Theme", palette: []}
    readonly property var shownCard: (importing ? importedCard : exportCard) || {id: "", name: "Theme", palette: []}
    readonly property bool compactStep: flowState.bundleStep === "result"
    property bool exportTargetsExpanded: false

    title: importing ? "Import theme" : "Export theme"
    implicitWidth: 500
    implicitHeight: compactStep ? 300 : 480
    minimumSize: Qt.size(500, compactStep ? 280 : 440)
    screen: settingsWindow ? settingsWindow.screen : Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    visible: open
    color: "transparent"
    onOpenChanged: Qt.callLater(() => {
        if (open)
            root.focusStep();
        else if (settingsWindow)
            settingsWindow.restoreFocusAfterDialog();
    })
    onClosed: {
        if (flowState.busy) { Qt.callLater(() => root.visible = Qt.binding(() => root.open)); return; }
        if (flowState.dialogKind === "import-review" || flowState.dialogKind === "export-review")
            flowState.closeBundleDialog();
    }

    Connections {
        target: root.flowState
        function onBundleStepChanged() {
            if (root.open)
                Qt.callLater(() => root.focusStep());
        }
    }

    Timer {
        interval: 100
        running: root.open && Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE").length > 0
            && Quickshell.env("QT_QPA_PLATFORM") !== "offscreen"
        onTriggered: Quickshell.execDetached(["python3", decodeURIComponent(String(Qt.resolvedUrl("../scripts/place_settings_window.py")).replace(/^file:\/\//, "")),
            root.title, String(Quickshell.processId), String(root.implicitWidth), String(root.implicitHeight), root.settingsWindow ? root.settingsWindow.title : ""])
    }

    Rectangle {
        id: frame
        Keys.onEscapePressed: event => {
            if (!root.flowState.busy) root.flowState.closeBundleDialog();
            event.accepted = true;
        }
        anchors.fill: parent
        anchors.margins: Shared.Theme.scaledSpacing(1)
        radius: Shared.Theme.scaledRadius(10)
        color: Shared.Theme.surface
        border.color: Shared.Theme.border
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Shared.Theme.scaledSpacing(20)
            spacing: Shared.Theme.scaledSpacing(12)

            RowLayout {
                Layout.fillWidth: true
                spacing: Shared.Theme.scaledSpacing(8)

                Text {
                    Layout.fillWidth: true
                    text: root.heading()
                    color: Shared.Theme.foreground
                    font.family: Shared.Theme.bodyFontFamily
                    font.pixelSize: 19
                    font.bold: true
                }

            }

            Flickable {
                id: bodyScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: bodyColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Shared.BloxWheelHandler {
                    flickable: bodyScroll
                }

                ScrollBar.vertical: Shared.BloxScrollBar {
                    policy: bodyScroll.contentHeight > bodyScroll.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                }

                ColumnLayout {
                    id: bodyColumn
                    x: Shared.Theme.scaledSpacing(2)
                    width: bodyScroll.width - Shared.Theme.scaledSpacing(20)
                    spacing: Shared.Theme.scaledSpacing(12)

                    ColumnLayout {
                        visible: root.importing && root.flowState.bundleStep === "sections"
                        Layout.fillWidth: true
                        spacing: Shared.Theme.scaledSpacing(10)

                        SettingsBundleThemeCard {
                            Layout.fillWidth: true
                            card: root.importedCard
                            subtitle: ""
                            incoming: true
                            active: root.importedCard.id === root.flowState.appliedThemeId
                        }

                        Rectangle {
                            visible: root.importValidationState() !== "valid"
                            Layout.fillWidth: true
                            implicitHeight: validationText.implicitHeight + Shared.Theme.scaledSpacing(18)
                            radius: Shared.Theme.scaledRadius(7)
                            color: Shared.Theme.withAlpha(root.validationColour(), 0.08)
                            border.color: Shared.Theme.withAlpha(root.validationColour(), 0.38)

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: Shared.Theme.scaledSpacing(9)
                                spacing: Shared.Theme.scaledSpacing(8)

                                Shared.PhosphorIcon {
                                    Layout.preferredWidth: 17
                                    Layout.preferredHeight: 17
                                    iconName: root.validationIcon()
                                    iconColor: root.validationColour()
                                }

                                Text {
                                    id: validationText
                                    Layout.fillWidth: true
                                    text: root.validationMessage()
                                    color: Shared.Theme.foreground
                                    font.family: Shared.Theme.bodyFontFamily
                                    font.pixelSize: 10
                                    wrapMode: Text.Wrap
                                }
                            }
                        }

                        Shared.PillSelector {
                            visible: ["conflict", "changed"].indexOf(root.importValidationState()) >= 0
                            Layout.fillWidth: true
                            showHeader: false
                            currentId: root.flowState.copyImportedTheme ? "copy" : root.flowState.replaceImportedTheme ? "replace" : ""
                            options: [{id: "replace", label: "Replace"}, {id: "copy", label: "Create copy"}]
                            onSelected: id => {
                                root.flowState.replaceImportedTheme = id === "replace";
                                root.flowState.copyImportedTheme = id === "copy";
                            }
                        }

                        Repeater {
                            model: root.flowState.importSectionRows
                            delegate: SettingsBundleSectionRow {
                                required property var modelData
                                Layout.fillWidth: true
                                label: modelData.label
                                detail: modelData.detail || ""
                                readOnly: modelData.readOnly === true
                                checked: modelData.included === true || root.flowState.selectedImportSections.indexOf(modelData.id) >= 0
                                onToggled: value => root.flowState.toggleImportSection(modelData.id, value)
                            }
                        }
                    }

                    ColumnLayout {
                        visible: root.importing && root.flowState.bundleStep === "sensitive"
                        Layout.fillWidth: true
                        spacing: Shared.Theme.scaledSpacing(9)

                        SettingsBundleThemeCard {
                            Layout.fillWidth: true
                            card: root.importedCard
                            subtitle: ""
                            incoming: true
                            active: root.importedCard.id === root.flowState.appliedThemeId
                        }

                        Repeater {
                            model: root.flowState.sensitiveImportFiles
                            delegate: SettingsBundleIncludedFileCard {
                                required property var modelData
                                Layout.fillWidth: true
                                file: modelData
                                flowState: root.flowState
                            }
                        }
                    }

                    ColumnLayout {
                        visible: !root.importing && root.flowState.bundleStep === "contents"
                        Layout.fillWidth: true
                        spacing: Shared.Theme.scaledSpacing(11)

                        SettingsBundleThemeCard {
                            Layout.fillWidth: true
                            card: root.exportCard
                            subtitle: ""
                            active: root.exportCard.id === root.flowState.appliedThemeId
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Export type"
                            color: Shared.Theme.foreground
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 12
                        }

                        Item {
                            Layout.fillWidth: true
                            implicitHeight: exportTypeSelector.implicitHeight

                            Shared.PillSelector {
                                id: exportTypeSelector
                                objectName: "export-type"
                                anchors.fill: parent
                                activeFocusOnTab: true
                                Keys.onLeftPressed: root.selectAdjacentExportType(-1)
                                Keys.onRightPressed: root.selectAdjacentExportType(1)
                                title: ""
                                showHeader: false
                                currentId: root.flowState.bundleLevel
                                selectedAccent: Shared.Theme.blue
                                options: [
                                    {id: "minimal", label: "Minimal"},
                                    {id: "standard", label: "Standard"},
                                    {id: "full", label: "Full"},
                                    {id: "custom", label: "Custom"}
                                ]
                                onSelected: id => root.selectExportType(id)
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                border.color: Shared.Theme.blue
                                border.width: 2
                                visible: exportTypeSelector.activeFocus
                            }
                        }

                        Repeater {
                            model: root.flowState.exportComponentRows
                            delegate: ColumnLayout {
                                id: exportSection
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Shared.Theme.scaledSpacing(4)

                                SettingsBundleSectionRow {
                                    Layout.fillWidth: true
                                    label: exportSection.modelData.label
                                    detail: exportSection.modelData.id === "targets" ? "" : exportSection.modelData.detail
                                    actionText: exportSection.modelData.id === "targets"
                                        ? (root.exportTargetsExpanded ? "Hide all targets" : "View all targets") : ""
                                    actionIcon: exportSection.modelData.id === "targets"
                                        ? (root.exportTargetsExpanded ? "caret-up" : "caret-down") : ""
                                    checked: root.flowState.exportComponentSelected(exportSection.modelData.id)
                                    onToggled: value => root.flowState.toggleExportComponent(exportSection.modelData.id, value)
                                    onActionClicked: root.exportTargetsExpanded = !root.exportTargetsExpanded
                                }

                                Rectangle {
                                    visible: exportSection.modelData.id === "targets"
                                        && root.flowState.exportComponentSelected("targets") && root.exportTargetsExpanded
                                    Layout.fillWidth: true
                                    implicitHeight: targetGroupColumn.implicitHeight + Shared.Theme.scaledSpacing(16)
                                    radius: Shared.Theme.scaledRadius(7)
                                    color: Shared.Theme.background
                                    border.color: Shared.Theme.border

                                    ColumnLayout {
                                        id: targetGroupColumn
                                        anchors.fill: parent
                                        anchors.margins: Shared.Theme.scaledSpacing(8)
                                        spacing: Shared.Theme.scaledSpacing(8)

                                        Repeater {
                                            model: root.flowState.exportTargetGroups
                                            delegate: ColumnLayout {
                                                id: targetGroup
                                                required property var modelData
                                                readonly property var groupTargets: root.flowState.targets.filter(target => modelData.keys.indexOf(target.key) >= 0)
                                                Layout.fillWidth: true
                                                spacing: Shared.Theme.scaledSpacing(3)

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: targetGroup.modelData.label
                                                    color: Shared.Theme.muted
                                                    font.family: Shared.Theme.bodyFontFamily
                                                    font.pixelSize: 11
                                                    font.bold: true
                                                }

                                                GridLayout {
                                                    Layout.fillWidth: true
                                                    columns: 2
                                                    columnSpacing: Shared.Theme.scaledSpacing(8)
                                                    rowSpacing: Shared.Theme.scaledSpacing(3)

                                                    Repeater {
                                                        model: targetGroup.groupTargets
                                                        delegate: Shared.BloxCheckBox {
                                                            required property var modelData
                                                            Layout.fillWidth: true
                                                            text: modelData.label
                                                            checked: root.flowState.selectedExportTargets.indexOf(modelData.key) >= 0
                                                            onToggled: value => root.flowState.toggleExportTarget(modelData.key, value)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Repeater {
                        model: !root.importing ? root.flowState.sensitiveImportFiles : []
                        SettingsBundleIncludedFileCard { required property var modelData; Layout.fillWidth: true; file: modelData; flowState: root.flowState }
                    }

                    ColumnLayout {
                        visible: root.importing && root.flowState.bundleStep === "progress"
                        Layout.fillWidth: true
                        Layout.topMargin: Shared.Theme.scaledSpacing(12)
                        spacing: Shared.Theme.scaledSpacing(12)

                        SettingsBundleThemeCard {
                            Layout.fillWidth: true
                            card: root.importedCard
                            subtitle: ""
                            incoming: true
                            active: root.importedCard.id === root.flowState.appliedThemeId
                        }

                        Shared.PhosphorIcon {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            iconName: "spinner-gap"
                            iconColor: Shared.Theme.blue
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Creating an editable theme. Saved targets will not be applied."
                            color: Shared.Theme.muted
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                        }
                    }

                    ColumnLayout {
                        visible: !root.importing && root.flowState.bundleStep === "progress"
                        Layout.fillWidth: true
                        Layout.topMargin: Shared.Theme.scaledSpacing(12)
                        spacing: Shared.Theme.scaledSpacing(12)

                        SettingsBundleThemeCard {
                            Layout.fillWidth: true
                            card: root.exportCard
                            subtitle: root.exportFilePath()
                            active: root.exportCard.id === root.flowState.appliedThemeId
                        }

                        Shared.PhosphorIcon {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            iconName: "spinner-gap"
                            iconColor: Shared.Theme.blue
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Writing " + root.flowState.bundleFileName
                            color: Shared.Theme.muted
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    ColumnLayout {
                        visible: root.flowState.bundleStep === "result"
                        Layout.fillWidth: true
                        spacing: Shared.Theme.scaledSpacing(11)

                        SettingsBundleThemeCard {
                            Layout.fillWidth: true
                            card: root.shownCard
                            subtitle: root.importing ? "" : root.exportFilePath()
                            incoming: root.importing
                            active: root.shownCard.id === root.flowState.appliedThemeId
                        }

                        Shared.PhosphorIcon {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: 28
                            Layout.preferredHeight: 28
                            iconName: root.flowState.bundleOperationState === "failure" ? "warning-circle" : "check-circle"
                            iconColor: root.flowState.bundleOperationState === "failure" ? Shared.Theme.red : Shared.Theme.green
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.resultTitle()
                            color: Shared.Theme.foreground
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 16
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.resultDetail()
                            color: Shared.Theme.muted
                            font.family: Shared.Theme.bodyFontFamily
                            font.pixelSize: 10
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Shared.Theme.scaledSpacing(8)

                Item { Layout.fillWidth: true }

                Shared.BloxButton {
                    visible: root.flowState.bundleStep === "sections" || root.flowState.bundleStep === "sensitive" || (!root.importing && root.flowState.bundleStep === "contents")
                    text: "Cancel"
                    onClicked: root.flowState.closeBundleDialog()
                }

                Shared.BloxButton {
                    visible: root.importing && !root.flowState.applyScriptReview && ["sections", "sensitive"].indexOf(root.flowState.bundleStep) >= 0
                    text: "Back"
                    iconName: "arrow-left"
                    onClicked: {
                        if (root.flowState.bundleStep === "sensitive")
                            root.flowState.bundleStep = "sections";
                        else
                            root.flowState.showBundleFilePicker("file-open");
                    }
                }

                Shared.BloxButton {
                    visible: root.importing && root.flowState.bundleStep === "sections"
                    text: root.flowState.sensitiveImportFiles.length ? "Next" : "Complete import"
                    iconName: "arrow-right"
                    enabled: root.flowState.importCanContinue() && (!root.flowState.applyScriptReview || root.flowState.approvedSensitiveFiles.length === root.flowState.sensitiveImportFiles.length)
                    accent: Shared.Theme.blue
                    onClicked: root.flowState.continueImportSections()
                }

                Shared.BloxButton {
                    visible: root.importing && root.flowState.bundleStep === "sensitive"
                    text: root.flowState.applyScriptReview ? "Apply" : "Complete import"
                    iconName: "arrow-right"
                    accent: Shared.Theme.blue
                    enabled: root.flowState.importCanContinue() && (!root.flowState.applyScriptReview || root.flowState.approvedSensitiveFiles.length === root.flowState.sensitiveImportFiles.length)
                    onClicked: root.flowState.startBundleImport()
                }

                Shared.BloxButton {
                    visible: !root.importing && root.flowState.bundleStep === "contents"
                    text: "Download"
                    enabled: !root.flowState.busy
                    iconName: "download-simple"
                    accent: Shared.Theme.blue
                    onClicked: root.flowState.showBundleFilePicker("file-save")
                }

                Shared.BloxButton {
                    id: resultButton
                    visible: root.flowState.bundleStep === "result"
                    text: root.resultButtonText()
                    accent: Shared.Theme.blue
                    onClicked: root.importing && root.flowState.bundleOperationState === "success"
                        ? root.flowState.completeBundleImport()
                        : root.flowState.closeBundleDialog()
                }
            }
        }
    }

    function focusStep() {
        if (!open)
            return;
        if (flowState.bundleStep === "result")
            resultButton.forceActiveFocus();
        else
            bodyColumn.forceActiveFocus();
    }

    function selectExportType(id) {
        if (id === "custom") {
            flowState.bundleLevel = "custom";
            exportTargetsExpanded = true;
        } else {
            flowState.chooseBundle(id);
        }
    }

    function selectAdjacentExportType(direction) {
        const types = ["minimal", "standard", "full", "custom"];
        const current = types.indexOf(flowState.bundleLevel);
        const next = Math.max(0, Math.min(types.length - 1, current + direction));
        selectExportType(types[next]);
    }

    function heading() {
        if (flowState.bundleStep === "sections") return "Choose sections";
        if (flowState.bundleStep === "sensitive") return "Approve included files";
        if (flowState.bundleStep === "contents") return "Export theme";
        if (flowState.bundleStep === "progress") return importing ? "Importing theme" : "Exporting theme";
        if (flowState.bundleStep === "result") return importing ? "Import result" : "Export result";
        return importing ? "Import theme" : "Export theme";
    }

    function titleCase(value) {
        return value.length ? value.charAt(0).toUpperCase() + value.slice(1) : "";
    }

    function importValidationState() {
        if (flowState.bundleOperationState === "progress") return "progress";
        if (flowState.bundleOperationState === "success") return "success";
        if (flowState.bundleOperationState === "failure") return "failure";
        return flowState.importValidationState();
    }

    function validationColour() {
        const state = importValidationState();
        if (["invalid", "failure"].indexOf(state) >= 0) return Shared.Theme.red;
        if (["conflict", "changed", "missing-dependency"].indexOf(state) >= 0) return Shared.Theme.yellow;
        if (state === "success") return Shared.Theme.green;
        return Shared.Theme.blue;
    }

    function validationIcon() {
        const state = importValidationState();
        if (["invalid", "failure", "conflict", "changed", "missing-dependency"].indexOf(state) >= 0) return "warning-circle";
        return state === "success" ? "check-circle" : "check-circle";
    }

    function validationMessage() { return flowState.validationMessage; }

    function exportFilePath() {
        return flowState.bundleDestination + "/" + flowState.bundleFileName;
    }

    function resultTitle() {
        if (flowState.bundleOperationState === "failure")
            return importing ? "Theme was not imported" : "Bundle was not saved";
        return importing ? "Theme imported" : "Bundle exported";
    }

    function resultDetail() {
        if (flowState.bundleOperationState === "failure") {
            if (!importing)
                return "Your theme is unchanged. Choose another destination and retry.";
            const count = flowState.approvedSensitiveFiles.length;
            return "Your current theme is unchanged. " + count + " user-owned " + (count === 1 ? "file" : "files") + " were approved.";
        }
        if (importing) {
            const count = flowState.approvedSensitiveFiles.length;
            return "Editable theme created. No targets were applied. " + count + " user-owned " + (count === 1 ? "file" : "files") + " included.";
        }
        return root.titleCase(flowState.bundleLevel) + " bundle saved to " + root.exportFilePath()
            + (flowState.exportComponentSelected("wallpaper") ? ". Wallpaper included." : ".");
    }

    function resultButtonText() {
        if (!importing) return "Done";
        return flowState.bundleOperationState === "success" ? "Open theme" : "Close";
    }
}
