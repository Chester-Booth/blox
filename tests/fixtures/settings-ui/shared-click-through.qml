import QtQuick
import QtQuick.Window
import QtTest
TestCase {
    name: "BloxExclusiveButton"
    when: windowShown
    property int backgroundClicks: 0
    property int buttonClicks: 0
    Window {
        id: host
        width: 200
        height: 120
        visible: true
        Rectangle {
            anchors.fill: parent
            TapHandler { onTapped: backgroundClicks += 1 }
        }
        BloxButton {
            id: plus
            x: 60; y: 40
            width: 38; height: 38
            compact: true
            text: "+"
            onClicked: buttonClicks += 1
        }
    }
    function test_left_edge_grabs_exclusively() {
        buttonClicks = 0;
        backgroundClicks = 0;
        mouseClick(plus, 2, plus.height / 2, Qt.LeftButton);
        compare(buttonClicks, 1);
        compare(backgroundClicks, 0);
    }
}
