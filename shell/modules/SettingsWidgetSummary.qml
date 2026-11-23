import QtQuick
import QtQuick.Layouts
import qs.shared

BloxButton {
    property string label: ""
    property string summary: ""
    text: summary.length ? label + " · " + summary : label
    elideText: true
    Layout.fillWidth: true
}
