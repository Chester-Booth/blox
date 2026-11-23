import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    readonly property bool chart: settings.style !== "rings"
    implicitWidth: 360
    implicitHeight: 250

    component Meter: Rectangle {
        property real value: -1
        property color tint: root.accent
        Layout.fillWidth: true
        implicitHeight: 4 * root.displayScale
        radius: Math.min(height / 2, 2 * root.rounding)
        color: root.borderColour
        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, parent.value))
            height: parent.height
            radius: parent.radius
            color: parent.tint
        }
    }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.gap
        RowLayout {
            Layout.fillWidth: true
            Text { text: root.chart ? "CPU" : "System"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale }
            Item { Layout.fillWidth: true }
            Text { visible: root.chart; text: root.numberText(root.observation.cpuPercent, "%"); color: root.accent; font.family: root.monoFont; font.pixelSize: 24 * root.displayScale }
        }
        RowLayout {
            visible: !root.chart
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8 * root.density
            MetricRing { Layout.fillWidth: true; Layout.fillHeight: true; value: root.numeric(root.observation.cpuPercent) ? root.observation.cpuPercent / 100 : -1; label: root.numberText(root.observation.cpuPercent, "%"); detail: "CPU"; stroke: root.accent; foreground: root.foreground; muted: root.muted; fontFamily: root.bodyFont; textScale: root.displayScale }
            MetricRing { Layout.fillWidth: true; Layout.fillHeight: true; value: root.numeric(root.observation.memoryPercent) ? root.observation.memoryPercent / 100 : -1; label: root.bytes(root.observation.memoryUsedBytes); detail: "RAM"; stroke: root.secondary; foreground: root.foreground; muted: root.muted; fontFamily: root.bodyFont; textScale: root.displayScale }
            MetricRing { Layout.fillWidth: true; Layout.fillHeight: true; value: root.numeric(root.observation.cpuTemperatureC) ? root.observation.cpuTemperatureC / 100 : -1; label: root.numberText(root.observation.cpuTemperatureC, "°C"); detail: "CPU temperature"; stroke: root.positive; foreground: root.foreground; muted: root.muted; fontFamily: root.bodyFont; textScale: root.displayScale }
        }
        Sparkline {
            objectName: "systemHistory"
            visible: root.chart && !root.compactPresentation
            Layout.fillWidth: true
            Layout.fillHeight: true
            samples: root.observation.history || []
            valueKey: "cpuPercent"
            stroke: root.accent
        }
        Meter {
            objectName: "systemCpuMeter"
            visible: root.chart && root.compactPresentation
            value: root.numeric(root.observation.cpuPercent) ? root.observation.cpuPercent / 100 : -1
        }
        Text { visible: root.chart && !root.compactPresentation && (!root.observation.history || root.observation.history.length < 2); text: "Waiting for samples"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize }
        RowLayout {
            visible: root.chart
            Layout.fillWidth: true
            Text { text: "RAM"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale }
            Item { Layout.fillWidth: true }
            Text { text: root.bytes(root.observation.memoryUsedBytes) + " / " + root.bytes(root.observation.memoryTotalBytes); color: root.foreground; font.family: root.monoFont; font.pixelSize: 12 * root.displayScale; elide: Text.ElideRight; Layout.maximumWidth: Math.max(0, root.width - root.padding * 2) * 0.8 }
        }
        Meter { visible: root.chart; value: root.numeric(root.observation.memoryPercent) ? root.observation.memoryPercent / 100 : -1; tint: root.secondary }
        Item { visible: root.chart && root.compactPresentation; Layout.fillHeight: true }
        RowLayout {
            Layout.fillWidth: true
            Text { text: root.numberText(root.observation.cpuTemperatureC, "°C"); color: root.muted; font.family: root.monoFont; font.pixelSize: 12 * root.displayScale }
            Item { Layout.fillWidth: true }
            Text { text: root.numberText(root.observation.powerW, " W", 1); color: root.muted; font.family: root.monoFont; font.pixelSize: 12 * root.displayScale }
            Item { Layout.fillWidth: true }
            Text { text: root.numeric(root.observation.uptimeSeconds) ? Math.floor(root.observation.uptimeSeconds / 3600) + "h " + Math.floor(root.observation.uptimeSeconds % 3600 / 60) + "m" : "Unavailable"; color: root.muted; font.family: root.bodyFont; font.pixelSize: 12 * root.displayScale }
        }
    }
}
