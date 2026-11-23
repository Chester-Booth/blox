import QtQuick

QtObject {
    enum Precision { Seconds, Minutes, Hours }
    property bool enabled: true
    property int precision: Precision.Seconds
    property date date: new Date()
}
