import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    readonly property var samples: observation.history || []
    readonly property real graphMaximum: {
        let highest = 1;
        for (let i = 0; i < samples.length; i++) {
            if (numeric(samples[i].rxBytesPerSecond)) highest = Math.max(highest, samples[i].rxBytesPerSecond);
            if (numeric(samples[i].txBytesPerSecond)) highest = Math.max(highest, samples[i].txBytesPerSecond);
        }
        return highest;
    }
    implicitWidth: 380
    implicitHeight: 240
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.gap
        RowLayout {
            Layout.fillWidth: true
            spacing: root.gap
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4 * root.density
                Text { text: "Receive"; color: root.muted; font.family: root.bodyFont; font.pixelSize: 12 * root.displayScale }
                Text { Layout.fillWidth: true; text: root.bytes(root.observation.rxBytesPerSecond) + (root.numeric(root.observation.rxBytesPerSecond) ? "/s" : ""); color: root.positive; font.family: root.bodyFont; font.pixelSize: (root.compactPresentation ? 20 : 23) * root.displayScale; fontSizeMode: Text.Fit; minimumPixelSize: 10 }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4 * root.density
                Text { text: "Send"; color: root.muted; font.family: root.bodyFont; font.pixelSize: 12 * root.displayScale }
                Text { Layout.fillWidth: true; text: root.bytes(root.observation.txBytesPerSecond) + (root.numeric(root.observation.txBytesPerSecond) ? "/s" : ""); color: root.secondary; font.family: root.bodyFont; font.pixelSize: (root.compactPresentation ? 20 : 23) * root.displayScale; fontSizeMode: Text.Fit; minimumPixelSize: 10 }
            }
        }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Sparkline { anchors.fill: parent; samples: root.samples; valueKey: "rxBytesPerSecond"; maximum: root.graphMaximum; stroke: root.positive }
            Sparkline { anchors.fill: parent; samples: root.samples; valueKey: "txBytesPerSecond"; maximum: root.graphMaximum; stroke: root.secondary }
            Text { anchors.centerIn: parent; visible: root.samples.length < 2; text: "Waiting for samples"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize }
        }
        Text { Layout.fillWidth: true; text: (root.observation.interfaces || []).map(item => item.name).join(", "); color: root.muted; font.family: root.monoFont; font.pixelSize: 12 * root.displayScale; elide: Text.ElideRight }
    }
}
