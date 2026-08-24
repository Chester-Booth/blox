import qs.shared
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    required property SystemPopoutController controller

    Layout.fillWidth: true
    visible: controller.currentMode() === "brightness"
    spacing: Theme.scaledSpacing(10)

    SystemLevelSlider {
        Layout.fillWidth: true
        interactive: root.controller.brightnessCanChange
        value: root.controller.visualBrightnessPercent
        accent: Theme.yellow
        onDragStarted: root.controller.adjustingBrightness = true
        onChanged: (value) => {
            root.controller.queueBrightness(value);
        }
        onDragFinished: root.controller.finishBrightness()
    }

    PillSelector {
        Layout.fillWidth: true
        enabled: root.controller.brightnessCanChange
        title: "Blue light"
        currentId: root.controller.visualBlueLightMode
        optimistic: true
        options: [{
            "id": "off",
            "icon": "󰃞",
            "label": "Off"
        }, {
            "id": "auto",
            "icon": "󰖙",
            "label": "Auto"
        }, {
            "id": "on",
            "icon": "󰖔",
            "label": "On"
        }]
        onSelected: (id) => {
            if (id === root.controller.visualBlueLightMode)
                return ;

            root.controller.runCommand(root.controller.scriptRoot + "/display/blue-light-mode.sh " + id, true);
        }
    }

}
