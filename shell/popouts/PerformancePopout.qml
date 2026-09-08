import qs.shared
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property var status: ({
    })
    property var batteryStatus: ({
    })
    property var powerProfileStatus: ({
    })
    property var powerProfileProvider: null
    property var vendorPerformanceStatus: ({
    })
    property var vendorPerformanceProvider: null
    property var gpuStatus: ({
    })
    property var gpuProvider: null
    property var monitorStatus: ({
    })
    property var monitorProvider: null
    property string scriptRoot: ""
    property bool actionBusy: false
    property string actionError: ""
    property string statusError: ""
    readonly property string visibleError: actionError.length > 0 ? actionError : statusError
    readonly property bool powerProfileReady: root.powerProfileStatus && root.powerProfileStatus.capability && root.powerProfileStatus.capability.ready === true
    readonly property bool powerProfileCanChange: root.powerProfileStatus && root.powerProfileStatus.capability && root.powerProfileStatus.capability.canChange === true
    readonly property bool vendorPerformanceCanChange: root.vendorPerformanceStatus && root.vendorPerformanceStatus.capability && root.vendorPerformanceStatus.capability.canChange === true
    readonly property bool performanceProfileCanChange: root.powerProfileCanChange || root.vendorPerformanceCanChange
    readonly property bool fanCurveCanChange: root.vendorPerformanceStatus && root.vendorPerformanceStatus.fanCurveCapability && root.vendorPerformanceStatus.fanCurveCapability.canChange === true
    readonly property bool gpuCanChange: root.gpuStatus && root.gpuStatus.capability && root.gpuStatus.capability.canChange === true
    readonly property string gpuPendingAction: root.gpuStatus && root.gpuStatus.pendingAction ? String(root.gpuStatus.pendingAction) : ""
    readonly property var refreshMonitors: root.monitorStatus && Array.isArray(root.monitorStatus.monitors) ? root.monitorStatus.monitors.filter(monitor => monitor.canChange === true) : []

    signal action(string command)

    function numberValue(value, fallback) {
        const parsed = Number(value);
        return isNaN(parsed) ? fallback : parsed;
    }

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    function performanceProfileId() {
        if (root.powerProfileCanChange)
            return String(root.powerProfileStatus.profile || "balanced");
        const value = String(root.vendorPerformanceStatus.profile || "balanced").toLowerCase();
        return value === "quiet" ? "power-saver" : ["performance", "balanced"].indexOf(value) >= 0 ? value : "balanced";
    }

    function performanceProfileOptions() {
        const available = root.powerProfileCanChange ? root.powerProfileStatus.profiles || [] : (root.vendorPerformanceStatus.profiles || []).map(value => value === "quiet" ? "power-saver" : value);
        return [{
            "id": "performance",
            "icon": "󱓞",
            "label": "Performance"
        }, {
            "id": "balanced",
            "icon": "󰗑",
            "label": "Balanced"
        }, {
            "id": "power-saver",
            "icon": "󰌪",
            "label": "Saver"
        }].filter(option => available.indexOf(option.id) >= 0);
    }

    function setPerformanceProfile(id) {
        if (root.powerProfileCanChange && root.powerProfileProvider)
            return root.powerProfileProvider.setProfile(id);
        if (root.vendorPerformanceCanChange && root.vendorPerformanceProvider)
            return root.vendorPerformanceProvider.setProfile(id === "power-saver" ? "quiet" : id);
        return false;
    }

    function gpuModeId() {
        const value = String(root.gpuStatus.mode || "custom").toLowerCase();
        return ["dedicated", "hybrid", "integrated"].indexOf(value) >= 0 ? value : "custom";
    }

    function gpuModeText() {
        return root.gpuStatus.label || "Unknown";
    }

    function fanText(value) {
        return value ? value + " RPM" : "N/A";
    }

    function gpuMemoryLabel() {
        return status.vramTotal ? "VRAM" : "Swap";
    }

    function gpuMemoryValue() {
        if (status.vramTotal)
            return (status.vramUsed || "0") + "/" + status.vramTotal + " MB";

        return (status.swapUsed || "?") + "/" + (status.swapTotal || "?") + " GB";
    }

    width: 268
    height: (status.vramTotal ? 517 : 465) + (root.performanceProfileCanChange ? 0 : -56) + (root.fanCurveCanChange ? 56 : 0) + (root.gpuCanChange ? 0 : -56) + root.refreshMonitors.length * 56 + (root.gpuPendingAction.length > 0 ? 22 : 0) + (visibleError.length > 0 ? Math.max(26, errorText.implicitHeight) : 0)
    radius: Theme.scaledRadius(8)
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(12)
        spacing: Theme.scaledSpacing(10)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(9)

            Item {
                width: 30
                height: 30

                Text {
                    anchors.centerIn: parent
                    text: "󰓅"
                    color: Theme.yellow
                    font.family: Theme.fontFamily
                    font.pixelSize: 24
                }

            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 30

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Performance"
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 15
                    font.bold: true
                }

            }

        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            rowSpacing: 7
            columnSpacing: 7

            DetailPill {
                icon: "󰈐"
                label: "CPU fan"
                value: root.fanText(root.status.fan1Rpm)
                accent: Theme.blue
            }

            DetailPill {
                icon: "󰈐"
                label: "GPU fan"
                value: root.fanText(root.status.fan2Rpm)
                accent: Theme.blue
            }

            DetailPill {
                icon: "󱟤"
                label: "Power"
                value: (root.status.powerW || "N/A") + " W"
                accent: Theme.yellow
            }

            DetailPill {
                icon: root.batteryStatus && root.batteryStatus.icon ? root.batteryStatus.icon : "󰁹"
                label: "Battery time"
                value: root.batteryStatus.timeLabel || "N/A"
                accent: root.batteryStatus && root.batteryStatus.class === "critical" ? Theme.red : root.batteryStatus && root.batteryStatus.class === "charging" ? Theme.green : Theme.teal
            }

            DetailPill {
                icon: "󰔟"
                label: "Uptime"
                value: root.status.uptimeLabel || "N/A"
                accent: Theme.teal
            }

            DetailPill {
                icon: "󰍛"
                label: root.gpuMemoryLabel()
                value: root.gpuMemoryValue()
                accent: Theme.mauve
            }

        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(7)

            MetricBar {
                icon: "󰘚"
                label: "CPU"
                detail: (root.status.cpuUtil || 0) + "% at " + (root.status.cpuClock || "N/A") + " GHz"
                percent: root.clamp(root.numberValue(root.status.cpuUtil, 0), 0, 100)
                accent: Theme.blue
            }

            MetricBar {
                icon: "󰔏"
                label: "Temperature"
                detail: (root.status.cpuTemp || "N/A") + "°C"
                percent: root.clamp(root.numberValue(root.status.cpuTemp, 0), 0, 100)
                accent: root.numberValue(root.status.cpuTemp, 0) >= 80 ? Theme.red : Theme.yellow
            }

            MetricBar {
                icon: ""
                label: "Memory"
                detail: (root.status.ramUsed || "?") + "/" + (root.status.ramTotal || "?") + " GB"
                percent: root.clamp(root.numberValue(root.status.ramPercent, 0), 0, 100)
                accent: Theme.mauve
            }

            MetricBar {
                icon: ""
                label: "Swap"
                detail: (root.status.swapUsed || "?") + "/" + (root.status.swapTotal || "?") + " GB"
                percent: root.clamp(root.numberValue(root.status.swapPercent, 0), 0, 100)
                accent: Theme.mauve
                visible: !!root.status.vramTotal
                Layout.preferredHeight: visible ? 45 : 0
            }

        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(6)

            Repeater {
                model: root.refreshMonitors

                PillSelector {
                    required property var modelData
                    Layout.fillWidth: true
                    enabled: !root.actionBusy && !root.monitorStatus.busy
                    title: root.refreshMonitors.length === 1 ? "Refresh rate" : modelData.name + " refresh"
                    currentId: modelData.refreshId
                    currentText: Number(modelData.refreshRate).toFixed(Number(modelData.refreshRate) % 1 === 0 ? 0 : 2) + " Hz"
                    options: modelData.rates
                    onSelected: (id) => {
                        if (root.monitorProvider)
                            return root.monitorProvider.setRefresh(modelData.name, id);
                        return false;
                    }
                }
            }

            PillSelector {
                Layout.fillWidth: true
                visible: root.performanceProfileCanChange
                enabled: !root.actionBusy && root.performanceProfileCanChange
                title: "Performance profile"
                currentId: root.performanceProfileId()
                options: root.performanceProfileOptions()
                onSelected: (id) => root.setPerformanceProfile(id)
            }

            PillSelector {
                Layout.fillWidth: true
                visible: root.fanCurveCanChange
                enabled: !root.actionBusy && root.fanCurveCanChange
                title: "Fan curves"
                currentId: root.vendorPerformanceStatus.fanCurveEnabled === true ? "custom" : "automatic"
                options: [{
                    "id": "automatic",
                    "icon": "󰠝",
                    "label": "Automatic"
                }, {
                    "id": "custom",
                    "icon": "󱑬",
                    "label": "Custom"
                }]
                onSelected: (id) => {
                    if (root.vendorPerformanceProvider)
                        return root.vendorPerformanceProvider.setFanCurvesEnabled(id === "custom");
                    return false;
                }
            }

            PillSelector {
                Layout.fillWidth: true
                visible: root.gpuCanChange
                enabled: !root.actionBusy && root.gpuCanChange
                title: "GPU mode"
                currentText: root.gpuModeText()
                currentId: root.gpuModeId()
                options: [{"id": "dedicated", "icon": "󰢮", "label": "Dedicated"},
                    {"id": "hybrid", "icon": "󰾅", "label": "Hybrid"},
                    {"id": "integrated", "icon": "󰌪", "label": "Integrated"}
                ].filter(option => root.gpuStatus.supportedModes.indexOf(option.id) >= 0)
                onSelected: (id) => {
                    if (root.gpuProvider)
                        return root.gpuProvider.requestMode(id);
                    return false;
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.gpuPendingAction.length > 0
                text: root.gpuPendingAction === "reboot" ? "Restart to finish the GPU switch" : "Log out to finish the GPU switch"
                color: Theme.yellow
                font.family: Theme.bodyFontFamily
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

        }

        Text {
            id: errorText

            Layout.fillWidth: true
            visible: root.visibleError.length > 0
            text: root.visibleError
            color: Theme.red
            font.family: Theme.bodyFontFamily
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

    }

    component DetailPill: Rectangle {
        id: pill

        property string icon: ""
        property string label: ""
        property string value: ""
        property color accent: Theme.blue

        Layout.fillWidth: true
        Layout.preferredHeight: 36
        radius: Theme.scaledRadius(6)
        color: Theme.surface
        border.color: Theme.surfaceAlt
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.scaledSpacing(8)
            anchors.rightMargin: Theme.scaledSpacing(8)
            spacing: Theme.scaledSpacing(6)

            Text {
                text: pill.icon
                color: pill.accent
                font.family: Theme.fontFamily
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 16
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(0)

                Text {
                    Layout.fillWidth: true
                    text: pill.label
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: pill.value
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                    font.bold: true
                    elide: Text.ElideRight
                }

            }

        }

    }

    component MetricBar: Rectangle {
        id: metric

        property string icon: ""
        property string label: ""
        property string detail: ""
        property real percent: 0
        property color accent: Theme.blue

        Layout.fillWidth: true
        Layout.preferredHeight: 45
        radius: Theme.scaledRadius(6)
        color: Theme.surface
        border.color: Theme.surfaceAlt
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.scaledSpacing(9)
            anchors.rightMargin: Theme.scaledSpacing(9)
            anchors.topMargin: Theme.scaledSpacing(7)
            anchors.bottomMargin: Theme.scaledSpacing(7)
            spacing: Theme.scaledSpacing(5)

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(7)

                Text {
                    text: metric.icon
                    color: metric.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    Layout.preferredWidth: 18
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    text: metric.label
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 10
                }

                Text {
                    Layout.fillWidth: true
                    text: metric.detail
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                }

            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 5
                radius: Theme.scaledRadius(2)
                color: Theme.background

                Rectangle {
                    width: Math.max(3, parent.width * metric.percent / 100)
                    height: parent.height
                    radius: parent.radius
                    color: metric.accent

                    Behavior on width {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }

                    }

                }

            }

        }

    }

}
