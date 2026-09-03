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
    property string scriptRoot: ""
    property bool actionBusy: false
    property string actionError: ""
    property string statusError: ""
    readonly property string visibleError: actionError.length > 0 ? actionError : statusError
    readonly property bool powerProfileReady: root.powerProfileStatus && root.powerProfileStatus.capability && root.powerProfileStatus.capability.ready === true

    signal action(string command)

    function fanCommand(profile) {
        return scriptRoot + "/control.sh fan-profile " + profile.toLowerCase();
    }

    function gpuCommand(mode) {
        return scriptRoot + "/gpu/set-mode.sh " + mode;
    }

    function numberValue(value, fallback) {
        const parsed = Number(value);
        return isNaN(parsed) ? fallback : parsed;
    }

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    function fanProfileId() {
        return String(status.profile || "balanced").toLowerCase();
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
    height: (status.vramTotal ? 517 : 465) + (powerProfileReady ? 56 : 0) + (visibleError.length > 0 ? Math.max(26, errorText.implicitHeight) : 0)
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

            PillSelector {
                Layout.fillWidth: true
                enabled: !root.actionBusy
                title: "Fan profile"
                currentText: root.status.profile || "Unknown"
                currentId: root.fanProfileId()
                options: [{
                    "id": "performance",
                    "icon": "󱑬",
                    "label": "Perf"
                }, {
                    "id": "balanced",
                    "icon": "󱜝",
                    "label": "Bal"
                }, {
                    "id": "quiet",
                    "icon": "󰠝",
                    "label": "Quiet"
                }]
                onSelected: (id) => {
                    return root.action(root.fanCommand(id.charAt(0).toUpperCase() + id.slice(1)));
                }
            }

            PillSelector {
                Layout.fillWidth: true
                visible: root.powerProfileReady
                enabled: !root.actionBusy && root.powerProfileStatus && root.powerProfileStatus.capability && root.powerProfileStatus.capability.canChange === true
                title: "Power profile"
                currentId: root.powerProfileStatus.profile || "unavailable"
                options: [{
                    "id": "power-saver",
                    "icon": "󰌪",
                    "label": "Saver"
                }, {
                    "id": "balanced",
                    "icon": "󱜝",
                    "label": "Balanced"
                }, {
                    "id": "performance",
                    "icon": "󱑬",
                    "label": "Performance"
                }, {
                    "id": "unavailable",
                    "icon": "󰅙",
                    "label": "Unavailable"
                }]
                onSelected: (id) => {
                    if (root.powerProfileProvider)
                        root.powerProfileProvider.setProfile(id);
                }
            }

            PillSelector {
                Layout.fillWidth: true
                enabled: !root.actionBusy
                title: "GPU mode"
                currentText: root.status.gpuLabel || "Unknown"
                currentId: root.status.gpuMode || "eco"
                options: [{
                    "id": "gaming",
                    "icon": "󰪫",
                    "label": "144"
                }, {
                    "id": "performance",
                    "icon": "󰢮",
                    "label": "60"
                }, {
                    "id": "high-refresh",
                    "icon": "",
                    "label": "144"
                }, {
                    "id": "eco",
                    "icon": "󰌪",
                    "label": "Eco"
                }]
                onSelected: (id) => {
                    return root.action(root.gpuCommand(id));
                }
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
