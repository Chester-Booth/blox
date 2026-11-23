import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    contentReady: dataReady && !!observation.entries && typeof observation.entries.length === "number" && width > 0 && height > 0
    implicitWidth: 360
    implicitHeight: 300
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.gap
        RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; text: "Files"; color: root.foreground; font.family: root.bodyFont; font.pixelSize: 18 * root.displayScale }
            Text { Layout.maximumWidth: (root.width - root.padding * 2) * 0.65; text: root.settings.directory || ""; color: root.muted; font.family: root.bodyFont; font.pixelSize: 11 * root.displayScale; elide: Text.ElideLeft }
        }
        NativeScroll {
            id: fileScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            scrollbarMode: root.scrollbarMode
            contentWidth: availableWidth
            Column {
                width: fileScroll.availableWidth
                spacing: root.gap
                Repeater { model: root.observation.entries || []
                    Item {
                        required property var modelData
                        width: parent.width
                        height: (root.compactPresentation ? 32 : 42) * root.displayScale
                        RowLayout {
                            anchors.fill: parent
                            spacing: root.gap
                            NativeIcon { name: modelData.isDirectory ? "folder-open" : "file"; iconRoot: root.theme ? root.theme.iconRoot : ""; tint: root.accent; Layout.preferredWidth: 18 * root.displayScale; Layout.preferredHeight: 18 * root.displayScale }
                            Column {
                                Layout.fillWidth: true
                                spacing: 4 * root.density
                                Text { width: parent.width; text: modelData.name; color: root.foreground; font.family: root.bodyFont; font.pixelSize: 14 * root.displayScale; elide: Text.ElideRight }
                                Text { visible: !root.compactPresentation; width: parent.width; text: modelData.isDirectory ? "Folder" : root.bytes(modelData.sizeBytes); color: root.muted; font.family: root.bodyFont; font.pixelSize: 11 * root.displayScale; elide: Text.ElideRight }
                            }
                            NativeAction { text: "Open"; iconName: "arrow-square-out"; iconRoot: root.theme ? root.theme.iconRoot : ""; Accessible.name: "Open " + modelData.name; foreground: root.muted; accent: root.accent; rounding: root.rounding; density: root.density; onClicked: root.actionRequested("open", {path: modelData.path}) }
                        }
                    }
                }
                Text { visible: !(root.observation.entries || []).length; text: "No files"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale }
            }
        }
    }
}
