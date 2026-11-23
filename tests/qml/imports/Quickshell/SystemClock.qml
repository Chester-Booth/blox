import QtQuick

QtObject {
    enum Precision { Seconds }
    property int precision: Precision.Seconds
    property date date: new Date()
}
