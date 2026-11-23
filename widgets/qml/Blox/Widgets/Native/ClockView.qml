import QtQuick

NativeView {
    id: root
    readonly property bool analogue: settings.style === "analogue"
    readonly property int hours: numeric(observation.hour) ? observation.hour : 0
    readonly property int minutes: numeric(observation.minute) ? observation.minute : 0
    readonly property int seconds: numeric(observation.second) ? observation.second : 0
    readonly property date dateValue: numeric(observation.year) && numeric(observation.month) && numeric(observation.day)
                                          ? new Date(observation.year, observation.month - 1, observation.day)
                                          : new Date(numeric(observation.epochMs) ? observation.epochMs : 0)
    readonly property string timeText: {
        const h = settings.format === "12h" ? (hours % 12 || 12) : hours;
        return (settings.format === "12h" ? String(h) : padded(h)) + ":" + padded(minutes)
                + (settings.showSeconds ? ":" + padded(seconds) : "")
                + (settings.format === "12h" ? (hours < 12 ? " am" : " pm") : "");
    }
    readonly property string dateText: dateValue.toLocaleDateString(Qt.locale("en_GB"), "dddd, d MMMM")
    contentReady: dataReady && numeric(observation.epochMs) && numeric(observation.hour)
                  && numeric(observation.minute) && numeric(observation.second) && width > 0 && height > 0
    implicitWidth: 360
    implicitHeight: 220
    function padded(value) { return String(value).padStart(2, "0"); }
    Column {
        visible: !root.analogue
        anchors.centerIn: parent
        width: Math.max(0, parent.width - root.padding * 2)
        spacing: root.gap
        Text { width: parent.width; text: root.timeText; color: root.foreground; font.family: root.bodyFont; font.weight: Font.Normal; font.pixelSize: Math.min(root.height * (root.compactPresentation ? 0.31 : 0.38), root.width / (root.settings.showSeconds ? 6.2 : 4.4)); horizontalAlignment: Text.AlignLeft; fontSizeMode: Text.Fit; minimumPixelSize: 10 }
        Text { width: parent.width; text: root.dateText; color: root.muted; font.family: root.bodyFont; font.pixelSize: Math.min(root.baseSize * root.displayScale, root.width / 17); horizontalAlignment: Text.AlignLeft; elide: Text.ElideRight }
    }
    Item {
        id: face
        readonly property real faceRadius: width * 0.43
        visible: root.analogue
        anchors.centerIn: parent
        width: Math.max(0, Math.min(root.width - root.padding * 2, root.height - root.padding * 2))
        height: width
        // Retained ticks and hands enter the first scene graph without a Canvas upload.
        Repeater {
            model: root.analogue ? 60 : 0
            Rectangle {
                required property int index
                readonly property real angle: index * Math.PI / 30
                readonly property real tickLength: face.faceRadius * (index % 5 === 0 ? 0.09 : 0.04)
                width: index % 5 === 0 ? 2 : 1
                height: tickLength
                x: face.width / 2 + Math.sin(angle) * (face.faceRadius - tickLength / 2) - width / 2
                y: face.height / 2 - Math.cos(angle) * (face.faceRadius - tickLength / 2) - height / 2
                rotation: index * 6
                color: index % 5 === 0 ? root.foreground : root.borderColour
                antialiasing: true
            }
        }
        component Hand: Item {
            property real length: 0
            property real thickness: 1
            property color stroke: root.foreground
            anchors.centerIn: parent
            width: 0; height: 0
            Rectangle { x: -width / 2; y: -parent.length - parent.thickness / 2; width: parent.thickness; height: parent.length + parent.thickness; radius: width / 2; color: parent.stroke; antialiasing: true }
        }
        Hand { length: face.faceRadius * 0.5; thickness: Math.max(3, face.faceRadius * 0.035); rotation: (root.hours % 12 + root.minutes / 60) * 30 }
        Hand { length: face.faceRadius * 0.75; thickness: Math.max(2, face.faceRadius * 0.022); rotation: (root.minutes + root.seconds / 60) * 6 }
        Hand { visible: root.settings.showSeconds === true; length: face.faceRadius * 0.84; thickness: Math.max(1, face.faceRadius * 0.009); stroke: root.accent; rotation: root.seconds * 6 }
        Rectangle { anchors.centerIn: parent; width: Math.max(6, face.faceRadius * 0.07); height: width; radius: width / 2; color: root.accent; antialiasing: true }
        Text { anchors.horizontalCenter: parent.horizontalCenter; y: parent.height * 0.68; width: parent.width * 0.65; text: root.dateText; color: root.muted; font.family: root.bodyFont; font.pixelSize: Math.min(root.baseSize * root.displayScale, parent.width / 19); horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
    }
}
