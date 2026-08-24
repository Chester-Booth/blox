import qs.shared
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    required property SystemPopoutController controller

    Layout.fillWidth: true
    visible: controller.currentMode() === "network" || controller.currentMode() === "bluetooth"
    spacing: Theme.scaledSpacing(10)

    PillSelector {
        Layout.fillWidth: true
        visible: root.controller.currentMode() === "network"
        enabled: root.controller.networkCanChange
        title: "Wi-Fi"
        currentText: visualId === "on" ? "On" : "Off"
        currentId: root.controller.networkEnabled ? "on" : "off"
        selectedAccent: visualId === "on" ? Theme.blue : Theme.yellow
        optimistic: true
        options: [{
            "id": "on",
            "icon": "󰤯",
            "label": "On"
        }, {
            "id": "off",
            "icon": "󰤭",
            "label": "Off"
        }]
        onSelected: (id) => {
            if (id !== currentId)
                root.controller.runCommand(root.controller.scriptRoot + "/control.sh wifi " + id, true);

        }
    }

    PillSelector {
        Layout.fillWidth: true
        visible: root.controller.currentMode() === "bluetooth"
        enabled: root.controller.bluetoothCanChange
        title: "Bluetooth"
        currentText: visualId === "on" ? "On" : "Off"
        currentId: root.controller.bluetoothEnabled ? "on" : "off"
        selectedAccent: visualId === "on" ? Theme.blue : Theme.yellow
        optimistic: true
        options: [{
            "id": "on",
            "icon": "󰂯",
            "label": "On"
        }, {
            "id": "off",
            "icon": "󰂲",
            "label": "Off"
        }]
        onSelected: (id) => {
            if (id !== currentId)
                root.controller.runCommand(root.controller.scriptRoot + "/control.sh bluetooth " + id, true);

        }
    }

}
