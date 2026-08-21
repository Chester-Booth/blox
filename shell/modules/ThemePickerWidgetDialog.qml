import "."
import "../shared"
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

GridLayout {
    required property ThemePickerController controller

    function focusInitial() {
        widgetNameField.focusEditor(true);
    }

    visible: controller.modalKind === "widget" && controller.widgetDraft !== null
    Layout.fillWidth: true
    columns: 2
    columnSpacing: 10
    rowSpacing: 8

    Label {
        text: "Name"
        color: Theme.muted
    }

    BloxTextField {
        id: widgetNameField

        Layout.fillWidth: true
        text: controller.widgetDraft ? controller.widgetDraft.name : ""
        onTextEdited: (value) => {
            if (controller.widgetDraft)
                controller.updateWidgetDraft({
                "name": value
            });

        }
    }

    Label {
        text: "Preset"
        color: Theme.muted
    }

    BloxComboBox {
        Layout.fillWidth: true
        model: ["file", "music", "calendar", "clock", "decorative", "custom"]
        currentIndex: controller.widgetDraft ? model.indexOf(controller.widgetPreset(controller.widgetDraft)) : model.length - 1
        onActivated: (index, value) => {
            const identity = controller.widgetDraft.id;
            const name = controller.widgetDraft.name;
            controller.widgetDraft = controller.newWidgetDraft(value === "decorative" ? "aquarium" : value);
            controller.updateWidgetDraft({
                "id": identity,
                "name": name
            });
        }
    }

    Label {
        visible: controller.widgetDraft && controller.widgetPreset(controller.widgetDraft) === "decorative"
        text: "Decoration"
        color: Theme.muted
    }

    BloxComboBox {
        visible: controller.widgetDraft && controller.widgetPreset(controller.widgetDraft) === "decorative"
        Layout.fillWidth: true
        model: ["aquarium", "pipes", "tree", "matrix", "fortune", "train"]
        currentIndex: controller.widgetDraft ? model.indexOf(controller.widgetDraft.type) : 0
        onActivated: (index, value) => {
            const replacement = controller.newWidgetDraft(value);
            controller.updateWidgetDraft({
                "type": value,
                "content_command": replacement.content_command,
                "options": replacement.options
            });
        }
    }

    Label {
        visible: controller.widgetDraft && (controller.widgetDraft.type === "custom" || controller.widgetDraft.type === "file")
        text: "Content command"
        color: Theme.muted
    }

    RowLayout {
        visible: controller.widgetDraft && (controller.widgetDraft.type === "custom" || controller.widgetDraft.type === "file")
        Layout.fillWidth: true

        BloxTextField {
            Layout.fillWidth: true
            text: controller.widgetDraft ? controller.widgetDraft.content_command : ""
            onTextEdited: (value) => {
                if (controller.widgetDraft)
                    controller.updateWidgetDraft({
                    "content_command": value
                });

            }
        }

        BloxButton {
            visible: controller.widgetDraft && controller.widgetDraft.type === "file"
            text: "Browse"
            onClicked: controller.openWidgetFileDialog()
        }

    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "custom"
        text: "Left click"
        color: Theme.muted
    }

    BloxTextField {
        visible: controller.widgetDraft && controller.widgetDraft.type === "custom"
        Layout.fillWidth: true
        text: controller.widgetDraft ? controller.widgetDraft.left_click_command : ""
        onTextEdited: (value) => {
            if (controller.widgetDraft)
                controller.updateWidgetDraft({
                "left_click_command": value
            });

        }
    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "custom"
        text: "Right click"
        color: Theme.muted
    }

    BloxTextField {
        visible: controller.widgetDraft && controller.widgetDraft.type === "custom"
        Layout.fillWidth: true
        text: controller.widgetDraft ? controller.widgetDraft.right_click_command : ""
        onTextEdited: (value) => {
            if (controller.widgetDraft)
                controller.updateWidgetDraft({
                "right_click_command": value
            });

        }
    }

    Label {
        visible: controller.widgetDraft && (controller.widgetDraft.type === "custom" || controller.widgetDraft.type === "file")
        text: "Update (ms)"
        color: Theme.muted
    }

    BloxTextField {
        visible: controller.widgetDraft && (controller.widgetDraft.type === "custom" || controller.widgetDraft.type === "file")
        Layout.fillWidth: true
        text: controller.widgetDraft ? String(controller.widgetDraft.interval_ms) : "60000"
        onEditingFinished: {
            if (controller.widgetDraft)
                controller.updateWidgetDraft({
                "interval_ms": Math.max(250, parseInt(text) || 60000)
            });

        }
    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "clock"
        text: "Clock options"
        color: Theme.muted
    }

    RowLayout {
        visible: controller.widgetDraft && controller.widgetDraft.type === "clock"

        BloxCheckBox {
            text: "24 hour"
            checked: !(controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.twelve_hour)
            onToggled: controller.updateWidgetOption("twelve_hour", !checked)
        }

        BloxCheckBox {
            text: "Seconds"
            checked: controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.seconds === true
            onToggled: controller.updateWidgetOption("seconds", checked)
        }

        BloxCheckBox {
            text: "Bold"
            checked: controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.bold === true
            onToggled: controller.updateWidgetOption("bold", checked)
        }

        BloxCheckBox {
            text: "Blink"
            checked: controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.blink === true
            onToggled: controller.updateWidgetOption("blink", checked)
        }

        BloxCheckBox {
            text: "Box"
            checked: controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.box === true
            onToggled: controller.updateWidgetOption("box", checked)
        }

    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "calendar"
        text: "View"
        color: Theme.muted
    }

    BloxComboBox {
        visible: controller.widgetDraft && controller.widgetDraft.type === "calendar"
        Layout.fillWidth: true
        model: ["agenda", "week", "month"]
        currentIndex: controller.widgetDraft && controller.widgetDraft.options ? Math.max(0, model.indexOf(controller.widgetDraft.options.view || "agenda")) : 0
        onActivated: (index, value) => {
            return controller.updateWidgetOption("view", value);
        }
    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "calendar"
        text: "Line art"
        color: Theme.muted
    }

    RowLayout {
        visible: controller.widgetDraft && controller.widgetDraft.type === "calendar"

        BloxComboBox {
            Layout.fillWidth: true
            model: ["fancy", "unicode", "ascii"]
            currentIndex: controller.widgetDraft && controller.widgetDraft.options ? Math.max(0, model.indexOf(controller.widgetDraft.options.lineart || "unicode")) : 1
            onActivated: (index, value) => {
                return controller.updateWidgetOption("lineart", value);
            }
        }

        BloxCheckBox {
            text: "Colour"
            checked: !controller.widgetDraft || !controller.widgetDraft.options || controller.widgetDraft.options.colour !== false
            onToggled: controller.updateWidgetOption("colour", checked)
        }

    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "music"
        text: "Cava config file"
        color: Theme.muted
    }

    BloxTextField {
        visible: controller.widgetDraft && controller.widgetDraft.type === "music"
        Layout.fillWidth: true
        placeholderText: "~/.config/cava/config"
        text: controller.widgetDraft && controller.widgetDraft.options ? controller.widgetDraft.options.config_file || "" : ""
        onEditingFinished: controller.updateWidgetOption("config_file", text.trim())
    }

    Label {
        visible: controller.widgetDraft && controller.widgetDraft.type === "file"
        text: "File options"
        color: Theme.muted
    }

    RowLayout {
        visible: controller.widgetDraft && controller.widgetDraft.type === "file"
        Layout.fillWidth: true
        Layout.rightMargin: 10

        BloxCheckBox {
            text: "Show filename"
            checked: controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.show_filename === true
            onToggled: controller.updateWidgetOption("show_filename", checked)
        }

        BloxCheckBox {
            text: "Markdown"
            checked: controller.widgetDraft && controller.widgetDraft.options && controller.widgetDraft.options.markdown === true
            onToggled: controller.updateWidgetOption("markdown", checked)
        }

        BloxCheckBox {
            text: "Auto update"
            checked: !controller.widgetDraft || !controller.widgetDraft.options || controller.widgetDraft.options.auto_update !== false
            onToggled: controller.updateWidgetOption("auto_update", checked)
        }

    }

}
