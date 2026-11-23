import QtQuick
import QtQuick.Layouts

NativeView {
    id: root
    readonly property date observedDate: new Date(numeric(observation.epochMs) ? observation.epochMs : 0)
    property int monthOffset: 0
    readonly property date monthDate: new Date(observedDate.getFullYear(), observedDate.getMonth() + monthOffset, 1)
    readonly property int firstWeekday: (monthDate.getDay() + 6) % 7
    readonly property int monthDays: new Date(monthDate.getFullYear(), monthDate.getMonth() + 1, 0).getDate()
    readonly property int cellCount: Math.ceil((firstWeekday + monthDays) / 7) * 7
    readonly property bool showMonth: settings.style !== "agenda"
    readonly property bool splitLayout: fullscreen && width > 850
    readonly property var events: observation.events || []
    contentReady: dataReady && numeric(observation.epochMs) && !!observation.events
                  && typeof observation.events.length === "number" && width > 0 && height > 0
    implicitWidth: 350
    implicitHeight: 360
    function cellDate(index) { return new Date(monthDate.getFullYear(), monthDate.getMonth(), index - firstWeekday + 1); }
    function isToday(date) { return date.getFullYear() === observedDate.getFullYear() && date.getMonth() === observedDate.getMonth() && date.getDate() === observedDate.getDate(); }
    function hasEvent(date) {
        for (let i = 0; i < events.length; i++) {
            const start = new Date(events[i].start);
            if (start.getFullYear() === date.getFullYear() && start.getMonth() === date.getMonth() && start.getDate() === date.getDate()) return true;
        }
        return false;
    }
    RowLayout {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: 32 * root.density
        ColumnLayout {
            visible: root.showMonth
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: root.splitLayout ? 1 : -1
            Layout.maximumWidth: root.fullscreen && !root.splitLayout ? 900 : Infinity
            spacing: root.gap
            RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; text: root.monthDate.toLocaleDateString(Qt.locale("en_GB"), "MMMM yyyy"); color: root.foreground; font.family: root.bodyFont; font.pixelSize: 19 * root.displayScale; elide: Text.ElideRight }
                NativeAction { text: "Open"; iconName: "arrow-square-out"; iconRoot: root.theme ? root.theme.iconRoot : ""; Accessible.name: "Open calendar"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; density: root.density; onClicked: root.actionRequested("open", {}) }
                NativeAction { text: "Previous"; iconName: "caret-left"; iconRoot: root.theme ? root.theme.iconRoot : ""; Accessible.name: "Previous month"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; density: root.density; onClicked: root.monthOffset-- }
                NativeAction { text: "Next"; iconName: "caret-right"; iconRoot: root.theme ? root.theme.iconRoot : ""; Accessible.name: "Next month"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; density: root.density; onClicked: root.monthOffset++ }
            }
            GridLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: 7
                columnSpacing: (root.compactPresentation ? 2 : 4) * root.density
                rowSpacing: (root.compactPresentation ? 2 : 4) * root.density
                Repeater { model: ["M", "T", "W", "T", "F", "S", "S"]
                    Text { required property string modelData; Layout.fillWidth: true; text: modelData; horizontalAlignment: Text.AlignHCenter; color: root.muted; font.family: root.bodyFont; font.pixelSize: 12 * root.displayScale }
                }
                Repeater { model: root.cellCount
                    Rectangle {
                        required property int index
                        readonly property date dayDate: root.cellDate(index)
                        readonly property bool today: root.isToday(dayDate)
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.preferredWidth: 35
                        Layout.minimumHeight: 15
                        color: today ? root.accent : "transparent"
                        radius: Math.min(width / 2, height / 2, 5 * root.rounding)
                        Text { anchors.centerIn: parent; text: parent.dayDate.getDate(); color: parent.today ? root.background : parent.dayDate.getMonth() === root.monthDate.getMonth() ? root.foreground : root.muted; opacity: parent.dayDate.getMonth() === root.monthDate.getMonth() ? 1 : 0.45; font.family: root.bodyFont; font.pixelSize: Math.min((root.compactPresentation ? 13 : 16) * root.displayScale, parent.height * 0.6) }
                        Rectangle { visible: root.hasEvent(parent.dayDate); width: 3 * root.displayScale; height: width; radius: width / 2; color: parent.today ? root.background : root.positive; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 3 }
                    }
                }
            }
        }
        ColumnLayout {
            visible: !root.showMonth || root.splitLayout
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: root.splitLayout ? 1 : -1
            spacing: root.gap
            RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; text: "Agenda"; color: root.foreground; font.family: root.bodyFont; font.pixelSize: 18 * root.displayScale }
                NativeAction { visible: !root.showMonth; text: "Open"; iconName: "arrow-square-out"; iconRoot: root.theme ? root.theme.iconRoot : ""; Accessible.name: "Open calendar"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; density: root.density; onClicked: root.actionRequested("open", {}) }
            }
            NativeScroll {
                id: agendaScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                scrollbarMode: root.scrollbarMode
                contentWidth: availableWidth
                Column {
                    width: agendaScroll.availableWidth
                    spacing: root.gap
                    Repeater { model: root.events
                        RowLayout {
                            required property var modelData
                            width: parent.width
                            spacing: 15 * root.density
                            Text { Layout.preferredWidth: 65 * root.displayScale; text: modelData.allDay ? "All day" : new Date(modelData.start).toLocaleTimeString(Qt.locale("en_GB"), "HH:mm"); color: root.muted; font.family: root.bodyFont; font.pixelSize: 12 * root.displayScale }
                            Rectangle { Layout.preferredWidth: 3; Layout.preferredHeight: (root.compactPresentation ? 28 : 36) * root.displayScale; color: modelData.color || root.accent }
                            Column {
                                Layout.fillWidth: true
                                spacing: 4 * root.density
                                Text { width: parent.width; text: modelData.title; color: root.foreground; font.family: root.bodyFont; font.pixelSize: (root.compactPresentation ? 13 : 15) * root.displayScale; wrapMode: Text.Wrap }
                                Text { width: parent.width; text: new Date(modelData.start).toLocaleDateString(Qt.locale("en_GB"), "ddd d MMM"); color: root.muted; font.family: root.bodyFont; font.pixelSize: 12 * root.displayScale }
                            }
                        }
                    }
                    Text { visible: root.events.length === 0; text: "No events"; color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale }
                }
            }
        }
    }
}
