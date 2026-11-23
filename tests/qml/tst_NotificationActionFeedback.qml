import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/services" as Services
import "../../shell/popouts" as Popouts

TestCase {
    id: testCase
    name: "NotificationActionFeedback"
    property var testWindow: null

    QtObject {
        id: notificationOne
        property int id: 0
        property string appName: "Example"
        property string desktopEntry: "example.desktop"
        property string summary: ""
        property string body: "A notification body"
        property var hints: ({})
        property var actions: []
        property bool hasActionIcons: false
        property bool tracked: false
        property bool bloxToastKnown: false
        property double bloxReceivedAt: 0
        signal closed()
        function dismiss() {}
    }

    QtObject {
        id: notificationTwo
        property int id: 0
        property string appName: "Example"
        property string desktopEntry: "example.desktop"
        property string summary: ""
        property string body: "A notification body"
        property var hints: ({})
        property var actions: []
        property bool hasActionIcons: false
        property bool tracked: false
        property bool bloxToastKnown: false
        property double bloxReceivedAt: 0
        signal closed()
        function dismiss() {}
    }

    function makeNotification(notification, id, summary) {
        notification.id = id;
        notification.summary = summary;
        const action = {
            identifier: "default",
            text: "Open",
            invocations: 0
        };
        action.invoke = function() { action.invocations += 1; };
        notification.actions = [action];
        return action;
    }

    function errorFor(notificationId) {
        const repeater = findChild(testWindow, "notification-card-repeater");
        if (!repeater)
            return null;
        for (let index = 0; index < repeater.count; index++) {
            const card = repeater.itemAt(index);
            if (card && Number(card.notification.id) === Number(notificationId))
                return findChild(card, "notificationActionError-" + notificationId);
        }
        return null;
    }

    Services.NotificationController {
        id: controller

        focusScript: "/isolated/focus-notification"
    }

    Component {
        id: notificationCentreWindow

        Window {
            width: 400
            height: 480
            visible: true

            Popouts.NotificationCenterPopout {
                objectName: "notificationCentre"
                actionResult: controller.actionResult
            }
        }
    }

    function init() {
        testWindow = notificationCentreWindow.createObject(testCase);
        const process = findChild(controller, "notification-focus-process");
        verify(process !== null);
        process.running = false;
        controller.sourceFocusNotificationId = -1;
        controller.sourceFocusNotificationDismissed = false;
        controller.actionResult = {version: 1, ok: true, code: "ok", message: "", data: null};
        controller.items = [];
        const centre = findChild(testWindow, "notificationCentre");
        centre.notifications = [];
    }

    function cleanup() {
        if (testWindow) {
            testWindow.close();
            testWindow.destroy();
            testWindow = null;
        }
    }

    function test_focus_failure_is_visible_and_success_clears_it() {
        const notification = notificationOne;
        const action = makeNotification(notification, 12, "A message");
        const process = findChild(controller, "notification-focus-process");
        const notificationCentre = findChild(testWindow, "notificationCentre");
        notificationCentre.notifications = [notification];
        controller.items = [notification];
        const cardRepeater = findChild(testWindow, "notification-card-repeater");
        verify(cardRepeater);
        tryCompare(cardRepeater, "count", 1);
        tryVerify(() => !!errorFor(12));
        const errorText = errorFor(12);

        verify(process !== null);
        verify(notificationCentre !== null);
        verify(errorText !== null);
        compare(controller.activate(notification).code, "pending");
        compare(action.invocations, 1);
        verify(process.running);

        process.finish(126, 0);
        compare(controller.actionResult.code, "permission-denied");
        verify(!controller.actionResult.ok);
        compare(controller.actionResult.data.exitCode, 126);
        compare(controller.actionResult.data.exitStatus, 0);
        compare(notificationCentre.actionResult.code, "permission-denied");
        tryCompare(errorText, "visible", true);
        compare(errorText.text, "The notification focus helper could not be run.");

        compare(controller.activate(notification).code, "pending");
        compare(action.invocations, 2);
        process.finish(0, 0);
        compare(controller.actionResult.code, "ok");
        verify(controller.actionResult.ok);
        tryCompare(errorText, "visible", false);
        compare(errorText.text, "");
    }

    function test_busy_focus_does_not_dispatch_second_notification_action() {
        const first = notificationOne;
        const second = notificationTwo;
        const firstAction = makeNotification(first, 21, "First message");
        const secondAction = makeNotification(second, 22, "Second message");
        const process = findChild(controller, "notification-focus-process");
        const notificationCentre = findChild(testWindow, "notificationCentre");
        notificationCentre.notifications = [first, second];
        controller.items = [first, second];
        tryVerify(() => !!errorFor(21) && !!errorFor(22));

        compare(controller.activate(first).code, "pending");
        compare(firstAction.invocations, 1);
        verify(process.running);
        compare(controller.sourceFocusNotificationId, 21);

        const repeated = controller.activate(first);
        compare(repeated.code, "busy");
        compare(repeated.data.notificationId, 21);
        compare(firstAction.invocations, 1);

        const busy = controller.activate(second);
        compare(busy.code, "busy");
        verify(!busy.ok);
        compare(busy.data.operation, "notification-action");
        compare(busy.data.notificationId, 22);
        compare(busy.data.sourceFocusNotificationId, 21);
        compare(secondAction.invocations, 0);
        compare(controller.sourceFocusNotificationId, 21);

        const firstError = errorFor(21);
        const secondError = errorFor(22);
        verify(firstError);
        verify(secondError);
        tryCompare(secondError, "visible", true);

        process.finish(126, 0);
        compare(controller.actionResult.code, "permission-denied");
        compare(controller.actionResult.data.notificationId, 21);
        tryCompare(firstError, "visible", true);
        tryCompare(secondError, "visible", false);
        compare(firstAction.invocations, 1);
        compare(secondAction.invocations, 0);

        compare(controller.activate(second).code, "pending");
        compare(secondAction.invocations, 1);
        compare(controller.actionResult.data.notificationId, 22);
        process.finish(0, 0);
        compare(controller.actionResult.code, "ok");
        compare(controller.actionResult.data.notificationId, 22);
        tryCompare(firstError, "visible", false);
        tryCompare(secondError, "visible", false);
    }

    function test_dismissal_clears_and_suppresses_focus_feedback() {
        const dismissed = notificationOne;
        makeNotification(dismissed, 31, "Dismissed message");
        const process = findChild(controller, "notification-focus-process");
        const notificationCentre = findChild(testWindow, "notificationCentre");
        notificationCentre.notifications = [dismissed];
        controller.items = [dismissed];
        tryVerify(() => !!errorFor(31));
        const errorText = errorFor(31);
        verify(errorText);

        compare(controller.activate(dismissed).code, "pending");
        process.finish(126, 0);
        tryCompare(errorText, "visible", true);
        compare(controller.actionResult.data.notificationId, 31);

        controller.clear();
        notificationCentre.notifications = [];
        controller.items = [];
        compare(controller.actionResult.code, "ok");
        tryCompare(errorText, "visible", false);

        const clearedWhilePending = notificationTwo;
        makeNotification(clearedWhilePending, 32, "Cleared message");
        notificationCentre.notifications = [clearedWhilePending];
        controller.items = [clearedWhilePending];
        tryVerify(() => !!errorFor(32));
        const clearedError = errorFor(32);
        verify(clearedError);
        compare(controller.activate(clearedWhilePending).code, "pending");
        controller.clear();
        notificationCentre.notifications = [];
        controller.items = [];
        process.finish(126, 0);
        compare(controller.actionResult.code, "ok");
        verify(controller.actionResult.ok);
        tryCompare(clearedError, "visible", false);

        const owner = notificationOne;
        const contender = notificationTwo;
        makeNotification(owner, 33, "Owner message");
        makeNotification(contender, 34, "Contender message");
        notificationCentre.notifications = [owner, contender];
        controller.items = [owner, contender];
        tryVerify(() => !!errorFor(33) && !!errorFor(34));
        compare(controller.activate(owner).code, "pending");
        compare(controller.activate(contender).code, "busy");
        const contenderError = errorFor(34);
        tryCompare(contenderError, "visible", true);

        controller.notificationDismissed(owner);
        notificationCentre.notifications = [contender];
        controller.items = [contender];
        process.finish(126, 0);
        compare(controller.actionResult.code, "ok");
        verify(controller.actionResult.ok);
        compare(controller.actionResult.data, null);
        tryCompare(contenderError, "visible", false);
    }
}
