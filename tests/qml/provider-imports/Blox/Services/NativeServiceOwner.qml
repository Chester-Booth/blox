import QtQuick

// Provider tests inject owner events here. The native implementation has separate
// integration coverage with actual service ownership on a private D-Bus.
QtObject {
    objectName: "native-service-owner-fixture"
    property string service: ""
    property string alternateService: ""
    property bool enabled: true
    property string fixtureOwner: ""
    property bool fixtureReady: false
    readonly property string owner: fixtureOwner
    readonly property bool ready: fixtureReady
    readonly property bool available: !enabled || (ready && owner.length > 0)
    signal serviceFound()

    function setOwner(value) {
        const changed = fixtureOwner !== value;
        fixtureReady = true;
        fixtureOwner = value;
        if (changed && value.length > 0) serviceFound();
    }
    function refresh() {}
    onEnabledChanged: {
        if (!enabled) {
            fixtureOwner = "";
            fixtureReady = false;
        }
    }
}
