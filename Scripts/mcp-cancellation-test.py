#!/usr/bin/env python3
"""Probe packaged MCP cancellation against private fake IPC, never a camera.

Tests consecutive NDJSON request/cancel in one write, cancellation after IPC
starts, EOF during an active request, and helper reuse. A separate diagnostic
covers the SDK's legacy JSON-RPC array-batch behavior; array batches are not a
required part of the negotiated 2025-11-25 protocol. No dependency is patched.
"""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import selectors
import socket
import subprocess
import tempfile
import threading
import time
import uuid

PROJECT = Path(__file__).resolve().parents[1]
TOOLS = {"camera_status", "capture_frame", "move_gimbal", "stop_gimbal", "camera_zoom_status", "camera_set_zoom"}
OBSERVATION_SECONDS = 1.5


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class FakeIPC:
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="p3-mcp-cancel-", dir="/tmp")
        path = Path(self.directory.name)
        self.token = uuid.uuid4().hex
        self.nonce = uuid.uuid4().hex
        (path / "connection-token").write_text(self.token)
        (path / "connection-token").chmod(0o600)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path / "bridge.sock"))
        (path / "bridge.sock").chmod(0o600)
        self.listener.listen(8); self.listener.settimeout(.05)
        self.lock = threading.Lock()
        self.done = threading.Event(); self.release = threading.Event()
        self.started = threading.Event(); self.cancelled = threading.Event()
        self.requests = []; self.failures = []; self.move = None
        self.threads = []
        self.accept_thread = threading.Thread(target=self.accept, daemon=True)
        self.accept_thread.start()

    def snapshot(self):
        with self.lock:
            return copy.deepcopy({"requests": self.requests, "move": self.move, "failures": self.failures})

    def accept(self):
        while not self.done.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            thread = threading.Thread(target=self.handle, args=(connection,), daemon=True)
            self.threads.append(thread); thread.start()

    def handle(self, connection):
        with connection:
            try:
                connection.settimeout(2)
                with connection.makefile("rb") as stream:
                    line = stream.readline(16385)
                require(len(line) <= 16384 and line.endswith(b"\n"), "Invalid private IPC framing")
                request = json.loads(line)
                require(request.get("token") == self.token and request.get("version") == 1, "Wrong private IPC credential/version")
                record = {key: request.get(key) for key in ("id", "operation", "arguments", "source")}
                record["receivedUptime"] = time.monotonic()
                with self.lock:
                    self.requests.append(record)
                operation = request["operation"]
                if operation == "move":
                    require(request.get("source") == "mcp" and request["arguments"] == {"direction": "left"}, "Move lost its source/arguments")
                    with self.lock:
                        require(self.move is None, "Unexpected second fake move")
                        self.move = {"id": request["id"], "startedUptime": time.monotonic(), "cancelSignalUptime": None,
                                     "cancelChannel": None, "peerEOFUptime": None, "fakeReplySent": False}
                    self.started.set()
                    deadline = time.monotonic() + 8
                    while not self.done.is_set() and time.monotonic() < deadline:
                        if select.select([connection], [], [], .02)[0]:
                            data = connection.recv(1, socket.MSG_PEEK)
                            if not data:
                                now = time.monotonic()
                                with self.lock:
                                    self.move["peerEOFUptime"] = now
                                    if self.move["cancelSignalUptime"] is None:
                                        self.move.update(cancelSignalUptime=now, cancelChannel="peer_eof")
                                self.cancelled.set(); return
                        if self.cancelled.is_set():
                            return
                        if self.release.is_set():
                            self.reply(connection, request, {"simulation": True, "fixtureNonce": self.nonce,
                                                           "fakeOperationCompleted": True, "hardwareWrites": 0})
                            with self.lock:
                                self.move["fakeReplySent"] = True
                            return
                    with self.lock:
                        self.failures.append("Fake move reached bounded timeout without test release")
                elif operation == "cancel-request":
                    cancelled_id = request.get("arguments", {}).get("id")
                    with self.lock:
                        # An unrelated cancellation must not satisfy this test.
                        if self.move is not None and cancelled_id == self.move["id"]:
                            if self.move["cancelSignalUptime"] is None:
                                self.move.update(cancelSignalUptime=time.monotonic(), cancelChannel="cancel_request")
                            self.cancelled.set()
                    self.reply(connection, request, {"simulation": True, "cancelled": cancelled_id})
                elif operation == "status":
                    require(request.get("source") == "mcp", "Status did not use MCP forwarding")
                    self.reply(connection, request, {"simulation": True, "fixtureNonce": self.nonce})
                else:
                    raise RuntimeError("Unexpected fake IPC operation: " + operation)
            except (BrokenPipeError, ConnectionResetError):
                # The client can leave before the redundant cancel-request ACK.
                pass
            except BaseException as error:
                with self.lock:
                    self.failures.append(f"{type(error).__name__}: {error}")

    @staticmethod
    def reply(connection, request, value):
        connection.sendall((json.dumps({"id": request["id"], "version": 1, "result": value}) + "\n").encode())

    def close(self):
        self.done.set(); self.release.set(); self.listener.close()
        self.accept_thread.join(timeout=1)
        for thread in self.threads:
            thread.join(timeout=1)
        self.directory.cleanup()


class Helper:
    def __init__(self, binary, fixture, stderr):
        self.process = subprocess.Popen([str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
            env={**os.environ, "POCKET3_BRIDGE_DIRECTORY": fixture.directory.name}, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray(); self.messages = []; self.eof = False

    def send_bytes(self, data):
        self.process.stdin.write(data); self.process.stdin.flush()

    def send(self, value):
        self.send_bytes((json.dumps(value) + "\n").encode())

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and not self.eof:
            if self.selector.select(min(.05, max(0, deadline-time.monotonic()))):
                data = self.process.stdout.read1(65536)
                if not data:
                    self.eof = True; break
                self.buffer.extend(data)
                require(len(self.buffer) < 262144, "Unexpected oversized fake-only MCP response")
                while b"\n" in self.buffer:
                    line, _, tail = self.buffer.partition(b"\n"); self.buffer[:] = tail
                    value = json.loads(line)
                    self.messages.extend(value if isinstance(value, list) else [value])

    def response(self, identifier, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = next((value for value in self.messages if value.get("id") == identifier), None)
            if found is not None:
                return found
            self.drain(.05)
            if self.eof:
                break
        raise TimeoutError("MCP response missing for " + str(identifier))

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=2)
        self.selector.close(); self.process.stdout.close()


def rpc(identifier, method, params):
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}


def exercise(binary, out, name, transport_mode):
    diagnostic = transport_mode == "array_batch"
    result = {"case": name, "mode": transport_mode, "diagnosticOnly": diagnostic, "passed": False,
              "observationWindowSeconds": OBSERVATION_SECONDS, "simulation": True, "hardwareWrites": 0}
    fixture = FakeIPC(); helper = None
    with (out / (name + ".stderr.log")).open("w") as stderr:
        try:
            helper = Helper(binary, fixture, stderr)
            helper.send(rpc("initialize", "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "PrivateIPCCancellationProbe", "version": "2"}}))
            initialized = helper.response("initialize")
            require(initialized.get("result", {}).get("protocolVersion") == "2025-11-25", "Unexpected negotiated protocol")
            helper.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            helper.send(rpc("private-preflight", "tools/call", {"name": "camera_status", "arguments": {}}))
            preflight = helper.response("private-preflight").get("result", {}).get("structuredContent", {})
            require(preflight.get("simulation") is True and preflight.get("fixtureNonce") == fixture.nonce,
                    "Helper did not reach the private fixture; no move is permitted")
            move = rpc("move", "tools/call", {"name": "move_gimbal", "arguments": {"direction": "left"}})
            cancel = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "move", "reason": "Private IPC test; no camera"}}
            sent = time.monotonic()
            if transport_mode == "ndjson_burst":
                helper.send_bytes((json.dumps(move) + "\n" + json.dumps(cancel) + "\n").encode())
            elif transport_mode == "array_batch":
                helper.send([move, cancel])
            else:
                helper.send(move)
                require(fixture.started.wait(2), "Fake move did not become active")
                sent = time.monotonic()
                if transport_mode == "stdin_eof":
                    helper.process.stdin.close()
                else:
                    helper.send(cancel)
            helper.drain(OBSERVATION_SECONDS)
            observed = fixture.snapshot()
            result["observationBeforeFixtureRelease"] = observed
            result["signalSentUptime"] = sent
            forwarded = observed["move"]
            cancel_time = forwarded and forwarded["cancelSignalUptime"]
            result["forwarded"] = forwarded is not None
            result["forwardedButUncancelledAtDeadline"] = forwarded is not None and cancel_time is None
            result["cancellationSeconds"] = None if cancel_time is None else cancel_time - sent
            result["responsesBeforeFixtureRelease"] = [value for value in helper.messages if value.get("id") == "move"]
            if transport_mode == "stdin_eof":
                helper.process.wait(timeout=2)
                # OS closes the helper's IPC socket on exit; permit a bounded
                # monitor turn before recording its peer EOF, not another request.
                fixture.cancelled.wait(.5)
                observed = fixture.snapshot(); result["observationBeforeFixtureRelease"] = observed
                forwarded = observed["move"]
                cancel_time = forwarded and forwarded["cancelSignalUptime"]
                result["forwarded"] = forwarded is not None
                result["forwardedButUncancelledAtDeadline"] = forwarded is not None and cancel_time is None
                result["cancellationSeconds"] = None if cancel_time is None else cancel_time - sent
                result["helperExitCode"] = helper.process.returncode
                result["passed"] = helper.process.returncode == 0 and forwarded is not None and forwarded["peerEOFUptime"] is not None
                result["outcome"] = "helper_exit_and_ipc_eof" if result["passed"] else "shutdown_not_confirmed"
                result["helperRemainedUsable"] = None
            else:
                # Freeze cancellation evidence before allowing an uncancelled
                # fake request to finish. Teardown EOF never upgrades a failed case.
                result["passed"] = not result["forwardedButUncancelledAtDeadline"] and not result["responsesBeforeFixtureRelease"]
                result["outcome"] = "cancelled_after_forward" if cancel_time is not None else "not_forwarded_within_observation_window" if forwarded is None else "cancellation_not_observed_before_fixture_release"
                fixture.release.set()
                helper.send(rpc("after-list", "tools/list", {}))
                listing = helper.response("after-list", timeout=3)
                require({tool["name"] for tool in listing.get("result", {}).get("tools", [])} == TOOLS, "Helper unusable after cancellation")
                helper.send(rpc("after-status", "tools/call", {"name": "camera_status", "arguments": {}}))
                after = helper.response("after-status").get("result", {}).get("structuredContent", {})
                result["helperRemainedUsable"] = after.get("fixtureNonce") == fixture.nonce and after.get("simulation") is True
                require(result["helperRemainedUsable"], "MCP lost private IPC after cancellation")
                helper.drain(.15)
                result["responsesAfterFixtureRelease"] = [value for value in helper.messages if value.get("id") == "move"]
                if result["passed"]:
                    require(not result["responsesAfterFixtureRelease"], "Cancelled request returned a late response")
            require(not fixture.snapshot()["failures"], "Fixture failure: " + repr(fixture.snapshot()["failures"]))
        except BaseException as error:
            result.update(passed=False, failure=f"{type(error).__name__}: {error}")
        finally:
            fixture.release.set()
            if helper:
                helper.close()
                result["helperExitCode"] = helper.process.returncode
            fixture.close()
            result["finalFixtureState"] = fixture.snapshot()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=PROJECT / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    parser.add_argument("--output", type=Path, default=PROJECT / "artifacts/mcp-cancellation")
    parser.add_argument("--early-repetitions", type=int, choices=range(1, 7), default=4)
    args = parser.parse_args()
    binary = args.binary.resolve()
    require(binary.is_file(), "Packaged MCP helper missing")
    out = args.output.resolve() / str(uuid.uuid4()); out.mkdir(parents=True, exist_ok=False)
    info_path = binary.parent.parent / "Info.plist"
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    report = {"runID": out.name, "startedAt": datetime.now(timezone.utc).isoformat(), "status": "running", "passed": False,
              "simulation": True, "hardwareAccess": False, "runningAppAccess": False,
              "binary": str(binary), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "scriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "buildVersion": info.get("CFBundleVersion"), "appVersion": info.get("CFBundleShortVersionString"),
              "protocol": "2025-11-25", "cases": [],
              "batchingRemovedReference": "https://modelcontextprotocol.io/specification/2025-06-18/changelog",
              "limitations": ["Fake IPC cancellation is not proof of physical motor stopping",
                  "A finite early-cancel sample cannot establish absence of all scheduling races",
                  "Legacy JSON-RPC array batches are a separate SDK diagnostic, not required 2025-11-25 protocol behavior"]}
    path = out / "result.json"
    def save(): path.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    save()
    for name, mode in [*[(f"early-ndjson-{index+1}", "ndjson_burst") for index in range(args.early_repetitions)],
                       ("after-ipc-start", "active_cancel"), ("stdin-eof", "stdin_eof"), ("legacy-array-batch", "array_batch")]:
        case = exercise(binary, out, name, mode)
        report["cases"].append(case); save()
        print(json.dumps({key: case.get(key) for key in ("case", "passed", "diagnosticOnly", "forwarded", "forwardedButUncancelledAtDeadline", "helperRemainedUsable", "failure")}), flush=True)
    report["passed"] = all(case["passed"] for case in report["cases"] if not case["diagnosticOnly"])
    report["status"] = "completed" if report["passed"] else "failed"
    report["finishedAt"] = datetime.now(timezone.utc).isoformat(); save()
    print(json.dumps({"passed": report["passed"], "report": str(path), "requiredCases": len(report["cases"])-1,
                      "legacyArrayBatchPassed": report["cases"][-1]["passed"]}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
