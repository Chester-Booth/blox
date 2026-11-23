import QtQuick
import QtQuick.Layouts
import qs.shared as Shared

ColumnLayout {
    id: root

    required property var card
    property string subtitle: ""
    property bool incoming: false
    property bool active: false

    spacing: Shared.Theme.scaledSpacing(4)

    SettingsThemeCard {
        Layout.fillWidth: true
        Layout.preferredHeight: 82
        themeData: root.card
        active: root.active
        selected: true
        readOnly: true
    }

    Text {
        Layout.fillWidth: true
        visible: root.subtitle.length > 0
        text: root.subtitle
        color: root.incoming ? Shared.Theme.blue : Shared.Theme.muted
        font.family: Shared.Theme.bodyFontFamily
        font.pixelSize: 11
        elide: Text.ElideRight
    }
}
