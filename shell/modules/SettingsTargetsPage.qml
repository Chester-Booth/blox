import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var settings: windowOwner.settingsController.settings || ({})
    readonly property var targetSettings: settings.targets || ({})
    readonly property var targetGroups: ["Core", "Applications", "Browsers"]
    readonly property var generatedTargetOrder: ["stylus", "quickshell", "widgets", "gtk", "helium", "chromium", "cursor",
        "wallpaper", "kitty", "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "t3code",
        "zed", "obsidian", "powerlevel10k"]
    readonly property var controller: windowOwner.themeEditorController
    readonly property var composition: windowOwner.compositionProviderController.provenance || ({})
    readonly property var candidate: controller ? controller.candidate : null

    searchTargetMap: targetSearchTargets()
    sectionMap: [
        {id: "targets", item: targetsSection},
        {id: "generated-files", item: filesSection},
        {id: "overrides", item: overridesSection}
    ]

    function targetKeys(group) {
        if (group === "Core")
            return ["quickshell", "widgets", "wallpaper", "hyprland", "hyprlock", "cursor"];
        if (group === "Applications")
            return ["kitty", "gtk", "btop", "micro", "glow", "code", "cursor_editor", "t3code", "zed", "stylus", "obsidian", "powerlevel10k"];
        if (group === "Browsers")
            return ["helium", "chromium"];
        return [];
    }

    function targetSearchTargets() {
        const entries = [
            {section: "targets", label: "Targets & files", objectName: "theme-target-quickshell"},
            {section: "targets", label: "Theme targets", objectName: "theme-target-quickshell"},
            {section: "generated-files", label: "Generated files", objectName: "generated-download-all"},
            {section: "overrides", label: "Target colour overrides", objectName: "target-override-gtk-background"}
        ];
        if (controller) {
            controller.targetKeys.forEach(key => entries.push({
                section: "targets", label: "Target " + key, objectName: "theme-target-" + key
            }));
        }
        ["gtk", "hyprlock"].forEach(target => ["background", "foreground", "accent", "border"].forEach(colour => {
            entries.push({section: "overrides", label: (target === "gtk" ? "GTK" : "Hyprlock") + " " + colour + " override",
                objectName: "target-override-" + target + "-" + colour});
        }));
        return entries;
    }

    function targetInfo(key) {
        const available = controller ? controller.targetAvailable(key) : false;
        return {
            key: key,
            label: controller ? controller.targetLabel(key) : key,
            available: available,
            enabled: candidate && candidate.targets ? candidate.targets[key] === true
                : targetSettings[key] ? targetSettings[key].enabled === true : false,
            mode: controller ? controller.targetApplyMode(key) : "automatic"
        };
    }

    function browserUnavailableReasonLabel(key) {
        if (!controller || ["helium", "chromium"].indexOf(key) < 0 || !controller.browserTargetsLoaded)
            return "";
        const browser = controller.browserTargetInfo(key);
        if (!browser || browser.available)
            return "";
        const reason = String(browser.reason || "").toLowerCase();
        if (reason.endsWith("is not installed"))
            return "Not installed";
        if (reason.endsWith("executable is not executable"))
            return "Not executable";
        if (reason.startsWith("stale or unsupported ") && reason.indexOf(" desktop entry") >= 0)
            return "Stale desktop entry";
        if (reason.startsWith("ambiguous browser installation:"))
            return "Multiple installs";
        return "";
    }

    function modeLabel(target) {
        const unavailableReason = !target.available ? browserUnavailableReasonLabel(target.key) : "";
        if (unavailableReason.length > 0)
            return unavailableReason;
        return controller ? controller.targetModeLabel(target.key) : "Automatic";
    }

    function modeColour(target) {
        return target.mode === "restart" ? Theme.yellow : Theme.green;
    }

    function targetLabelFor(key) {
        if (["sddm", "grub"].indexOf(key) >= 0)
            return key + " · unavailable";
        return controller ? controller.targetLabel(key) : key;
    }

    function filesForTarget(key) {
        const entries = composition.targets || [];
        const target = entries.find(entry => entry.target === key);
        return target && Array.isArray(target.files) ? target.files : [];
    }

    function generatedFileGroups() {
        const result = [];
        generatedTargetOrder.forEach(target => {
            const files = filesForTarget(target);
            if (files.length > 0)
                result.push({target: target, files: files});
        });
        return result;
    }

    function targetOverride(target, key) {
        const entry = targetSettings[target];
        const savedOverrides = windowOwner.settingsValue("targets." + target + ".overrides",
            entry && entry.overrides ? entry.overrides : ({}));
        return savedOverrides && savedOverrides[key] ? savedOverrides[key] : "";
    }

    function semanticFallback(key) {
        if (candidate && candidate.colours && candidate.colours[key])
            return candidate.colours[key];
        if (key === "background")
            return Theme.background;
        if (key === "foreground")
            return Theme.foreground;
        if (key === "accent")
            return Theme.accent;
        return Theme.border;
    }

    ColumnLayout {
        id: targetsSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        Text {
            text: "Theme targets"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }

        Repeater {
            model: root.targetGroups
            delegate: ColumnLayout {
                required property string modelData
                readonly property string groupName: modelData
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(6)
                Text {
                    text: groupName
                    color: Theme.blue
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    font.bold: true
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(8)
                    Repeater {
                        model: root.targetKeys(groupName).map(key => root.targetInfo(key))
                        delegate: Rectangle {
                            required property var modelData
                            objectName: "theme-target-" + modelData.key
                            width: 250
                            height: 54
                            radius: Theme.scaledRadius(8)
                            color: modelData.available ? Theme.background : Theme.withAlpha(Theme.background, 0.55)
                            border.color: modelData.available ? Theme.border : Theme.withAlpha(Theme.border, 0.65)
                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: Theme.scaledSpacing(7)
                                spacing: Theme.scaledSpacing(5)
                                BloxCheckBox {
                                    objectName: "theme-target-control-" + modelData.key
                                    Layout.fillWidth: true
                                    text: root.targetLabelFor(modelData.key)
                                    checked: root.windowOwner.settingsValue("targets." + modelData.key + ".enabled",
                                        modelData.enabled)
                                    enabled: modelData.available && root.windowOwner.settingsController.settings !== null
                                    onToggled: value => {
                                        root.windowOwner.writeSettingsValue("targets." + modelData.key + ".enabled", value);
                                        if (root.controller && root.controller.themeControlsEnabled)
                                            root.controller.setTarget(modelData.key, value);
                                    }
                                }
                                Text {
                                    objectName: "theme-target-status-" + modelData.key
                                    visible: modelData.mode !== "manual"
                                    text: root.modeLabel(modelData)
                                    color: root.modeColour(modelData)
                                    font.family: Theme.monoFontFamily
                                    font.pixelSize: 9
                                    Layout.alignment: Qt.AlignVCenter
                                    elide: Text.ElideRight
                                }
                                BloxButton {
                                    visible: modelData.mode === "manual"
                                    text: "Guide"
                                    compact: true
                                    onClicked: root.windowOwner.openStylusGuide()
                                }
                            }
                        }
                    }
                }
            }
        }

        Text { text: "Unavailable"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12; font.bold: true }
        Flow {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(8)
            Repeater {
                model: ["sddm", "grub"].map(key => root.targetInfo(key))
                delegate: BloxCheckBox {
                    required property var modelData
                    objectName: "theme-target-" + modelData.key
                    text: root.targetLabelFor(modelData.key)
                    checked: false
                    enabled: modelData.available
                }
            }
        }
        Text { text: "Stylus"; color: Theme.blue; font.family: Theme.bodyFontFamily; font.pixelSize: 12; font.bold: true }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(10)
            Text { text: "Style set"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
            BloxComboBox {
                Layout.preferredWidth: 230
                enabled: root.windowOwner.settingsController.settings !== null
                model: ["Recommended", "Include unmaintained", "All eligible"]
                currentIndex: Math.max(0, ["recommended", "unmaintained", "all"].indexOf(
                    root.windowOwner.settingsValue("targets.stylus.styleSet",
                        root.targetSettings.stylus ? root.targetSettings.stylus.styleSet || "recommended" : "recommended")))
                onActivated: (index, value) => root.windowOwner.writeSettingsValue("targets.stylus.styleSet", ["recommended", "unmaintained", "all"][index])
            }
            Item { Layout.fillWidth: true }
        }


    }

    SettingsGeneratedFiles {
        id: filesSection
        objectName: "generated-files"
        Layout.fillWidth: true
        windowOwner: root.windowOwner
        groups: root.generatedFileGroups()
        composition: root.composition
        targetLabelFor: root.targetLabelFor
    }

    ColumnLayout {
        id: overridesSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)
        Text {
            text: "Target-specific colour overrides"
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 17
            font.bold: true
        }
        Repeater {
            model: ["gtk", "hyprlock"]
            delegate: ColumnLayout {
                id: targetOverrideGroup
                required property string modelData
                readonly property string targetName: modelData
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(5)
                Text {
                    text: targetName
                    color: Theme.blue
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 12
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(8)
                    Repeater {
                        model: ["background", "foreground", "accent", "border"]
                        delegate: ColumnLayout {
                            required property string modelData
                            readonly property string overrideValue: root.targetOverride(targetOverrideGroup.targetName, modelData)
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.minimumWidth: 0
                            spacing: Theme.scaledSpacing(3)
                            Text {
                                text: modelData
                                color: Theme.muted
                                font.family: Theme.bodyFontFamily
                                font.pixelSize: 9
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                SettingsColourSwatch {
                                    objectName: "target-override-" + targetOverrideGroup.targetName + "-" + modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 38
                                    enabled: root.windowOwner.settingsController.settings !== null
                                        && root.windowOwner.themeEditorController
                                        && root.windowOwner.themeEditorController.candidate !== null
                                    windowOwner: root.windowOwner
                                    key: modelData
                                    target: targetOverrideGroup.targetName
                                    value: overrideValue
                                    fallbackValue: root.semanticFallback(modelData)
                                }
                                BloxButton {
                                    Layout.preferredWidth: 38
                                    Layout.preferredHeight: 38
                                    compact: true
                                    iconName: "arrow-counter-clockwise"
                                    visible: overrideValue.length > 0
                                    HoverHandler { id: resetHover; enabled: parent.enabled }
                                    BloxToolTip {
                                        shown: resetHover.hovered
                                        text: "Reset " + modelData + " to theme colour"
                                    }
                                    onClicked: root.windowOwner.clearTargetOverride(targetOverrideGroup.targetName, modelData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
