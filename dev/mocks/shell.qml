import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "shared"

// Static mock for ADR-010's shape controls, built from the real shared
// components and the live Theme tokens. Run standalone:
//   BLOX_DATA_DIR=$HOME/.local/share/blox/themes qml dev/shape-controls-mock.qml
// Nothing here touches generated state or the running shell.

ApplicationWindow {
    id: root

    readonly property var presets: [
        { id: "square", label: "Square", radius: 0, density: 1.0 },
        { id: "rounded", label: "Rounded", radius: 1.0, density: 1.0 },
        { id: "compact", label: "Compact", radius: 1.0, density: 0.8 },
        { id: "spacious", label: "Spacious", radius: 1.25, density: 1.25 }
    ]
    property real radiusScale: 1.0
    property real densityScale: 1.0
    property string presetId: "rounded"
    readonly property int hyprlandRounding: Math.round(12 * radiusScale)
    readonly property int hyprlandGaps: Math.round(10 * densityScale)
    readonly property int gtkRadius: Math.round(12 * radiusScale)

    function selectPreset(id) {
        const preset = presets.find(entry => entry.id === id);
        if (!preset)
            return;
        presetId = id;
        radiusScale = preset.radius;
        densityScale = preset.density;
    }

    color: Theme.background
    title: "Shape controls mock"
    width: 620
    height: content.implicitHeight + 32

    ColumnLayout {
        id: content

        anchors.fill: parent
        anchors.margins: 16
        spacing: 14

        Label {
            text: "Preset starting points"
            color: Theme.muted
            font.pixelSize: 12
        }

        Row {
            spacing: 10

            Repeater {
                model: root.presets

                delegate: Rectangle {
                    required property var modelData

                    width: 132
                    height: previewColumn.implicitHeight + 14
                    radius: Theme.radius + 2
                    color: root.presetId === modelData.id ? Theme.surfaceAlt : Theme.surface
                    border.color: root.presetId === modelData.id ? Theme.accent : Theme.border
                    border.width: root.presetId === modelData.id ? 2 : 1

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectPreset(modelData.id)
                    }

                    ColumnLayout {
                        id: previewColumn

                        anchors.centerIn: parent
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true
                            height: 8
                            radius: Math.round(4 * modelData.radius)
                            color: Theme.accent
                        }

                        Rectangle {
                            Layout.preferredWidth: 104
                            Layout.preferredHeight: 34
                            radius: Math.round(12 * modelData.radius)
                            color: Theme.withAlpha(Theme.foreground, 0.06)
                            border.color: Theme.border
                        }

                        Row {
                            spacing: Math.max(2, Math.round(10 * (modelData.density - 0.75)))

                            Repeater {
                                model: 3

                                Rectangle {
                                    required property int index

                                    width: 24
                                    height: 20
                                    radius: Math.round(12 * modelData.radius)
                                    color: Theme.surfaceAlt
                                    border.color: Theme.border
                                }
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignHCenter
                            text: modelData.label
                            color: Theme.foreground
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }

        Label {
            text: "Fine control"
            color: Theme.muted
            font.pixelSize: 12
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Label {
                text: "Roundness scale " + root.radiusScale.toFixed(2) + "   (bounds 0 – 2)"
                color: Theme.foreground
            }

            Slider {
                id: radiusSlider

                Layout.fillWidth: true
                from: 0
                to: 2
                stepSize: 0.05
                value: root.radiusScale
                onMoved: {
                    root.radiusScale = value;
                    root.presetId = "";
                }
            }

            Label {
                text: "Density scale " + root.densityScale.toFixed(2) + "   (bounds 0.75 – 1.5)"
                color: Theme.foreground
            }

            Slider {
                id: densitySlider

                Layout.fillWidth: true
                from: 0.75
                to: 1.5
                stepSize: 0.05
                value: root.densityScale
                onMoved: {
                    root.densityScale = value;
                    root.presetId = "";
                }
            }
        }

        GroupBox {
            id: advancedBox

            Layout.fillWidth: true
            title: "Advanced values"

            background: Rectangle {
                y: advancedBox.topPadding - 6
                width: parent.width
                height: parent.height - advancedBox.topPadding + 6
                radius: Theme.radius
                color: Theme.surface
                border.color: Theme.border
            }

            label: Label {
                x: advancedBox.leftPadding
                text: advancedBox.title
                color: Theme.muted
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 6

                SpinBox {
                    id: radiusBox

                    editable: true
                    from: 0
                    to: 200
                    stepSize: 5
                    value: Math.round(root.radiusScale * 100)
                    textFromValue: value => (value / 100).toFixed(2)
                    valueFromText: text => Math.round(Number(text) * 100)
                    onValueModified: {
                        root.radiusScale = value / 100;
                        root.presetId = "";
                    }
                }

                SpinBox {
                    id: densityBox

                    editable: true
                    from: 75
                    to: 150
                    stepSize: 5
                    value: Math.round(root.densityScale * 100)
                    textFromValue: value => (value / 100).toFixed(2)
                    valueFromText: text => Math.round(Number(text) * 100)
                    onValueModified: {
                        root.densityScale = value / 100;
                        root.presetId = "";
                    }
                }

                Label {
                    text: "Hyprland rounding " + root.hyprlandRounding + " px · gaps " + root.hyprlandGaps + " px · GTK radius " + root.gtkRadius + " px — Apply only; Quickshell previews live."
                    color: Theme.muted
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
            }
        }

        Label {
            text: "Live Quickshell preview"
            color: Theme.muted
            font.pixelSize: 12
        }

        Rectangle {
            Layout.fillWidth: true
            height: 92
            radius: Math.round(12 * root.radiusScale)
            color: Theme.surface
            border.color: Theme.border

            Column {
                anchors.fill: parent
                anchors.margins: Math.round(10 * root.densityScale)
                spacing: Math.round(8 * root.densityScale)

                Rectangle {
                    width: parent.width
                    height: 12
                    radius: Math.round(6 * root.radiusScale)
                    color: Theme.accent
                }

                Row {
                    spacing: Math.round(10 * root.densityScale)

                    Rectangle {
                        width: 140
                        height: 40
                        radius: Math.round(12 * root.radiusScale)
                        color: Theme.withAlpha(Theme.foreground, 0.05)
                        border.color: Theme.border
                    }

                    Rectangle {
                        width: 44
                        height: 40
                        radius: Math.round(12 * root.radiusScale)
                        color: Theme.surfaceAlt
                        border.color: Theme.border
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
