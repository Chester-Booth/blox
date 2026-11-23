import QtQuick
import QtTest
import "../../shell/modules" as Modules

TestCase {
    id: testCase
    name: "LauncherMainFocusReturn"

    property var target: null
    property var focusReturn: null
    property int closeRequests: 0

    Component {
        id: targetComponent

        QtObject {
            property int restoreRequests: 0

            function restoreTarget() {
                restoreRequests++;
                return true;
            }
        }
    }

    Component {
        id: focusReturnComponent

        Modules.LauncherMainFocusReturn {
            targetController: testCase.target
            onCloseRequested: testCase.closeRequests++
        }
    }

    function init() {
        closeRequests = 0;
        target = targetComponent.createObject(testCase);
        focusReturn = focusReturnComponent.createObject(testCase);
    }

    function cleanup() {
        if (focusReturn) {
            focusReturn.destroy();
            focusReturn = null;
        }
        if (target) {
            target.destroy();
            target = null;
        }
    }

    function test_explicit_dismiss_restores_then_closes() {
        focusReturn.dismiss();
        compare(target.restoreRequests, 1);
        compare(closeRequests, 1);
    }

    function test_dmenu_selection_restores_without_owning_the_close() {
        focusReturn.selectDmenu();
        compare(target.restoreRequests, 1);
        compare(closeRequests, 0);
    }
}
