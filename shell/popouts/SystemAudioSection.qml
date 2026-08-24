import qs.shared
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    required property SystemPopoutController controller

    Layout.fillWidth: true
    visible: controller.currentMode() === "audio"
    spacing: Theme.scaledSpacing(10)

    SystemLevelSlider {
        Layout.fillWidth: true
        interactive: root.controller.audioCanChange
        value: root.controller.visualAudioVolume
        maxValue: 150
        snapValue: 100
        accent: root.controller.visualAudioOverdriven ? Theme.red : Theme.blue
        onDragStarted: root.controller.adjustingAudio = true
        onChanged: (value) => {
            root.controller.queueAudio(value);
        }
        onDragFinished: root.controller.finishAudio()
    }

    PillSelector {
        Layout.fillWidth: true
        enabled: root.controller.audioCanChange
        title: "Microphone"
        currentText: visualId === "muted" ? "Muted" : "Open"
        currentId: root.controller.micMuted ? "muted" : "open"
        selectedAccent: visualId === "open" ? Theme.blue : Theme.yellow
        optimistic: true
        options: [{
            "id": "open",
            "icon": "󰍬",
            "label": "Open"
        }, {
            "id": "muted",
            "icon": "󰍭",
            "label": "Muted"
        }]
        onSelected: (id) => {
            if (id !== currentId)
                root.controller.runCommand(root.controller.scriptRoot + "/control.sh mic " + id, true);

        }
    }

}
