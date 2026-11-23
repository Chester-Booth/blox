import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    readonly property string condition: {
        const code = observation.weatherCode;
        if (code === 0) return observation.isDay === false ? "Clear night" : "Clear";
        if (code === 1 || code === 2) return "Partly cloudy";
        if (code === 3) return "Cloudy";
        if (code === 45 || code === 48) return "Fog";
        if ([51, 53, 55, 56, 57].indexOf(code) >= 0) return "Drizzle";
        if ([61, 63, 65, 66, 67, 80, 81, 82].indexOf(code) >= 0) return "Rain";
        if ([71, 73, 75, 77, 85, 86].indexOf(code) >= 0) return "Snow";
        if ([95, 96, 99].indexOf(code) >= 0) return "Thunderstorm";
        return "Conditions unavailable";
    }

    contentReady: dataReady && numeric(observation.temperatureC) && width > 0 && height > 0
    implicitWidth: 300
    implicitHeight: 220
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.max(0, Math.min(parent.width - root.padding * 2, 700))
        spacing: root.gap
        RowLayout {
            Layout.fillWidth: true
            spacing: root.gap
            NativeIcon {
                visible: root.condition === "Clear"
                name: "sun"
                iconRoot: root.theme ? root.theme.iconRoot : ""
                tint: root.accent
                Layout.preferredWidth: Math.min((root.compactPresentation ? 44 : 64) * root.displayScale, root.width * 0.23)
                Layout.preferredHeight: width
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2 * root.density
                Text { text: root.numberText(root.observation.temperatureC, "°"); color: root.foreground; font.family: root.bodyFont; font.weight: Font.Normal; font.pixelSize: Math.min((root.compactPresentation ? 48 : 64) * root.displayScale, root.width * 0.2) }
                Text { Layout.fillWidth: true; text: root.condition; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale; elide: Text.ElideRight }
            }
        }
        Text { Layout.fillWidth: true; text: "Wind " + root.numberText(root.observation.windSpeedKph, " km/h"); color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale }
    }
}
