import qs.shared
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var controller
    readonly property var draft: controller.widgetDraft
    readonly property string draftKind: draft ? draft.kind : ""
    readonly property bool commandWidget: draftKind === "command"
    readonly property var catalogue: controller.widgetCatalogue ? controller.widgetCatalogue.widgets || [] : []
    readonly property var registry: controller.widgetRegistry || ({})
    readonly property var manifest: draft && draft.kind === "qml" ? registry[draft.settings.manifest] || null : null
    readonly property var kindRule: controller.widgetSchema && draft
        ? controller.widgetSchema.properties.widgets.items.oneOf.find(item => item.properties.kind.const === draft.kind) : null
    readonly property var settingsRule: kindRule ? controller.widgetSchema.$defs[kindRule.properties.settings.$ref.split("/").pop()] : null
    readonly property bool executable: !!draft && (draft.kind === "command" || draft.kind === "terminal")
    readonly property var appearanceKeys: ["fontFamily", "fontSize", "padding"]
    readonly property var advancedKeys: ["workingDirectory", "environment", "intervalSeconds", "timeoutSeconds", "columns", "rows", "maxRuntimeSeconds", "restartPolicy"]
    readonly property var tabs: ["Content", "Actions", "Appearance", "Display", "Placement"]
    property int currentTab: 0
    property bool contentAdvanced: false
    property string focusedSetting: ""
    property string actionSide: ""
    property string workspaceError: ""
    property var kindDrafts: ({})
    property int editingSession: 0
    readonly property string inputError: firstInputError(body)
    implicitHeight: 300
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.minimumHeight: 0
    spacing: Theme.scaledSpacing(12)
    visible: controller.modalKind === "widget" && draft !== null

    function firstInputError(item) {
        if (item.validationError) return item.validationError;
        for (const child of item.children) {
            const error = firstInputError(child);
            if (error) return error;
        }
        return "";
    }
    function focusInitial() {
        currentTab = 0;
        contentAdvanced = false;
        focusedSetting = "";
        actionSide = "";
        kindDrafts = ({});
        editingSession++;
        resetEditors(body);
        Qt.callLater(() => widgetNameField.focusEditor(true));
    }
    function resetEditors(item) {
        if (typeof item.resetInputState === "function") item.resetInputState();
        for (const child of item.children) resetEditors(child);
    }
    function selectTab(index, focusTab) {
        if (index === 1 && (!draft || draft.kind !== "command")) return;
        currentTab = index;
        scroll.contentItem.contentY = 0;
        const button = tabButtons.itemAt(index);
        if (focusTab && button) button.forceActiveFocus();
        if (button) tabViewport.contentX = Math.max(0, Math.min(button.x, tabViewport.contentWidth - tabViewport.width));
    }
    function moveTab(delta) {
        let index = currentTab;
        do { index = (index + delta + tabs.length) % tabs.length; }
        while (index === 1 && (!draft || draft.kind !== "command"));
        selectTab(index, true);
    }
    function revealFocus() {
        const item = root.Window.window ? root.Window.window.activeFocusItem : null;
        if (!item) return;
        let ancestor = item;
        while (ancestor && ancestor !== body) ancestor = ancestor.parent;
        if (!ancestor) return;
        const position = item.mapToItem(body, 0, 0);
        const flick = scroll.contentItem;
        if (position.y < flick.contentY) flick.contentY = position.y;
        else if (position.y + item.height > flick.contentY + scroll.availableHeight)
            flick.contentY = Math.min(Math.max(0, body.height - scroll.availableHeight), position.y + item.height - scroll.availableHeight);
    }
    function updateSection(section, key, value) {
        const next = JSON.parse(JSON.stringify(draft[section]));
        next[key] = value;
        if (section === "placement" && (key === "width" || key === "height")) next.sizing = "fixed";
        const update = {}; update[section] = next;
        controller.updateWidgetDraft(update);
    }
    function changeKind(kind) {
        if (kind === draft.kind) return;
        const replacement = controller.newWidgetDraft(kind);
        if (!replacement) return;
        kindDrafts[draft.kind] = JSON.parse(JSON.stringify({settings: draft.settings, fullscreen: draft.fullscreen,
            placement: {width: draft.placement.width, height: draft.placement.height, sizing: draft.placement.sizing}}));
        const saved = kindDrafts[kind] || replacement;
        const previous = catalogue.find(entry => entry.kind === draft.kind);
        controller.updateWidgetDraft({kind: kind, name: previous && draft.name === previous.name ? replacement.name : draft.name,
            settings: saved.settings, fullscreen: saved.fullscreen,
            placement: Object.assign({}, draft.placement, {width: saved.placement.width, height: saved.placement.height,
                sizing: saved.placement.sizing})});
        contentAdvanced = false;
        focusedSetting = "";
    }
    function chooseManifest(identifier) {
        const entry = registry[identifier];
        if (!entry) return;
        const settings = Object.assign({}, draft.settings, {manifest: identifier,
            layouts: entry.layouts.slice(), providers: (entry.providers || []).slice()});
        const fullscreen = Object.assign({}, draft.fullscreen);
        if (entry.layouts.indexOf(fullscreen.mode) < 0) fullscreen.mode = entry.layouts[0];
        controller.updateWidgetDraft({settings: settings, fullscreen: fullscreen});
    }
    function workspaceIdsText(ids) {
        return typeof ids === "string" ? ids : ids.map(id => typeof id === "string" ? JSON.stringify(id) : String(id)).join(", ");
    }
    // Only commas outside JSON strings separate names. Keep escapes for JSON.parse.
    function workspaceTokens(text) {
        const tokens = [];
        let start = 0;
        let quoted = false;
        let escaped = false;
        for (let index = 0; index < text.length; ++index) {
            const character = text[index];
            if (escaped) escaped = false;
            else if (quoted && character === "\\") escaped = true;
            else if (character === '"') quoted = !quoted;
            else if (!quoted && character === ",") {
                tokens.push(text.slice(start, index));
                start = index + 1;
            }
        }
        if (quoted) throw new Error("unterminated workspace name");
        tokens.push(text.slice(start));
        return tokens;
    }
    function editWorkspaceIds(text) {
        let value;
        try {
            value = text.trim() ? workspaceTokens(text).map(part => {
                const token = part.trim();
                if (!token) throw new Error("empty workspace");
                return token.startsWith('"') ? JSON.parse(token) : /^-?\d+$/.test(token) ? Number(token) : token;
            }) : [];
            workspaceError = "";
        } catch (error) { value = text; workspaceError = "Enter workspace IDs or names, separated by commas."; }
        updateSection("workspaces", "ids", value);
    }
    function workspaceRangesText(ranges) {
        return typeof ranges === "string" ? ranges : ranges.map(range => range[0] + "-" + range[1]).join(", ");
    }
    function editWorkspaceRanges(text) {
        let value;
        try {
            value = text.trim() ? text.split(",").map(part => {
                const match = part.trim().match(/^(-?\d+)\s*-\s*(-?\d+)$/);
                if (!match || Number(match[1]) > Number(match[2])) throw new Error("invalid range");
                return [Number(match[1]), Number(match[2])];
            }) : [];
            workspaceError = "";
        } catch (error) { value = text; workspaceError = "Enter ascending ranges such as 4-6, separated by commas."; }
        updateSection("workspaces", "ranges", value);
    }

    onDraftChanged: {
        if (!draft) kindDrafts = ({});
        if (currentTab === 1 && (!draft || draft.kind !== "command")) selectTab(0, false);
    }
    onContentAdvancedChanged: scroll.contentItem.contentY = 0
    onFocusedSettingChanged: scroll.contentItem.contentY = 0
    onActionSideChanged: scroll.contentItem.contentY = 0
    Connections { target: root.Window.window; function onActiveFocusItemChanged() { Qt.callLater(root.revealFocus); } }

    Flickable {
        id: tabViewport
        objectName: "widget-tabs"
        Layout.fillWidth: true
        Layout.preferredHeight: 36
        contentWidth: tabRow.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Row {
            id: tabRow
            spacing: Theme.scaledSpacing(6)
            Repeater {
                id: tabButtons
                model: root.tabs
                delegate: BloxButton {
                    required property string modelData
                    required property int index
                    objectName: "widget-tab-" + modelData.toLowerCase()
                    width: Math.max(implicitWidth, (tabViewport.width - tabRow.spacing * 4) / 5)
                    text: modelData
                    compact: true
                    checked: root.currentTab === index
                    enabled: index !== 1 || !!root.draft && root.draft.kind === "command"
                    Accessible.role: Accessible.PageTab
                    Accessible.name: text
                    Accessible.selected: checked
                    onClicked: root.selectTab(index, true)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                            root.moveTab(event.key === Qt.Key_Left ? -1 : 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                            root.selectTab(event.key === Qt.Key_Home ? 0 : 4, true);
                            event.accepted = true;
                        }
                    }
                }
            }
        }
    }
    ScrollView {
        id: scroll
        objectName: "widget-editor-scroll"
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 0
        clip: true
        contentWidth: availableWidth
        contentHeight: body.implicitHeight
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical: BloxScrollBar {
            objectName: "widget-editor-scrollbar"
            parent: scroll
            orientation: Qt.Vertical
            x: scroll.width - width
            height: scroll.availableHeight
            active: true
            policy: ScrollBar.AsNeeded
            visible: scroll.contentHeight > scroll.availableHeight
        }
        ColumnLayout {
            id: body
            objectName: "widget-editor-body"
            height: implicitHeight
            width: Math.max(0, scroll.availableWidth - (implicitHeight > scroll.availableHeight ? 12 : 0))
            spacing: Theme.scaledSpacing(8)
            ColumnLayout {
                visible: root.currentTab === 0
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(8)
                BloxButton { visible: root.contentAdvanced; text: "Content"; iconName: "caret-left"; onClicked: root.contentAdvanced = false }
                GridLayout {
                    visible: !root.contentAdvanced && !root.focusedSetting
                    Layout.fillWidth: true
                    columns: root.width < 460 ? 2 : 3
                    columnSpacing: Theme.scaledSpacing(10)
                    rowSpacing: Theme.scaledSpacing(8)
                    Label { text: "Name"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12; Layout.preferredWidth: root.width < 360 ? 84 : 114 }
                    BloxTextField {
                        id: widgetNameField
                        objectName: "widgetName"
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: root.draft ? root.draft.name : ""
                        onTextEdited: value => root.controller.updateWidgetDraft({name: value})
                    }
                    Label { visible: root.width < 460; text: "Kind"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12; Layout.row: 1; Layout.column: 0 }
                    BloxComboBox {
                        objectName: "widgetKind"
                        Layout.fillWidth: root.width < 460
                        Layout.minimumWidth: 0
                        Layout.preferredWidth: root.width < 460 ? -1 : 152
                        Layout.row: root.width < 460 ? 1 : 0
                        Layout.column: root.width < 460 ? 1 : 2
                        model: root.catalogue.map(entry => entry.name)
                        currentIndex: root.draft ? root.catalogue.findIndex(entry => entry.kind === root.draft.kind) : -1
                        onActivated: (index, value) => root.changeKind(root.catalogue[index].kind)
                    }
                }
                Repeater {
                    model: root.settingsRule ? Object.keys(root.settingsRule.properties).filter(key => key !== "actions"
                        && (root.draftKind !== "qml" || ["manifest", "providers", "layouts", "settings"].indexOf(key) < 0)
                        && (!root.executable || root.appearanceKeys.indexOf(key) < 0)) : []
                    delegate: SettingsWidgetSettingField {
                        required property string modelData
                        visible: (!root.focusedSetting || root.focusedSetting === modelData)
                            && (!root.executable ? !root.contentAdvanced : root.contentAdvanced === (root.advancedKeys.indexOf(modelData) >= 0))
                        editingSession: root.editingSession
                        onFocusedChanged: {
                            if (focused) root.focusedSetting = modelData;
                            else if (root.focusedSetting === modelData) root.focusedSetting = "";
                        }
                        fieldName: modelData
                        controlName: "widget-setting-" + modelData
                        rule: root.settingsRule ? root.settingsRule.properties[modelData] || {} : ({})
                        value: root.draft ? root.draft.settings[modelData] : undefined
                        onEdited: value => root.controller.updateWidgetOption(modelData, value)
                    }
                }
                SettingsWidgetScalarField {
                    visible: root.draftKind === "qml" && !root.focusedSetting
                    fieldName: "manifest"
                    controlName: "widgetManifest"
                    rule: ({enum:Object.keys(root.registry)})
                    value: root.draft ? root.draft.settings.manifest : ""
                    enabled: Object.keys(root.registry).length > 0
                    onEdited: value => root.chooseManifest(value)
                }
                Repeater {
                    model: root.draftKind === "qml" ? ["providers", "layouts"] : []
                    delegate: SettingsWidgetScalarField {
                        required property string modelData
                        visible: !root.focusedSetting
                        fieldName: modelData
                        rule: ({type:"string"})
                        value: root.draft ? (root.draft.settings[modelData] || []).join(", ") : ""
                        enabled: false
                    }
                }
                Text { visible: root.draftKind === "qml" && !root.manifest && !root.focusedSetting; Layout.fillWidth: true; text: "Choose a registered trusted manifest."; color: Theme.muted; wrapMode: Text.Wrap; font.family: Theme.bodyFontFamily }
                SettingsWidgetSummary {
                    objectName: "widget-qml-settings"
                    visible: root.draftKind === "qml" && !root.focusedSetting
                    label: "Settings"
                    summary: root.draftKind === "qml" ? Object.keys(root.draft.settings.settings).length + " entries" : ""
                    onClicked: root.focusedSetting = "settings"
                }
                BloxButton {
                    visible: root.focusedSetting === "settings" && !qmlSettings.focused
                    iconName: "caret-left"
                    text: "Content"
                    onClicked: root.focusedSetting = ""
                }
                SettingsWidgetSettingField {
                    id: qmlSettings
                    visible: root.draftKind === "qml" && root.focusedSetting === "settings"
                    fieldName: "settings"
                    editingSession: root.editingSession
                    rule: ({type:"object"})
                    value: root.draftKind === "qml" ? root.draft.settings.settings : ({})
                    onFocusedChanged: { if (focused && root.draftKind === "qml") root.focusedSetting = "settings"; }
                    onEdited: value => root.controller.updateWidgetOption("settings", value)
                }
                BloxButton { objectName: "widget-content-advanced"; visible: root.executable && !root.contentAdvanced; text: "Advanced"; iconName: "gear-six"; onClicked: root.contentAdvanced = true }
            }
            ColumnLayout {
                visible: root.currentTab === 1
                Layout.fillWidth: true
                BloxButton { objectName: "widget-action-back"; visible: root.actionSide.length > 0; text: "Actions"; iconName: "caret-left"; onClicked: root.actionSide = "" }
                Repeater {
                    model: root.commandWidget ? ["left", "right"] : []
                    delegate: ColumnLayout {
                        required property string modelData
                        Layout.fillWidth: true
                        SettingsWidgetSummary {
                            objectName: "widget-action-" + modelData
                            visible: !root.actionSide
                            label: modelData === "left" ? "Left click" : "Right click"
                            summary: {
                                const action = root.draft && root.draft.settings.actions ? root.draft.settings.actions[modelData] : null;
                                return action ? (action.kind === "run" ? "Run" : "Launch") + " · " + JSON.parse(JSON.stringify(action.command || [])).join(" ") : "None";
                            }
                            onClicked: root.actionSide = modelData
                        }
                        SettingsWidgetActionEditor {
                            visible: root.actionSide === modelData
                            Layout.fillWidth: true
                            side: modelData
                            editingSession: root.editingSession
                            value: root.draft && root.draft.settings.actions ? root.draft.settings.actions[modelData] : null
                            rule: root.settingsRule && root.settingsRule.properties.actions ? root.settingsRule.properties.actions.properties[modelData] : null
                            onEdited: value => {
                                const actions = Object.assign({}, root.draft.settings.actions);
                                actions[modelData] = value;
                                root.controller.updateWidgetOption("actions", actions);
                            }
                        }
                    }
                }
            }
            ColumnLayout {
                visible: root.currentTab === 2
                Layout.fillWidth: true
                SettingsWidgetScalarField { fieldName: "presentation"; label: "Layout"; controlName: "widgetPresentation"; rule: ({enum:["Open","Compact"]}); value: root.draft && root.draft.appearance.presentation === "compact" ? "Compact" : "Open"; onEdited: value => root.updateSection("appearance", "presentation", value === "Compact" ? "compact" : "open") }
                BloxSlider { objectName: "widgetBackgroundOpacity"; Layout.fillWidth: true; label: "Background opacity"; from: 0; to: 1; value: root.draft ? root.draft.appearance.backgroundOpacity : 0.8; onMoved: value => root.updateSection("appearance", "backgroundOpacity", value) }
                SettingsWidgetScalarField { fieldName: "scrollbars"; label: "Scrollbars"; controlName: "widgetScrollbars"; rule: ({enum:["auto","show","hide"]}); value: root.draft ? root.draft.appearance.scrollbars : "auto"; onEdited: value => root.updateSection("appearance", "scrollbars", value) }
                Repeater {
                    model: root.commandWidget ? root.appearanceKeys : []
                    delegate: SettingsWidgetSettingField {
                        required property string modelData
                        fieldName: modelData
                        rule: root.settingsRule ? root.settingsRule.properties[modelData] || {} : ({})
                        value: root.draft ? root.draft.settings[modelData] : undefined
                        onEdited: value => root.controller.updateWidgetOption(modelData, value)
                    }
                }
            }
            ColumnLayout {
                visible: root.currentTab === 3
                Layout.fillWidth: true
                SettingsWidgetScalarField { fieldName: "visibility"; label: "Show when"; controlName: "widgetVisibility"; rule: ({enum:["always","empty-workspace"]}); value: root.draft ? root.draft.visibility : "empty-workspace"; onEdited: value => root.controller.updateWidgetDraft({visibility:value}) }
                SettingsWidgetScalarField { fieldName: "workspaces"; label: "Workspaces"; controlName: "widgetWorkspaceMode"; rule: ({enum:["All","Selected"]}); value: root.draft && root.draft.workspaces.mode === "include" ? "Selected" : "All"; onEdited: value => root.updateSection("workspaces", "mode", value === "All" ? "all" : "include") }
                SettingsWidgetScalarField { visible: !!root.draft && root.draft.workspaces.mode === "include"; fieldName: "ids"; label: "IDs and names"; controlName: "widgetWorkspaceIds"; rule: ({type:"string"}); value: root.draft ? root.workspaceIdsText(root.draft.workspaces.ids) : ""; onEdited: value => root.editWorkspaceIds(value) }
                SettingsWidgetScalarField { visible: !!root.draft && root.draft.workspaces.mode === "include"; fieldName: "ranges"; label: "Ranges"; controlName: "widgetWorkspaceRanges"; rule: ({type:"string"}); value: root.draft ? root.workspaceRangesText(root.draft.workspaces.ranges) : ""; onEdited: value => root.editWorkspaceRanges(value) }
                RowLayout {
                    Layout.fillWidth: true
                    Label { Layout.preferredWidth: root.width < 360 ? 84 : 114; text: "Fullscreen"; color: Theme.muted; font.family: Theme.bodyFontFamily; font.pixelSize: 12 }
                    BloxCheckBox { objectName: "widgetFullscreenEnabled"; checked: root.draft ? root.draft.fullscreen.enabled : false; onToggled: value => root.updateSection("fullscreen", "enabled", value) }
                    BloxComboBox {
                        objectName: "widgetFullscreenMode"
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        enabled: root.draft ? root.draft.fullscreen.enabled : false
                        model: root.draft ? root.draft.kind === "qml" ? root.manifest ? root.manifest.layouts : [] : root.kindRule ? root.kindRule.properties.fullscreen.properties.mode.enum : [] : []
                        currentIndex: root.draft ? model.indexOf(root.draft.fullscreen.mode) : -1
                        onActivated: (index, value) => root.updateSection("fullscreen", "mode", value)
                    }
                }
            }
            ColumnLayout {
                visible: root.currentTab === 4
                Layout.fillWidth: true
                SettingsWidgetScalarField { fieldName: "anchor"; label: "Anchor"; controlName: "widgetAnchor"; rule: ({enum:["top-left","top-right","bottom-left","bottom-right","centre"]}); value: root.draft ? root.draft.placement.anchor : "top-left"; onEdited: value => root.updateSection("placement", "anchor", value) }
                Repeater {
                    model: ["x", "y", "width", "height", "sizing"]
                    delegate: SettingsWidgetScalarField {
                        required property string modelData
                        fieldName: modelData
                        label: ({x:"X", y:"Y", width:"Width", height:"Height", sizing:"Sizing"})[modelData]
                        controlName: "widgetPlacement-" + modelData
                        rule: modelData === "sizing" ? ({enum:["fixed","content"]}) : ({type:"integer"})
                        value: root.draft ? root.draft.placement[modelData] ?? (modelData === "sizing" ? "fixed" : undefined) : undefined
                        onEdited: value => root.updateSection("placement", modelData, value)
                    }
                }
            }
        }
    }
    Text {
        objectName: "widget-validation-error"
        Layout.fillWidth: true
        Layout.maximumHeight: 36
        visible: text.length > 0
        text: root.inputError || controller.widgetDraftError
        color: Theme.red
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        font.family: Theme.bodyFontFamily
        font.pixelSize: 12
    }
}
