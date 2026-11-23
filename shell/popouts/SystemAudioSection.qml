import qs.shared
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root

    required property SystemPopoutController controller
    signal keyboardFocusRequested(Item item)

    Layout.fillWidth: true
    visible: controller.currentMode() === "audio"
    spacing: Theme.scaledSpacing(10)

    SystemLevelSlider {
        id: volumeSlider
        Layout.fillWidth: true
        label: "Volume"
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
        onFocusEntered: item => root.keyboardFocusRequested(item)
    }

    PillSelector {
        Layout.fillWidth: true
        enabled: root.controller.micCanChange
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
                root.controller.setMicMuted(id === "muted");

        }
    }

}
