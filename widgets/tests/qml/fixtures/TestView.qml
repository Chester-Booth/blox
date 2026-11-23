import QtQuick
import Blox.Widgets 1.0
WidgetView {
    contentReady: snapshot !== null && snapshot.state === "ready" && snapshot.value.resourceReady === true
    property int completedGeneration: -1
    Component.onCompleted: completedGeneration = context.generation
}
