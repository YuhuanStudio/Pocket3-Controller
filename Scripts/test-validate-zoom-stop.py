#!/usr/bin/env python3
"""Pure fake-CLI checks: never spawn a process, contact IPC, or use hardware."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("zoom_stop", Path(__file__).with_name("validate-zoom-stop.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Clock:
    value = 100.0
    def monotonic(self):
        return self.value
    def sleep(self, seconds):
        self.value += seconds


class Job:
    def __init__(self, cli):
        self.cli = cli
        self.cancelled = False
    def running(self):
        return not self.cancelled and not self.cli.stopped and self.cli.scenario != "already_completed"
    def cancel(self):
        self.cli.events.append("cancel-child")
        self.cancelled = True
        if self.cli.scenario == "cancel_error":
            raise OSError("fake cancellation failure")
    def collect(self, timeout=4):
        if self.cli.scenario == "already_completed":
            return {"returncode": 0, "result": {"verified": True}}
        return {"returncode": 1, "error": {"code": "operation_failed", "message": "Fake cancellation"}}


class FakeCLI:
    def __init__(self, clock, scenario="success", origin=100):
        self.clock, self.scenario = clock, scenario
        self.started = self.stopped = False
        self.raw = origin
        self.events = []
        self.progress_reads = self.post_reads = 0
        self.target = None
    def call(self, *arguments):
        name = arguments[0]
        self.events.append(name)
        self.clock.sleep(.01)
        if name == "status":
            session = "replacement" if self.started and self.scenario == "replaced" else "capture"
            return {"selected": {"id": "camera"}, "capture": {"sessionID": session, "age": .1, "frame": {"id": "frame", "sessionID": session, "deviceID": "other-camera" if self.scenario == "stale_frame" else "camera"}},
                    "gimbal": {"registryID": "registry", "bootSessionID": "boot", "position": {"pan": 0, "tilt": 0}},
                    "phase": "moving" if self.started and not self.stopped else "ready", "motionActive": self.started and not self.stopped,
                    "access": "manual", "controlTransport": "usb_position", "appVersion": "fixture", "buildVersion": "fixture"}
        if name == "zoom-status":
            assert arguments[1:] == ("--session", "capture")
            if self.started and not self.stopped:
                self.progress_reads += 1
                sign = 1 if self.target > self.raw else -1
                if self.scenario == "wrong_direction":
                    self.raw -= 5
                elif self.scenario == "stationary":
                    self.raw = 106
                else:
                    self.raw += 6 * sign
            elif self.stopped:
                self.post_reads += 1
                self.raw = self.held + (self.post_reads if self.scenario == "late_ramp" else -(self.post_reads % 2))
            return {"current": self.raw, "minimum": 100, "maximum": 400, "step": 2 if self.scenario == "wrong_step" else 1, "writable": True}
        if name == "stop":
            self.stopped = True
            self.held = self.raw
            hold = {"submitted": True, "verified": True, "failure": None, "target": self.held, "observed": self.held,
                    "sampleCount": 11, "stableDurationSeconds": .8, "toleranceRaw": 1,
                    "verification": "fresh_uvc_zoom_hold_with_advertised_tolerance"}
            if self.scenario == "short_window":
                hold["stableDurationSeconds"] = .16
            if self.scenario == "wrong_tolerance":
                hold["toleranceRaw"] = 0
            if self.scenario == "arrived_at_target":
                hold["target"] = hold["observed"] = self.target
            return {"accepted": True, "completed": True, "verified": True,
                    "zoomStop": None if self.scenario == "missing_hold" else hold}
        raise AssertionError("Unexpected fake command: " + name)
    def start_zoom(self, target, session, folder):
        assert session == "capture"
        self.events.append("start-zoom")
        self.started = True; self.target = target
        return Job(self)


class ZoomStopTests(unittest.TestCase):
    def run_case(self, scenario="success", origin=100, target=200, session="capture", full_advertised_range=False):
        clock = Clock(); cli = FakeCLI(clock, scenario, origin)
        with tempfile.TemporaryDirectory(prefix="pocket3-zoom-stop-test-") as directory:
            args = SimpleNamespace(output=Path(directory), device="camera", session=session,
                                   registry="registry", target_raw=target, full_advertised_range=full_advertised_range)
            with patch.object(module.subprocess, "run", side_effect=AssertionError("No processes in pure tests")), \
                 patch.object(module.subprocess, "Popen", side_effect=AssertionError("No processes in pure tests")):
                report, path = module.run(args, cli, clock)
            self.assertEqual(json.loads(path.read_text())["passed"], report["passed"])
            self.assertFalse(list(Path(directory).rglob("*.jpg")))
            self.assertLessEqual(cli.events.count("start-zoom"), 1)
            self.assertLessEqual(cli.events.count("stop"), 1)
        return report, cli

    def test_both_directions_require_progress_summary_and_a_full_second_window(self):
        for origin, target in [(100,200),(250,150)]:
            with self.subTest(origin=origin):
                report, cli = self.run_case(origin=origin, target=target)
                self.assertTrue(report["passed"], report)
                self.assertGreaterEqual(report["distinctProgressReadbacks"], 2)
                self.assertGreaterEqual(report["postStopStableDurationSeconds"], .8)
                self.assertGreaterEqual(len(report["postStopSamples"]), 3)
                self.assertNotEqual(report["finalRaw"], target)
                self.assertEqual(cli.events.count("start-zoom"), 1)
                self.assertEqual(cli.events.count("stop"), 1)

    def test_no_stationary_or_completed_request_can_pass_as_moving_stop(self):
        for scenario in ["stationary", "already_completed", "arrived_at_target", "missing_hold"]:
            with self.subTest(scenario=scenario):
                report, _ = self.run_case(scenario)
                self.assertFalse(report["passed"])
                self.assertIn("failure", report)

    def test_short_summary_wrong_tolerance_or_late_ramp_are_not_verified(self):
        for scenario in ["short_window", "wrong_tolerance", "late_ramp"]:
            with self.subTest(scenario=scenario):
                report, cli = self.run_case(scenario)
                self.assertFalse(report["passed"])
                self.assertIn("stop", report)
                self.assertEqual(cli.events.count("stop"), 1)
                self.assertEqual(cli.events.count("start-zoom"), 1)

    def test_replacement_connection_receives_no_cleanup_stop(self):
        report, cli = self.run_case("replaced")
        self.assertFalse(report["passed"])
        self.assertIn("Connection changed", report["cleanupFailure"])
        self.assertEqual(cli.events.count("stop"), 0)
        self.assertIn("cancel-child", cli.events)

    def test_invalid_binding_limits_or_step_prevent_any_mutation(self):
        for kwargs in [{"session":"other"}, {"target":400}, {"target":105}, {"scenario":"wrong_step"}, {"scenario":"stale_frame"}]:
            with self.subTest(kwargs=kwargs):
                report, cli = self.run_case(**kwargs)
                self.assertFalse(report["passed"])
                self.assertNotIn("start-zoom", cli.events)
                self.assertNotIn("stop", cli.events)

    def test_full_advertised_range_requires_explicit_opt_in_and_keeps_evidence_gates(self):
        default, default_cli = self.run_case(target=400)
        self.assertFalse(default["passed"])
        self.assertFalse(default["fullAdvertisedRangeOptIn"])
        self.assertNotIn("start-zoom", default_cli.events)
        full, full_cli = self.run_case(target=400, full_advertised_range=True)
        self.assertTrue(full["passed"], full)
        self.assertTrue(full["fullAdvertisedRangeOptIn"])
        self.assertGreaterEqual(full["distinctProgressReadbacks"], 2)
        self.assertGreaterEqual(full["postStopStableDurationSeconds"], .8)
        self.assertEqual(full_cli.events.count("start-zoom"), 1)
        self.assertEqual(full_cli.events.count("stop"), 1)
        for target in [99,105,401]:
            with self.subTest(target=target):
                rejected, cli = self.run_case(target=target, full_advertised_range=True)
                self.assertFalse(rejected["passed"])
                self.assertNotIn("start-zoom", cli.events)
        failed, _ = self.run_case("short_window", target=400, full_advertised_range=True)
        self.assertFalse(failed["passed"])

    def test_failure_before_progress_cancels_child_before_cleanup_and_never_retries(self):
        report, cli = self.run_case("wrong_direction", origin=150, target=250)
        self.assertFalse(report["passed"])
        self.assertLess(cli.events.index("cancel-child"), cli.events.index("stop"))
        self.assertEqual(cli.events.count("start-zoom"), 1)

    def test_cancel_error_does_not_suppress_best_effort_same_binding_stop(self):
        # Arrange a progress timeout then a failed child cancellation.
        original = FakeCLI.call
        def limited(cli, *arguments):
            if arguments[0] == "zoom-status" and cli.started and not cli.stopped:
                cli.clock.sleep(3)
            return original(cli, *arguments)
        with patch.object(FakeCLI, "call", limited):
            report, cli = self.run_case("cancel_error")
        self.assertFalse(report["passed"])
        self.assertIn("CLI cancellation failed", report["cleanupFailure"])
        self.assertEqual(cli.events.count("stop"), 1)

    def test_artifact_write_failure_cannot_prevent_the_cleanup_stop(self):
        clock = Clock(); cli = FakeCLI(clock)
        original = Path.write_text
        def unavailable_during_motion(path, *arguments, **keywords):
            if cli.started and not cli.stopped:
                raise OSError("fake artifact storage failure")
            return original(path, *arguments, **keywords)
        with tempfile.TemporaryDirectory(prefix="pocket3-zoom-stop-io-test-") as directory:
            args = SimpleNamespace(output=Path(directory), device="camera", session="capture", registry="registry", target_raw=200)
            with patch.object(Path, "write_text", unavailable_during_motion):
                report, path = module.run(args, cli, clock)
            self.assertFalse(report["passed"])
            self.assertIn("artifact storage", report["failure"])
            self.assertEqual(cli.events.count("stop"), 1)
            self.assertEqual(cli.events.count("start-zoom"), 1)
            self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
