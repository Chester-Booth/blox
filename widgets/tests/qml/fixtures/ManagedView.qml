import QtQuick
import Blox.Widgets 1.0

WidgetView {
    contentReady: snapshot !== null && snapshot.state === "ready" && settings.resourcesReady !== false
    Component.onCompleted: {
        var requests = settings.requests || [];
        for (var i = 0; i < requests.length; ++i) {
            var request = requests[i];
            context.requestData(request.name, request.options || {}, request.required);
        }
    }
}
