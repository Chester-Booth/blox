import QtQuick

Text {
    id: root

    property string body: ""

    function plainText(value) {
        return String(value || "").replace(/<[^>]*>/g, "");
    }

    visible: body.length > 0
    text: plainText(body)
    color: Theme.foreground
    font.family: Theme.bodyFontFamily
    font.pixelSize: 12
    wrapMode: Text.Wrap
    elide: Text.ElideRight
}
