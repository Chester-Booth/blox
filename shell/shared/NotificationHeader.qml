import QtQuick

Column {
    id: root

    property string summary: ""
    property string meta: ""

    spacing: Theme.scaledSpacing(1)

    Text {
        width: parent.width
        text: root.summary
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 13
        font.bold: true
        elide: Text.ElideRight
    }

    Text {
        width: parent.width
        visible: root.meta.length > 0
        text: root.meta
        color: Theme.muted
        font.family: Theme.bodyFontFamily
        font.pixelSize: 10
        elide: Text.ElideRight
    }

}
