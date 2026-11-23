import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property var samples: []
    property string valueKey: ""
    property real maximum: 100
    property color stroke: "#89b4fa"
    clip: true
    readonly property string pathData: {
        if (!visible || !samples || samples.length < 2 || maximum <= 0) return "";
        let path = "", connected = false;
        for (let i = 0; i < samples.length; i++) {
            const value = valueKey ? samples[i] && samples[i][valueKey] : samples[i];
            if (typeof value !== "number" || !isFinite(value)) { connected = false; continue; }
            const x = i * width / (samples.length - 1);
            const y = height - 2 - Math.max(0, Math.min(1, value / maximum)) * Math.max(0, height - 4);
            path += (connected ? " L " : " M ") + x + " " + y;
            connected = true;
        }
        return path;
    }
    Shape {
        anchors.fill: parent
        asynchronous: false
        antialiasing: true
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.stroke
            strokeWidth: 2
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.FlatCap
            PathSvg { path: root.pathData }
        }
    }
}
