#!/usr/bin/env python3
"""Pure fake cancellation/cleanup checks. No process, socket, camera or image.

Run: python3 Scripts/test-mcp-zoom-cancel-hardware.py
"""
from contextlib import ExitStack
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("zoom_cancel_tested", Path(__file__).with_name("mcp-zoom-cancel-hardware.py"))
M = importlib.util.module_from_spec(SPEC)
with patch("subprocess.Popen", side_effect=AssertionError("No process during import")), \
     patch("socket.socket", side_effect=AssertionError("No socket during import")):
    SPEC.loader.exec_module(M)


class Clock:
    def __init__(self): self.now = 1000.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += seconds


class Fake:
    def __init__(self, clock, mode):
        self.clock, self.mode = clock, mode
        self.current, self.target = 100, 400
        self.started = self.cancelled = False
        self.next_id = 1
        self.buffer = bytearray()
        self.cli_calls, self.sent = [], []
        self.moving_reads = self.factory_count = self.close_count = self.stop_count = 0
        self.selector = SimpleNamespace(select=self.select)
        self.proc = SimpleNamespace(stdout=SimpleNamespace(read1=self.read_last_reply),
                                    stdin=SimpleNamespace(closed=False, close=self.close_stdin), wait=self.wait)
        self.final_chunk = b""

    def select(self, timeout):
        self.clock.sleep(timeout)
        if self.mode == "deadline_reply" and self.cancelled and self.clock.now >= self.collection_started + .5:
            self.mode = "deadline_reply_delivered"
            self.final_chunk = (json.dumps({"jsonrpc": "2.0", "id": self.zoom_id, "result": {"content": []}}) + "\n").encode()
            return [True]
        return []

    def read_last_reply(self, maximum):
        data, self.final_chunk = self.final_chunk, b""
        return data

    def factory(self, *_):
        self.factory_count += 1
        return self

    def request(self, method, params):
        self.next_id += 1
        self.clock.sleep(.01)
        if method == "initialize": value = {"protocolVersion": "2025-11-25"}
        elif method == "tools/list": value = self.listing()
        else: raise AssertionError("Unexpected synchronous MCP call: " + method)
        return value, self.clock.now - .01, self.clock.now

    def listing(self):
        return {"tools": [{"name": name} for name in sorted(M.ZOOM.TOOLS)]}

    def queue(self, message):
        self.buffer.extend((json.dumps(message) + "\n").encode())

    def send(self, message):
        self.sent.append(message)
        method = message["method"]
        if method == "notifications/initialized": return
        if method == "tools/call":
            assert not self.started
            assert message["params"] == {"name": "camera_set_zoom", "arguments": {"rawValue": 400, "expectedSessionID": "session"}}
            self.started = True; self.zoom_id = message["id"]
        elif method == "notifications/cancelled":
            assert message["params"]["requestId"] == self.zoom_id
            assert not self.cancelled
            self.cancelled = True
            if self.mode == "completion_reply":
                self.queue({"jsonrpc": "2.0", "id": self.zoom_id, "result": {"content": [], "structuredContent": {"completed": True}}})
        elif method == "tools/list":
            self.collection_started = self.clock.now
            self.queue({"jsonrpc": "2.0", "id": message["id"], "result": self.listing()})
        else: raise AssertionError("Unexpected send: " + method)

    def close(self):
        self.close_count += 1
        if self.mode == "close_failure": raise OSError("Synthetic client close failure")

    def close_stdin(self):
        assert not self.proc.stdin.closed
        self.proc.stdin.closed = True
        self.cancelled = True

    def wait(self, timeout):
        assert self.proc.stdin.closed
        self.clock.sleep(.02)
        return 1 if self.mode == "eof_exit_failure" else 0

    def cli(self, argv, **kwargs):
        args = argv[1:]; self.cli_calls.append(args)
        self.clock.sleep(.03)
        if args == ["status"]:
            session = "replacement" if self.started and self.mode == "changed_binding" else "session"
            moving = self.started and (not self.cancelled or self.mode == "eof_no_hold")
            value = {"buildVersion": "18" if self.mode == "wrong_build" else "19",
                     "selected": {"id": "device"}, "capture": {"sessionID": session, "age": .02,
                         "frame": {"sessionID": session, "deviceID": "device"}},
                     "gimbal": {"registryID": "registry", "bootSessionID": "boot"},
                     "phase": "moving" if moving else "ready", "motionActive": moving,
                     "access": "observe" if self.cancelled and self.mode != "eof_no_hold" else "control"}
        elif args == ["zoom-status", "--session", "session"]:
            if self.started and not self.cancelled:
                self.moving_reads += 1
                self.current = {"already_completed": 400, "overshot": 420}.get(self.mode, 100 + 30 * self.moving_reads)
            elif self.cancelled and self.mode == "keeps_ramping" and self.stop_count == 0:
                self.current += 35
            value = dict(current=self.current, minimum=100, maximum=500, step=1, writable=True)
        elif args == ["stop"]:
            self.stop_count += 1
            assert self.stop_count == 1
            value = dict(accepted=True, completed=True, verified=True)
        else: raise AssertionError("Unexpected CLI operation: " + repr(args))
        return SimpleNamespace(returncode=0, stdout=json.dumps(value), stderr="")


class CancellationHarnessTests(unittest.TestCase):
    def check_case(self, mode="pass", fault=None, ending="notification"):
        clock = Clock(); fake = Fake(clock, mode)
        with tempfile.TemporaryDirectory(prefix="p3-mcp-cancel-fake-") as directory, ExitStack() as stack:
            root = Path(directory)
            binary = root / "nonexecutable-fixture"
            binary.write_bytes(b"Never executed")
            args = SimpleNamespace(output=str(root / "reports"), binary=str(binary), zoom=True,
                device="device", session="session", registry="registry", expected_build="19",
                expected_raw=100, target_raw=400, ending=ending)
            blocked = [stack.enter_context(patch(name, side_effect=AssertionError("Offline test forbids " + name)))
                       for name in ("subprocess.Popen", "subprocess.run", "socket.socket", "os.system", "time.sleep")]
            stack.enter_context(patch.dict(M.os.environ, {"POCKET3_BRIDGE_DIRECTORY": ""}))
            original = Path.write_text
            fault_triggered = False

            def persist(path, text, *a, **kw):
                nonlocal fault_triggered
                if path.name == "result.json.tmp":
                    value = json.loads(text)
                    fault_triggered |= (fault == "after_set" and fake.started) or (fault == "final" and value["status"] == "complete")
                    if fault_triggered: raise OSError(28, "Synthetic persistent disk full")
                return original(path, text, *a, **kw)

            stack.enter_context(patch.object(Path, "write_text", persist))
            report, output = M.run(args, client_factory=fake.factory, clock=clock, cli_runner=fake.cli)
            for operation in blocked: operation.assert_not_called()
            self.assertEqual(fake.close_count, fake.factory_count)
            self.assertLessEqual(fake.factory_count, 1)
            self.assertFalse(report["imagesSaved"])
            self.assertFalse(report["restoreSent"])
            self.assertIn("finishedAt", report)
            self.assertLess(clock.now - 1000, 12)
            self.assertFalse(any(item.suffix.lower() in {".jpg", ".jpeg", ".png"} for item in root.rglob("*")))
            self.assertTrue(all(item.name in {"result.json", "result.json.tmp", "stderr.log"} for item in output.parent.iterdir()))
            if fault:
                self.assertTrue(fault_triggered)
                self.assertTrue(report["evidenceWriteFailed"])
                self.assertGreaterEqual(len(report["persistenceErrors"]), 1)
                self.assertLessEqual(len(report["persistenceErrors"]), 8)
            return report, fake

    def test_cancel_holds_intermediate_without_client_stop_and_helper_survives(self):
        report, fake = self.check_case()
        self.assertTrue(report["passed"])
        self.assertEqual(report["distinctProgressReadbacks"], [130, 160])
        self.assertGreaterEqual(report["stableDurationSeconds"], 1)
        self.assertEqual(report["finalRaw"], 160)
        self.assertTrue(report["helperRemainedUsable"] and report["cancelledReplySuppressed"])
        self.assertEqual(fake.stop_count, 0)
        self.assertFalse(report["clientStopSent"])

    def test_unexpected_build_never_constructs_helper_or_sends_set(self):
        report, fake = self.check_case("wrong_build")
        self.assertFalse(report["passed"])
        self.assertFalse(fake.started)
        self.assertEqual(fake.factory_count, 0)
        self.assertEqual(fake.stop_count, 0)

    def test_stdin_eof_requires_normal_exit_and_independent_app_hold_without_client_stop(self):
        report, fake = self.check_case(ending="stdin-eof")
        self.assertTrue(report["passed"])
        self.assertTrue(report["stdinEOFSubmitted"] and fake.proc.stdin.closed)
        self.assertFalse(report["cancelNotificationSent"])
        self.assertEqual(report["helperExitCode"], 0)
        self.assertIsNone(report["helperRemainedUsable"])
        self.assertNotIn("cancelledReplySuppressed", report)
        self.assertEqual(report["distinctProgressReadbacks"], [130, 160])
        self.assertEqual(report["finalRaw"], 160)
        self.assertGreaterEqual(report["stableDurationSeconds"], 1)
        self.assertEqual(fake.stop_count, 0)
        self.assertFalse(report["clientStopSent"])
        self.assertFalse(any(item["method"] in {"notifications/cancelled", "tools/list"} for item in fake.sent))

    def test_stdin_eof_without_hold_or_with_continued_ramp_fails_with_one_cleanup_stop(self):
        for mode in ("eof_no_hold", "keeps_ramping"):
            with self.subTest(mode=mode):
                report, fake = self.check_case(mode, ending="stdin-eof")
                self.assertFalse(report["passed"])
                self.assertEqual(report["helperExitCode"], 0)
                self.assertEqual(fake.stop_count, 1)
                self.assertTrue(report["clientStopSent"])
                self.assertFalse(report["cancelNotificationSent"])
                self.assertFalse(any(item["method"] == "notifications/cancelled" for item in fake.sent))

    def test_stdin_eof_abnormal_helper_exit_is_not_a_pass(self):
        report, fake = self.check_case("eof_exit_failure", ending="stdin-eof")
        self.assertFalse(report["passed"])
        self.assertEqual(report["helperExitCode"], 1)
        self.assertEqual(fake.stop_count, 1)
        self.assertIn("exit normally", report["error"])

    def test_target_already_completed_or_overshot_cannot_pass(self):
        for mode in ("already_completed", "overshot"):
            with self.subTest(mode=mode):
                report, fake = self.check_case(mode)
                self.assertFalse(report["passed"])
                self.assertIn("before cancellation", report["error"])
                self.assertEqual(fake.stop_count, 1)

    def test_ramping_after_cancel_fails_with_one_fallback_stop(self):
        report, fake = self.check_case("keeps_ramping")
        self.assertFalse(report["passed"])
        self.assertEqual(fake.stop_count, 1)
        self.assertTrue(report["clientStopSent"])

    def test_replaced_binding_never_receives_cleanup_stop(self):
        report, fake = self.check_case("changed_binding")
        self.assertFalse(report["passed"])
        self.assertTrue(fake.started and fake.cancelled)
        self.assertEqual(fake.stop_count, 0)
        self.assertFalse(report["clientStopSent"])
        self.assertIn("changed", report["cleanupError"])

    def test_cancelled_request_completion_reply_fails_even_when_zoom_stable(self):
        for mode in ("completion_reply", "deadline_reply"):
            with self.subTest(mode=mode):
                report, fake = self.check_case(mode)
                self.assertFalse(report["passed"])
                self.assertIn("completion reply", report["error"])
                self.assertEqual(fake.stop_count, 1)

    def test_persistent_disk_fault_after_set_cannot_prevent_cleanup(self):
        report, fake = self.check_case(fault="after_set")
        self.assertFalse(report["passed"])
        self.assertTrue(fake.cancelled)
        self.assertEqual(fake.stop_count, 1)
        self.assertTrue(report["cleanupStop"]["verified"])

    def test_final_persistence_or_client_close_failure_cannot_report_pass(self):
        for mode, fault in (("pass", "final"), ("close_failure", None)):
            with self.subTest(mode=mode, fault=fault):
                report, fake = self.check_case(mode, fault)
                self.assertFalse(report["passed"])
                self.assertEqual(report["status"], "failed")
                self.assertEqual(fake.stop_count, 0)  # cancellation had already held and been verified
                if mode == "close_failure": self.assertIn("clientCloseFailure", report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
