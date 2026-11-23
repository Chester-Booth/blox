import json
import os
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "shell/scripts/status/vendor-performance.sh"
CAPTURE = ROOT / "shell/scripts/status/asusctl-query.py"

FAKE = r'''#!/usr/bin/env python3
import json, os, resource, signal, stat, subprocess, sys, time

def record(event, **values):
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(json.dumps(dict(event=event, pid=os.getpid(), **values)) + "\n")

args = sys.argv[1:]
assert args in [["profile", "list"], ["profile", "get"], ["fan-curve", "--get-enabled"]], args
for fd in (1, 2):
    info = os.fstat(fd)
    assert stat.S_ISREG(info.st_mode)
    assert stat.S_IMODE(info.st_mode) == 0o600
    assert info.st_nlink == 0
assert resource.getrlimit(resource.RLIMIT_FSIZE) == (65536, 65536)
record("call", args=args, group=os.getpgrp())
mode = os.environ.get("FAKE_MODE", "success")
if mode == "slow":
    time.sleep(1.7)
if mode == "slow-then-hang":
    time.sleep(1.7 if args[0] == "profile" else 30)
if args == ["profile", "list"]:
    if mode == "fail":
        print("failed printing to stdout: simulated I/O reason", file=sys.stderr)
        sys.exit(134)
    if mode == "full-stderr":
        os.write(2, b"x" * 65536)
        record("stderr-full")
        time.sleep(30)
    if mode == "exit-with-descendant":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        record("ready-to-exit", child=child.pid)
        while not os.path.exists(os.environ["FAKE_EXIT"]): time.sleep(0.01)
    if mode in ("hang", "descendant"):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            record("descendant")
            while True: time.sleep(1)
        if mode == "hang":
            while True: time.sleep(1)
    if mode == "overflow":
        try:
            while True: os.write(1, b"x" * 8192)
        except OSError:
            record("limited", size=os.fstat(1).st_size)
            sys.exit(1)
    if mode == "closed":
        os.write(1, b" " * 8192)
        record("writing")
        time.sleep(0.2)
        os.write(1, b" " * 8192 + b"\n")
        record("write-succeeded")
    if mode != "empty": print("Quiet\nBalanced\nLow Power  ")
elif args == ["profile", "get"]:
    print("unrecognised" if mode == "malformed" else "Active profile: Low Power")
else:
    # The old fan probe deliberately parsed combined stdout and stderr.
    print(os.environ.get("FAKE_FAN", "CPU: enabled: true"), file=sys.stderr)
    if mode == "fanfail": sys.exit(1)
'''


class AsusctlCaptureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="blox-asusctl-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake = fake_bin / "asusctl"
        fake.write_text(FAKE)
        fake.chmod(0o700)
        self.log = self.root / "calls.jsonl"
        self.temporary_files = self.root / "tmp"
        self.temporary_files.mkdir()
        self.env = dict(os.environ, PATH=f"{fake_bin}:/usr/bin:/bin",
                        TMPDIR=str(self.temporary_files), FAKE_LOG=str(self.log))
        self.addCleanup(self.clean_processes)

    def events(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def clean_processes(self):
        # Confine emergency test cleanup to groups recorded by our fake command.
        for group in {event["group"] for event in self.events() if "group" in event}:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def wait_for(self, condition, seconds=4):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail("condition did not complete before its deadline")

    def running(self, pid):
        try:
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            return state != "Z"
        except FileNotFoundError:
            return False

    def assert_clean(self):
        self.wait_for(lambda: all(not self.running(event["pid"]) for event in self.events()))
        self.assertEqual([], list(self.temporary_files.iterdir()))

    def start(self, mode="success", capture=False):
        command = ["python3", str(CAPTURE), "profile", "list"] if capture else ["bash", str(STATUS)]
        process = subprocess.Popen(command, env=dict(self.env, FAKE_MODE=mode),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        return process

    def status(self, mode="success", **environment):
        self.env.update(environment)
        process = self.start(mode)
        output, errors = process.communicate(timeout=9)
        self.assertEqual(0, process.returncode, errors)
        self.assert_clean()
        return json.loads(output), errors.decode()

    def test_profile_and_combined_fan_parsing_keep_the_contract(self):
        payload, errors = self.status()
        self.assertEqual("", errors)
        self.assertEqual("low-power", payload["profile"])
        self.assertEqual("Low Power", payload["profileLabel"])
        self.assertEqual(["quiet", "balanced", "low-power"], payload["profiles"])
        self.assertEqual(payload["profiles"], payload["profileLabels"])
        self.assertEqual("platform-profile", payload["profileControlDomain"])
        self.assertTrue(payload["capability"]["canChange"])
        self.assertTrue(payload["fanCurveCapability"]["canChange"])
        self.assertTrue(payload["fanCurveEnabled"])
        self.assertEqual([["profile", "list"], ["profile", "get"], ["fan-curve", "--get-enabled"]],
                         [event["args"] for event in self.events() if event["event"] == "call"])

    def test_failure_retains_diagnostic_and_stops_followup_queries(self):
        payload, errors = self.status("fail")
        self.assertEqual("query-failed", payload["errorCode"])
        self.assertFalse(payload["capability"]["available"])
        self.assertIn("profile list failed, status 134", errors)
        self.assertIn("simulated I/O reason", errors)
        self.assertEqual(1, len(self.events()))

    def test_malformed_active_profile_is_unavailable(self):
        payload, _ = self.status("malformed")
        self.assertEqual("malformed-status", payload["errorCode"])
        self.assertEqual(2, len(self.events()))

    def test_empty_choices_and_unsupported_fan_keep_fallbacks(self):
        payload, _ = self.status("empty", FAKE_FAN="Error: org.freedesktop.DBus.Error.UnknownInterface")
        self.assertTrue(payload["capability"]["ready"])
        self.assertFalse(payload["capability"]["canChange"])
        self.assertEqual("profile-unavailable", payload["capability"]["reason"])
        self.assertFalse(payload["fanCurveEnabled"])
        self.assertEqual("fan-curves-unsupported", payload["fanCurveCapability"]["reason"])

    def test_failed_optional_fan_query_keeps_profile_and_diagnostic(self):
        payload, errors = self.status("fanfail", FAKE_FAN="daemon rejected fan query")
        self.assertTrue(payload["capability"]["canChange"])
        self.assertFalse(payload["fanCurveCapability"]["available"])
        self.assertIn("fan-curve --get-enabled failed, status 1", errors)
        self.assertIn("daemon rejected fan query", errors)

    def test_missing_command_keeps_typed_unavailable_fallback(self):
        # Use a closed PATH with no real asusctl fallback.
        fake_bin = self.root / "without-asusctl"
        fake_bin.mkdir()
        for name in ("bash", "dirname", "jq", "python3"):
            (fake_bin / name).symlink_to(Path("/usr/bin") / name)
        self.env["PATH"] = str(fake_bin)
        payload, _ = self.status()
        self.assertEqual("command-unavailable", payload["errorCode"])
        self.assertEqual("unavailable", payload["profile"])
        self.assertFalse(payload["capability"]["ready"])
        self.assertEqual([], self.events())

    def test_closing_status_stdout_during_vendor_write_keeps_files_writable(self):
        process = self.start("closed")
        self.wait_for(lambda: any(event["event"] == "writing" for event in self.events()))
        process.stdout.close()
        process.wait(timeout=5)
        process.stderr.read()
        process.stderr.close()
        self.assertTrue(any(event["event"] == "write-succeeded" for event in self.events()))
        self.assert_clean()

    def test_output_is_bounded_and_files_are_removed(self):
        payload, errors = self.status("overflow")
        self.assertFalse(payload["capability"]["available"])
        self.assertIn("output limit reached", errors)
        self.assertEqual(65536, next(event["size"] for event in self.events() if event["event"] == "limited"))

    def test_timeout_kills_term_ignoring_query_and_descendant(self):
        payload, errors = self.status("hang")
        self.assertFalse(payload["capability"]["available"])
        self.assertIn("profile list failed, status", errors)
        self.assertIn("sending signal", errors)
        self.assertTrue(any(event["event"] == "descendant" for event in self.events()))

    def test_supervisor_diagnostic_cannot_exceed_full_stderr_file(self):
        process = self.start("full-stderr", capture=True)
        self.wait_for(lambda: any(event["event"] == "stderr-full" for event in self.events()))
        event = next(event for event in self.events() if event["event"] == "stderr-full")
        # Keep an independent reader to inspect the file after all writers exit.
        with open(f"/proc/{event['pid']}/fd/2", "rb") as errors_file:
            _, errors = process.communicate(timeout=4)
            self.assertEqual(124, process.returncode, errors)
            self.assertIn(b"output limit reached", errors)
            self.assertEqual(65536, os.fstat(errors_file.fileno()).st_size)
        self.assert_clean()

    def test_capture_termination_and_forced_death_are_bounded(self):
        for number in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=number):
                process = self.start("hang", capture=True)
                self.wait_for(lambda: any(event["event"] == "descendant" and self.running(event["pid"])
                                         for event in self.events()))
                process.send_signal(number)
                process.communicate(timeout=4)
                self.assert_clean()

    def test_status_owner_death_does_not_leave_query_running(self):
        process = self.start("hang")
        self.wait_for(lambda: any(event["event"] == "descendant" for event in self.events()))
        process.kill()
        process.communicate(timeout=4)
        self.assert_clean()

    def test_successful_query_cannot_leave_a_descendant_running(self):
        self.status("descendant")

    def test_owner_death_after_direct_exit_still_cleans_exec_descendant(self):
        release = self.root / "exit-command"
        self.env["FAKE_EXIT"] = str(release)
        process = self.start("exit-with-descendant", capture=True)
        self.wait_for(lambda: any(event["event"] == "ready-to-exit" for event in self.events()))
        event = next(event for event in self.events() if event["event"] == "ready-to-exit")
        group = next(event["group"] for event in self.events() if event["event"] == "call")
        self.assertEqual(group, os.getpgid(event["child"]))
        output = Path(f"/proc/{event['child']}/fd/1").stat()
        self.assertTrue(stat.S_ISREG(output.st_mode))
        self.assertEqual(0, output.st_nlink)
        # Hold the capture owner across direct-child exit, then kill it before
        # it can run any finally cleanup. The supervisor must still own the group.
        process.send_signal(signal.SIGSTOP)
        release.touch()
        self.wait_for(lambda: not self.running(event["pid"]))
        process.kill()
        process.communicate(timeout=4)
        self.wait_for(lambda: not self.running(event["child"]), seconds=2.8)
        self.assert_clean()

    def test_three_slow_successful_queries_fit_provider_watchdog(self):
        started = time.monotonic()
        payload, _ = self.status("slow")
        elapsed = time.monotonic() - started
        self.assertTrue(payload["fanCurveCapability"]["available"])
        self.assertGreater(elapsed, 5)
        self.assertLess(elapsed, 8)
        self.assertEqual(3, len([event for event in self.events() if event["event"] == "call"]))

    def test_shared_deadline_shortens_later_query_and_skips_expired_queries(self):
        deadline = time.monotonic() + 0.35
        self.env["BLOX_ASUSCTL_DEADLINE"] = str(deadline)
        process = self.start("hang", capture=True)
        _, errors = process.communicate(timeout=3)
        self.assertEqual(124, process.returncode, errors)
        self.assertLess(time.monotonic() - deadline, 1)
        self.assert_clean()
        calls = len(self.events())
        # A later invocation with the same exhausted deadline must not start asusctl.
        process = self.start(capture=True)
        _, errors = process.communicate(timeout=3)
        self.assertEqual(124, process.returncode, errors)
        self.assertEqual(calls, len(self.events()))
        self.assert_clean()

    def test_whole_status_deadline_keeps_optional_fan_failure_typed(self):
        # Include work between queries. Each profile still fits its own budget,
        # but the fan query must use the remainder of the whole status deadline.
        jq = self.root / "bin/jq"
        jq.write_text('#!/bin/sh\nif [ "$1" = "-Rsc" ] || [ "$1" = "length" ]; then sleep 0.8; fi\nexec /usr/bin/jq "$@"\n')
        jq.chmod(0o700)
        started = time.monotonic()
        payload, errors = self.status("slow-then-hang")
        self.assertTrue(payload["capability"]["available"])
        self.assertFalse(payload["fanCurveCapability"]["available"])
        self.assertIn("fan-curve --get-enabled failed, status 124", errors)
        self.assertLess(time.monotonic() - started, 7)


if __name__ == "__main__":
    unittest.main()
