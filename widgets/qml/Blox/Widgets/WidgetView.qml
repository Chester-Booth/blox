import QtQuick

// Views own their content. The host owns placement, visibility and provider lifetime.
Item {
    property var context: ({})
    property var settings: ({})
    property bool fullscreen: false
    property var theme: null
    property var snapshot: null
    property bool contentReady: false
    signal actionRequested(string action, var payload)
    signal readinessChanged()
    onContentReadyChanged: readinessChanged()
}
