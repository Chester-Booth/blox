from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]


class NotificationRuntimeTests(unittest.TestCase):
    def test_shared_notification_actions_hide_blank_labels(self) -> None:
        content = (
            REPOSITORY
            / "shell/shared/NotificationContent.qml"
        ).read_text(encoding="utf-8")

        refresh = content.split("function refreshActions()", 1)[1].split(
            "function actionIcon", 1
        )[0]
        self.assertIn('String(actions[i].text || "").trim().length > 0', refresh)
        self.assertIn('actions[i].identifier !== "default"', refresh)

    def test_notification_action_buttons_focus_the_source(self) -> None:
        content = (
            REPOSITORY
            / "shell/shared/NotificationContent.qml"
        ).read_text(encoding="utf-8")
        toast_surface = (
            REPOSITORY
            / "shell/popouts/BarNotificationToastSurface.qml"
        ).read_text(encoding="utf-8")

        action_click = content.split("id: actionMouse", 1)[1].split("}", 2)[0]
        self.assertIn("root.actionInvoked(root.notification)", action_click)
        self.assertIn(
            "root.notificationController.focusSource(notification)", toast_surface
        )

    def test_notification_focus_ships_no_machine_specific_helper(self) -> None:
        # The focus helper is user policy (Hyprland scripts live outside this
        # repository). The shell must opt in through the environment and treat
        # an unset script as a disabled feature.
        bar = (REPOSITORY / "shell/modules/Bar.qml").read_text(encoding="utf-8")
        controller = (REPOSITORY / "shell/services/NotificationController.qml").read_text(encoding="utf-8")

        self.assertNotIn("/home/", bar)
        self.assertIn('Quickshell.env("BLOX_NOTIFICATION_FOCUS_SCRIPT")', bar)
        self.assertIn("focusScript.length === 0", controller)

    def test_notification_card_invokes_the_default_action(self) -> None:
        notification_surface = (
            REPOSITORY
            / "shell/popouts/BarNotificationSurface.qml"
        ).read_text(encoding="utf-8")
        toast_surface = (
            REPOSITORY
            / "shell/popouts/BarNotificationToastSurface.qml"
        ).read_text(encoding="utf-8")
        controller = (
            REPOSITORY
            / "shell/services/NotificationController.qml"
        ).read_text(encoding="utf-8")

        activate = controller.split("function activate(notification)", 1)[1].split(
            "function focusSource", 1
        )[0]
        self.assertIn('actions[i].identifier === "default"', activate)
        self.assertIn("actions[i].invoke()", activate)
        self.assertIn("focusSource(notification)", activate)
        self.assertIn(
            "root.notificationController.activate(notification)", toast_surface
        )
        self.assertIn(
            "root.notificationController.activate(notification)", notification_surface
        )

    def test_dnd_toggle_updates_persistent_ui_state(self) -> None:
        controller = (
            REPOSITORY
            / "shell/services/NotificationController.qml"
        ).read_text(encoding="utf-8")
        toggle = controller.split("function toggleDnd()", 1)[1].split(
            "function activate", 1
        )[0]

        self.assertIn(
            "persistentState.notificationDnd = !persistentState.notificationDnd",
            toggle,
        )
        self.assertIn("root.toggleDnd()", controller)

    def test_shared_notification_images_use_a_left_thumbnail(self) -> None:
        content = (
            REPOSITORY
            / "shell/shared/NotificationContent.qml"
        ).read_text(encoding="utf-8")

        row = content.split("id: notificationRow", 1)[1].split("Flow {", 1)[0]
        self.assertIn("id: notificationThumbnail", row)
        self.assertIn("width: visible ? 72 : 0", row)
        self.assertIn("height: visible ? 72 : 0", row)
        self.assertIn("fillMode: Image.PreserveAspectFit", row)
        self.assertIn(
            "width: parent.width - notificationThumbnail.width - parent.spacing", row
        )
        self.assertNotIn("Math.min(150", content)
        self.assertNotIn("Image.PreserveAspectCrop", content)

    def test_toast_bounds_match_the_visible_card(self) -> None:
        stack = (
            REPOSITORY
            / "shell/popouts/NotificationToastStack.qml"
        ).read_text(encoding="utf-8")

        self.assertIn("width: toastWidth", stack)
        self.assertIn("height: implicitHeight", stack)
        self.assertIn("x: 0", stack)
        self.assertNotIn("width: visibleWidth + dismissTravel", stack)
        self.assertNotIn("x: root.dismissTravel + root.sidePadding", stack)

    def test_animated_toasts_start_with_their_full_lifetime(self) -> None:
        stack = (
            REPOSITORY
            / "shell/popouts/NotificationToastStack.qml"
        ).read_text(encoding="utf-8")

        completed = stack.split("Component.onCompleted:", 1)[1].split(
            "Timer {", 1
        )[0]
        expiry_timer = stack.split("id: expiryTimer", 1)[1].split(
            "NotificationContent {", 1
        )[0]

        self.assertIn(
            "toast.startExpiry(animateHorizontalMovement ? fullLifetime : remainingLifetime)",
            completed,
        )
        self.assertNotIn("running:", expiry_timer)

    def test_hover_pauses_toast_expiry_and_shows_its_click_action(self) -> None:
        stack = (
            REPOSITORY
            / "shell/popouts/NotificationToastStack.qml"
        ).read_text(encoding="utf-8")
        controller = (
            REPOSITORY
            / "shell/services/NotificationController.qml"
        ).read_text(encoding="utf-8")

        hover = stack.split("id: toastHover", 1)[1].split("NotificationContent", 1)[0]
        self.assertIn("toast.pauseExpiry()", hover)
        self.assertIn("toast.resumeExpiry()", hover)
        self.assertIn("BloxToolTip {", stack)
        self.assertIn("text: toast.clickTooltip", stack)
        self.assertIn("x: toastHover.point.position.x", stack)
        self.assertIn("y: toastHover.point.position.y", stack)
        self.assertIn('preferredPlacement: "top-right"', stack)
        self.assertIn('return label.length > 0 ? label : "Open"', controller)
        self.assertIn('return canFocusSource(notification) ? "Focus" : ""', controller)

    def test_position_preview_uses_a_real_desktop_notification(self) -> None:
        controller = (
            REPOSITORY
            / "shell/services/NotificationController.qml"
        ).read_text(encoding="utf-8")
        preview = controller.split(
            "function onNotificationPositionPreviewRequested()", 1
        )[1].split("target: Theme", 1)[0]

        self.assertIn('Quickshell.execDetached(["notify-send"', preview)
        self.assertIn('"Previewing " + Theme.notificationPosition', preview)
        self.assertNotIn("notificationPositionPreviewWindow", controller)

    def test_full_screen_toast_surface_only_accepts_input_on_the_stack(self) -> None:
        surface = (
            REPOSITORY
            / "shell/popouts/BarNotificationToastSurface.qml"
        ).read_text(encoding="utf-8")

        self.assertIn("implicitWidth: targetScreen ? targetScreen.width : 1", surface)
        self.assertIn("implicitHeight: targetScreen ? targetScreen.height : 1", surface)
        self.assertIn("left: true", surface)
        self.assertIn("right: true", surface)
        self.assertIn("mask: Region {", surface)
        self.assertIn("x: notificationToasts.x", surface)
        self.assertIn("y: notificationToasts.y", surface)
        self.assertIn("width: notificationToasts.width", surface)
        self.assertIn("height: notificationToasts.height", surface)
        self.assertNotIn("item: notificationToasts", surface)
        self.assertIn("x: root.onLeft ? 12 + Theme.notificationOffsetX", surface)
        self.assertIn("y: root.onTop ? 12 + Theme.notificationOffsetY", surface)
        self.assertNotIn("anchors.left: root.onLeft", surface)


if __name__ == "__main__":
    unittest.main()
