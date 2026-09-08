import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[1]
MODULE_PATH = REPOSITORY / "shell/scripts/graphicsctl.py"
SPEC = importlib.util.spec_from_file_location("graphicsctl", MODULE_PATH)
graphicsctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(graphicsctl)


def completed(stdout="", returncode=0, stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


INTEGRATED = {"id": "card0", "vendor": "amd", "driver": "amdgpu", "kind": "integrated", "bootVga": True}
DISCRETE = {"id": "card1", "vendor": "nvidia", "driver": "nvidia", "kind": "discrete", "bootVga": False}


class FakeController:
    def __init__(
        self,
        supported="[Integrated, Hybrid, AsusMuxDgpu]",
        current="Hybrid",
        pending_mode="Unknown",
        pending_action="No action required",
    ):
        self.supported = supported
        self.current = current
        self.pending_mode = pending_mode
        self.pending_action = pending_action
        self.calls = []

    def __call__(self, command, timeout=5):
        self.calls.append(command)
        if command[:3] == ["systemctl", "is-active", "--quiet"]:
            return completed(returncode=3)
        if command[:3] == ["busctl", "introspect", "org.freedesktop.login1"]:
            return completed(".ListSessions method - a(susso) -")
        if command == ["supergfxctl", "--supported"]:
            return completed(self.supported)
        if command == ["supergfxctl", "--get"]:
            return completed(self.current)
        if command == ["supergfxctl", "--pend-mode"]:
            return completed(self.pending_mode)
        if command == ["supergfxctl", "--pend-action"]:
            return completed(self.pending_action)
        raise AssertionError(command)


class GraphicsControlTests(unittest.TestCase):
    def test_no_gpu_and_integrated_only_are_non_actionable(self):
        empty = graphicsctl.gpu_snapshot([], has_command=lambda _: False)
        integrated = graphicsctl.gpu_snapshot([INTEGRATED], has_command=lambda _: False)
        self.assertEqual(empty["capability"]["reason"], "no-gpu")
        self.assertEqual(integrated["capability"]["reason"], "no-switchable-gpu")
        self.assertFalse(integrated["capability"]["canChange"])

    def test_dual_gpu_without_approved_controller_stays_hidden(self):
        snapshot = graphicsctl.gpu_snapshot([INTEGRATED, DISCRETE], has_command=lambda _: False)
        self.assertEqual(snapshot["capability"]["reason"], "no-supported-controller")
        self.assertEqual(snapshot["supportedModes"], [])

    def test_boot_inventory_keeps_a_powered_off_discrete_gpu(self):
        log = "\n".join([
            "kernel: pci 0000:64:00.0: [1002:15bf] type 00 class 0x030000 PCIe Legacy Endpoint",
            "kernel: pci 0000:01:00.0: [10de:28a0] type 00 class 0x030000 PCIe Legacy Endpoint",
        ])
        active = dict(INTEGRATED, pciAddress="0000:64:00.0", present=True)
        with patch.object(graphicsctl, "drm_devices", return_value=[active]):
            devices = graphicsctl.discover_gpu_devices(lambda command, timeout=5: completed(log))
        self.assertEqual(len(devices), 2)
        powered_off = next(item for item in devices if item["vendor"] == "nvidia")
        self.assertEqual(powered_off["pciAddress"], "0000:01:00.0")
        self.assertFalse(powered_off["present"])
        snapshot = graphicsctl.gpu_snapshot(devices, has_command=lambda _: False)
        self.assertEqual(snapshot["capability"]["reason"], "no-supported-controller")
        self.assertEqual(snapshot["discreteCount"], 1)
        self.assertFalse(snapshot["gpuOn"])

    def test_approved_controller_maps_public_modes_in_fixed_order(self):
        runner = FakeController(current="AsusMuxDgpu")
        snapshot = graphicsctl.gpu_snapshot([INTEGRATED, DISCRETE], runner, lambda _: True)
        self.assertEqual(snapshot["supportedModes"], ["dedicated", "hybrid", "integrated"])
        self.assertEqual(snapshot["mode"], "dedicated")
        self.assertEqual(snapshot["controllerMode"], "AsusMuxDgpu")
        self.assertTrue(snapshot["capability"]["canChange"])

    def test_active_legacy_switcher_blocks_the_approved_controller(self):
        def runner(command, timeout=5):
            if command[:3] == ["systemctl", "is-active", "--quiet"]:
                return completed(returncode=0 if command[3] == "gpu-eco-boot.service" else 3)
            raise AssertionError(command)

        snapshot = graphicsctl.gpu_snapshot([INTEGRATED, DISCRETE], runner, lambda _: True)
        self.assertEqual(snapshot["capability"]["reason"], "competing-controller-active")
        self.assertEqual(snapshot["capability"]["permission"], "denied")

    def test_controller_without_logind_session_method_stays_hidden(self):
        class IncompatibleController(FakeController):
            def __call__(self, command, timeout=5):
                if command[:3] == ["busctl", "introspect", "org.freedesktop.login1"]:
                    return completed(".Sessions property a(susso) 0 const")
                return super().__call__(command, timeout)

        snapshot = graphicsctl.gpu_snapshot(
            [INTEGRATED, DISCRETE], IncompatibleController(), lambda _: True
        )
        self.assertEqual(snapshot["controller"], "supergfxctl")
        self.assertEqual(snapshot["mode"], "hybrid")
        self.assertEqual(snapshot["capability"]["reason"], "controller-incompatible")
        self.assertFalse(snapshot["capability"]["canChange"])
        self.assertEqual(snapshot["supportedModes"], [])

    def test_pending_controller_state_reports_logout(self):
        snapshot = graphicsctl.gpu_snapshot(
            [INTEGRATED, DISCRETE],
            FakeController(current="Hybrid", pending_mode="Integrated", pending_action="Logout"),
            lambda _: True,
        )
        self.assertEqual(snapshot["pendingMode"], "integrated")
        self.assertEqual(snapshot["pendingAction"], "logout")

    def test_pending_controller_state_can_require_reboot(self):
        snapshot = graphicsctl.gpu_snapshot(
            [INTEGRATED, DISCRETE],
            FakeController(current="Hybrid", pending_mode="Integrated", pending_action="Reboot"),
            lambda _: True,
        )
        self.assertEqual(snapshot["pendingAction"], "reboot")

    def test_discrete_gpu_clients_are_reported_without_polling_the_gpu(self):
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            process = proc_root / "4242"
            (process / "fd").mkdir(parents=True)
            (process / "comm").write_text("gpu-app\n", encoding="utf-8")
            (process / "fd" / "7").symlink_to("/dev/null")
            with patch.object(graphicsctl, "discrete_device_nodes", return_value={Path("/dev/null")}):
                reply = graphicsctl.gpu_clients([], proc_root=proc_root)
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["data"]["count"], 1)
        self.assertEqual(reply["data"]["clients"], [{"pid": 4242, "name": "gpu-app"}])

    def test_mode_change_accepts_pending_logout_without_waiting_for_logout(self):
        controller = FakeController(current="Hybrid")
        events = []

        def runner(command, timeout=5):
            if command == ["supergfxctl", "--mode", "Integrated"]:
                events.append("controller-called")
                controller.pending_mode = "Integrated"
                controller.pending_action = "Logout required to complete mode change"
                return completed("Graphics mode changed to Integrated. Required user action is: Logout required to complete mode change")
            return controller(command, timeout)

        with (
            patch.object(graphicsctl, "discover_gpu_devices", return_value=[INTEGRATED, DISCRETE]),
            patch.object(graphicsctl, "command_exists", return_value=True),
        ):
            reply = graphicsctl.set_gpu_mode(
                "integrated", "hybrid", runner, lambda: events.append("mutation-started")
            )

        self.assertTrue(reply["ok"])
        self.assertTrue(reply["data"]["changed"])
        self.assertEqual(reply["data"]["pendingAction"], "logout")
        self.assertEqual(controller.pending_mode, "Integrated")
        self.assertEqual(events, ["mutation-started", "controller-called"])

    def test_failed_gpu_preflight_never_emits_mutation_started(self):
        events = []
        with (
            patch.object(graphicsctl, "discover_gpu_devices", return_value=[INTEGRATED]),
            patch.object(graphicsctl, "command_exists", return_value=True),
            self.assertRaises(graphicsctl.AdapterError),
        ):
            graphicsctl.set_gpu_mode(
                "integrated", "hybrid", FakeController(), lambda: events.append("started")
            )
        self.assertEqual(events, [])

    def test_blocked_controller_call_starts_logout_after_settle(self):
        events = []

        class Process:
            returncode = 0

            def poll(self):
                return None

            def communicate(self, timeout=None):
                events.append(("communicate", timeout))
                return "changed", ""

        result = graphicsctl.run_controller_then_logout(
            ["supergfxctl", "--mode", "Integrated"],
            ["safe.sh", "logout"],
            popen_factory=lambda *args, **kwargs: Process(),
            logout_launcher=lambda command: events.append(("logout", command)),
            settle=lambda delay: events.append(("settle", delay)),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(events[0], ("settle", 0.75))
        self.assertEqual(events[1], ("logout", ["safe.sh", "logout"]))

    def test_fast_controller_failure_never_starts_logout(self):
        events = []

        class Process:
            returncode = 4

            def poll(self):
                return 4

            def communicate(self):
                return "", "permission denied"

        result = graphicsctl.run_controller_then_logout(
            ["supergfxctl", "--mode", "Integrated"],
            ["safe.sh", "logout"],
            popen_factory=lambda *args, **kwargs: Process(),
            logout_launcher=lambda command: events.append(command),
            settle=lambda delay: None,
        )
        self.assertEqual(result.returncode, 4)
        self.assertEqual(events, [])

    def test_fast_controller_success_starts_logout(self):
        events = []

        class Process:
            returncode = 0

            def poll(self):
                return 0

            def communicate(self):
                return "request accepted", ""

        result = graphicsctl.run_controller_then_logout(
            ["supergfxctl", "--mode", "Integrated"],
            ["safe.sh", "logout"],
            popen_factory=lambda *args, **kwargs: Process(),
            logout_launcher=lambda command: events.append(command),
            settle=lambda delay: None,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(events, [["safe.sh", "logout"]])

    def test_logout_mode_change_does_not_query_controller_after_acceptance(self):
        controller = FakeController(current="Hybrid")
        events = []

        def runner(command, timeout=5):
            if command == ["supergfxctl", "--mode", "Integrated"]:
                events.append("controller-called")
                return completed("request accepted")
            return controller(command, timeout)

        with (
            patch.object(graphicsctl, "discover_gpu_devices", return_value=[INTEGRATED, DISCRETE]),
            patch.object(graphicsctl, "command_exists", return_value=True),
        ):
            reply = graphicsctl.set_gpu_mode(
                "integrated",
                "hybrid",
                runner,
                verify_after=False,
                pending_action_hint="logout",
            )

        self.assertTrue(reply["ok"])
        self.assertEqual(reply["data"]["pendingAction"], "logout")
        self.assertEqual(events, ["controller-called"])
        self.assertEqual(controller.calls[-1], ["supergfxctl", "--pend-action"])

    def test_pending_controller_failure_disables_mode_changes(self):
        class BrokenPending(FakeController):
            def __call__(self, command, timeout=5):
                if command == ["supergfxctl", "--pend-mode"]:
                    return completed(returncode=4, stderr="permission denied")
                return super().__call__(command, timeout)

        snapshot = graphicsctl.gpu_snapshot([INTEGRATED, DISCRETE], BrokenPending(), lambda _: True)
        self.assertFalse(snapshot["capability"]["canChange"])
        self.assertEqual(snapshot["capability"]["permission"], "denied")
        self.assertEqual(snapshot["controlReason"], "denied")

    def test_denied_and_busy_controller_failures_are_typed(self):
        denied = graphicsctl.classify_controller_error(completed(returncode=4, stderr="permission denied"))
        busy = graphicsctl.classify_controller_error(completed(returncode=5, stderr="GPU is busy"))
        self.assertEqual(denied.code, "denied")
        self.assertEqual(busy.code, "busy")

    def test_command_timeout_is_typed(self):
        with patch.object(graphicsctl.subprocess, "run", side_effect=subprocess.TimeoutExpired(["tool"], 5)):
            with self.assertRaises(graphicsctl.AdapterError) as caught:
                graphicsctl.run_command(["tool"])
        self.assertEqual(caught.exception.code, "timeout")

    def test_monitor_modes_use_only_current_resolution(self):
        snapshot = graphicsctl.monitor_snapshot([{
            "name": "renamed-panel", "description": "Panel", "width": 1920, "height": 1080,
            "refreshRate": 60.0, "x": -20, "y": 30, "scale": 1.25, "transform": 2,
            "dpmsStatus": True, "disabled": False,
            "availableModes": ["1920x1080@144.00Hz", "1920x1080@60.00Hz", "1280x720@144.00Hz"],
        }])
        monitor = snapshot["monitors"][0]
        self.assertEqual([item["id"] for item in monitor["rates"]], ["144", "60"])
        self.assertEqual((monitor["x"], monitor["y"], monitor["scale"], monitor["transform"]), (-20, 30, 1.25, 2))
        self.assertEqual(
            graphicsctl.monitor_eval(monitor, 144),
            'hl.monitor({ output = "renamed-panel", mode = "1920x1080@144", position = "-20x30", scale = 1.25, transform = 2 })',
        )

    def test_stale_monitor_preflight_never_mutates(self):
        current = [{
            "name": "panel", "width": 1920, "height": 1080, "refreshRate": 60.0,
            "x": 0, "y": 0, "scale": 1.0, "transform": 0, "dpmsStatus": True,
            "disabled": False, "availableModes": ["1920x1080@144.00Hz", "1920x1080@60.00Hz"],
        }]
        calls = []

        def runner(command, timeout=5):
            calls.append(command)
            return completed(__import__("json").dumps(current))

        expected = graphicsctl.monitor_snapshot(current)["monitors"][0]
        expected["x"] = 10
        with self.assertRaises(graphicsctl.AdapterError) as caught:
            graphicsctl.set_refresh("panel", "144", expected, runner)
        self.assertEqual(caught.exception.code, "stale")
        self.assertEqual(calls, [["hyprctl", "-j", "monitors"]])

    def test_refresh_failure_reports_rollback_state(self):
        raw = [{
            "name": "panel", "width": 1920, "height": 1080, "refreshRate": 60.0,
            "x": 0, "y": 0, "scale": 1.0, "transform": 0, "dpmsStatus": True,
            "disabled": False, "availableModes": ["1920x1080@144.00Hz", "1920x1080@60.00Hz"],
        }]
        expected = graphicsctl.monitor_snapshot(raw)["monitors"][0]
        replies = iter([completed(__import__("json").dumps(raw)), completed(returncode=0), completed(__import__("json").dumps(raw)), completed(returncode=0)])
        with self.assertRaises(graphicsctl.AdapterError) as caught:
            graphicsctl.set_refresh("panel", "144", expected, lambda command, timeout=5: next(replies))
        self.assertEqual(caught.exception.data, {"failedStep": "verify", "rollback": "applied"})


if __name__ == "__main__":
    unittest.main()
