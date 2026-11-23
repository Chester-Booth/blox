import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    contentReady: width > 0 && height > 0
    implicitWidth: 360
    implicitHeight: 300
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.gap
        RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; text: root.settings.title || "Notes"; color: root.foreground; font.family: root.bodyFont; font.pixelSize: (root.compactPresentation ? 21 : 25) * root.displayScale; elide: Text.ElideRight }
            NativeAction { objectName: "notes-edit-button"; text: "Edit"; iconName: "pencil-simple"; iconRoot: root.theme ? root.theme.iconRoot : ""; Accessible.name: "Edit note"; foreground: root.muted; accent: root.accent; rounding: root.rounding; density: root.density; onClicked: root.actionRequested("edit", {}) }
        }
        NativeScroll {
            id: noteScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            scrollbarMode: root.scrollbarMode
            contentWidth: availableWidth
            Text {
                width: noteScroll.availableWidth
                text: root.settings.text || ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.bodyFont
                font.pixelSize: (root.compactPresentation ? 13 : 15) * root.displayScale
                lineHeight: 1.35
                wrapMode: Text.Wrap
            }
        }
    }
}
