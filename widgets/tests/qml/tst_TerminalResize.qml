import QtQuick
import QtTest
import Blox.Widgets 1.0
import "../../qml/Blox/Widgets/Native" as Native
import "../fixtures" as Fixtures

TestCase {
    id: test
    name: "TerminalResize"
    when: windowShown
    visible: true
    width: 1200
    height: 800

    WidgetTheme { id: widgetTheme }
    Fixtures.TerminalFixtureDecoder { id: decoder }
    Component { id: terminalComponent; Native.TerminalView {} }
    property var terminal: null
    property int revision: 0
    SignalSpy { id: actions; signalName: "actionRequested" }
    Timer {
        id: stream
        interval: 16
        repeat: true
        onTriggered: test.publish()
    }

    function publish(columns, rows) {
        revision++;
        terminal.snapshot = decoder.adapt("fixture", {state: "ready", revision: revision, value: {
            generation: 1, sequence: revision, columns: columns || 40, rowCount: rows || 3,
            rows: [{runs: [{column: 0, cells: ["x"], text: "x"}]}], changedRuns: []}});
    }
    function init() {
        failOnWarning(/.*/);
        revision = 0;
        decoder.reset();
        widgetTheme.densityScale = 1;
        widgetTheme.fontSize = 14;
        terminal = terminalComponent.createObject(test, {width: 600, height: 600,
            theme: widgetTheme, settings: {columns: 40, rows: 3}, context: {fullscreenMode: "resize"}});
        verify(terminal !== null);
        actions.target = terminal;
        actions.clear();
        publish();
    }
    function cleanup() {
        stream.stop();
        actions.target = null;
        terminal.destroy();
        terminal = null;
        wait(0);
    }
    function test_snapshotsCannotPostponeResizeOrRepeatUnchangedRequest() {
        terminal.fullscreen = true;
        stream.start();
        tryCompare(actions, "count", 1, 200);
        const size = actions.signalArguments[0][1];
        compare(actions.signalArguments[0][0], "resize");
        verify(size.columns > 40);
        wait(100);
        compare(actions.count, 1);
        publish(size.columns, size.rows);
        wait(30);
        compare(actions.count, 1);
        terminal.width = 900;
        tryCompare(actions, "count", 2, 200);
        verify(actions.signalArguments[1][1].columns > size.columns);
        wait(60);
        compare(actions.count, 2);
    }
    function test_densityChangeDuringContinuousSnapshotsQueuesOnce() {
        terminal.fullscreen = true;
        tryCompare(actions, "count", 1);
        stream.start();
        widgetTheme.densityScale = 1.5;
        tryCompare(actions, "count", 2, 200);
        verify(actions.signalArguments[1][1].columns < actions.signalArguments[0][1].columns);
        wait(100);
        compare(actions.count, 2);
    }
    function test_leaveResizeRestoresConfiguredDimensionsBeforeAcknowledgement() {
        terminal.fullscreen = true;
        tryCompare(actions, "count", 1);
        // The old configured frame is still observed when the resize is undone.
        terminal.fullscreen = false;
        tryCompare(actions, "count", 2);
        compare(actions.signalArguments[1][1].columns, 40);
        compare(actions.signalArguments[1][1].rows, 3);
        stream.start();
        wait(80);
        compare(actions.count, 2);
    }
    function test_initialFrameAndFontChangeAndLeavingMode() {
        terminal.fullscreen = true;
        tryCompare(actions, "count", 1);
        widgetTheme.fontSize = 24;
        tryCompare(actions, "count", 2);
        terminal.context = {fullscreenMode: "fit"};
        tryCompare(actions, "count", 3);
        compare(actions.signalArguments[2][1].columns, 40);
        compare(actions.signalArguments[2][1].rows, 3);
        widgetTheme.fontSize = 14;
        wait(40);
        compare(actions.count, 3);
    }
}
