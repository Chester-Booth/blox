pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.modules
import qs.shared

SettingsPageContent {
    id: root

    readonly property var controller: windowOwner.themeEditorController
    readonly property var widgets: controller ? controller.widgetItems() : []
    readonly property var catalogue: controller && controller.widgetCatalogue ? controller.widgetCatalogue.widgets || [] : []
    readonly property string metadataError: windowOwner.widgetMetadataError || ""
    sectionMap: [{id: "widgets", item: widgetsSection}]
    searchTargetMap: [{section: "widgets", label: "Widgets", objectName: "newWidgetButton"}]
        .concat(["Background opacity", "Workspace assignment", "Fullscreen"].map(label => ({
            section: "widgets", label: label, objectName: widgets.length ? "widget-edit-" + widgets[0].id : "newWidgetButton"
        }))).concat(catalogue.map(entry => ({
        section: "widgets", label: entry.kind === "qml" ? "QML widget" : entry.name + " widget",
        objectName: widgets.some(item => item.kind === entry.kind) ? "widget-row-" + entry.kind : "newWidgetButton"
    })))

    function setWidgetEnabled(id, enabled) {
        if (!controller) return;
        controller.setWidgetItems(widgets.map(item => item.id === id ? Object.assign({}, item, {enabled: enabled}) : item));
    }

    function deleteWidget(id) {
        if (controller) controller.setWidgetItems(widgets.filter(item => item.id !== id));
    }

    function editWidget(id) {
        if (!controller) return false;
        const index = controller.widgetItems().findIndex(item => item.id === id);
        if (index < 0) return false;
        controller.openWidgetEditor(index);
        return true;
    }

    ColumnLayout {
        id: widgetsSection
        Layout.fillWidth: true
        spacing: Theme.scaledSpacing(9)

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: "Widgets"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 20
                font.bold: true
            }
            BloxButton {
                text: "Edit mode"
                iconName: "squares-four"
                enabled: root.controller && root.controller.widgetControlsEnabled && root.widgets.some(item => item.enabled)
                onClicked: root.windowOwner.beginWidgetEditMode()
            }
            BloxButton {
                text: "New widget"
                iconName: "plus"
                enabled: root.controller && root.controller.widgetControlsEnabled && root.controller.widgetCatalogue && root.controller.widgetSchema && root.widgets.length < root.controller.widgetSchema.properties.widgets.maxItems
                id: newWidgetButton
                objectName: "newWidgetButton"
                onClicked: root.controller.openWidgetEditor(-1)
            }
            BloxButton {
                text: "Import"
                iconName: "download-simple"
                enabled: root.controller && root.controller.widgetControlsEnabled
                onClicked: root.controller.openWidgetImportDialog()
            }
            BloxButton {
                text: "Export"
                iconName: "upload-simple"
                enabled: root.controller && root.controller.widgetControlsEnabled
                onClicked: root.controller.openWidgetExportDialog()
            }
        }

        Repeater {
            model: root.widgets
            delegate: Rectangle {
                id: widgetRow
                required property var modelData
                objectName: "widget-row-" + widgetRow.modelData.kind
                Layout.fillWidth: true
                implicitHeight: 58
                radius: Theme.scaledRadius(8)
                color: rowHover.hovered ? Theme.withAlpha(Theme.surfaceAlt, 0.55) : Theme.background
                border.color: Theme.border
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(9)
                    spacing: Theme.scaledSpacing(9)
                    PhosphorIcon {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        iconName: "squares-four"
                        iconColor: widgetRow.modelData.enabled ? Theme.blue : Theme.muted
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.scaledSpacing(2)
                        Text {
                            Layout.fillWidth: true
                            text: widgetRow.modelData.name
                            color: widgetRow.modelData.enabled ? Theme.foreground : Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: (root.catalogue.find(entry => entry.kind === widgetRow.modelData.kind) || {name: widgetRow.modelData.kind}).name + (widgetRow.modelData.settings.style ? " · " + widgetRow.modelData.settings.style : "")
                            color: Theme.muted
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                    BloxCheckBox {
                        Layout.preferredWidth: 27
                        text: ""
                        checked: widgetRow.modelData.enabled
                        onToggled: value => root.setWidgetEnabled(widgetRow.modelData.id, value)
                    }
                    BloxButton {
                        id: editWidgetButton
                        objectName: "widget-edit-" + widgetRow.modelData.id
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        compact: true
                        iconName: "pencil-simple"
                        iconSize: 16
                        enabled: root.controller && root.controller.widgetControlsEnabled
                        onClicked: root.editWidget(widgetRow.modelData.id)
                    }
                    BloxButton {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        compact: true
                        iconName: "trash"
                        iconSize: 16
                        destructive: true
                        enabled: root.controller && root.controller.widgetControlsEnabled
                        onClicked: root.deleteWidget(widgetRow.modelData.id)
                    }
                }
                HoverHandler { id: rowHover }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Theme.widgetError.length > 0
            text: Theme.widgetError
            color: Theme.red
            wrapMode: Text.Wrap
        }

        Text {
            Layout.fillWidth: true
            visible: root.metadataError.length > 0
            text: root.metadataError
            color: Theme.red
            wrapMode: Text.Wrap
        }

        Text {
            Layout.fillWidth: true
            visible: root.controller && root.controller.widgetDraftError.length > 0
            text: root.controller ? root.controller.widgetDraftError : ""
            color: Theme.red
            wrapMode: Text.Wrap
        }

        Text {
            visible: root.widgets.length === 0
            text: "No widgets in this theme. Add one to show it on the desktop."
            color: Theme.muted
        }
    }

}
