#!/usr/bin/env python3
"""Observe a real MCP zoom cancellation during motion, without a client Stop.

Requires an already-connected App with control access and explicit binding.
The successful run leaves the verified intermediate zoom in place. Restore it
separately after inspecting the evidence. A failed run may use one same-binding
Stop for cleanup; that can never turn the cancellation test into a pass.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

SPEC = importlib.util.spec_from_file_location("zoom_acceptance", Path(__file__).with_name("mcp-zoom-hardware.py"))
ZOOM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ZOOM)
require = ZOOM.require


def run(args, *, client_factory=ZOOM.MCPClient, clock=time, cli_runner=subprocess.run):
    out = Path(args.output).resolve() / str(uuid.uuid4())
    out.mkdir(parents=True, exist_ok=False)
    report = {"id": out.name, "startedAt": datetime.now(timezone.utc).isoformat(),
              "passed": False, "status": "running", "simulation": False,
              "imagesSaved": False, "targetRaw": args.target_raw,
              "expectedInitialRaw": args.expected_raw, "samples": [],
              "clientStopSent": False, "restoreSent": False,
              "limitations": ["One cancellation case, not all disconnect/reconnect races",
                              "Raw zoom is not a calibrated magnification",
                              "Fallback global Stop has only client-side binding checks"]}
    output = out / "result.json"
    client = None
    request_id = None
    write_attempted = False
    cancelled = False
    binding = {"sessionID": args.session, "deviceID": args.device, "registryID": args.registry}
    report["binding"] = binding

    def persist(required=True):
        try:
            temp = out / "result.json.tmp"
            temp.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
            temp.replace(output)
        except (OSError, TypeError, ValueError) as error:
            report.update(passed=False, status="failed", evidenceWriteFailed=True)
            errors = report.setdefault("persistenceErrors", [])
            if len(errors) < 8:
                errors.append(f"{type(error).__name__}: {error}")
            if required:
                raise

    def cli(*arguments):
        result = cli_runner([args.binary, *arguments], capture_output=True, text=True, timeout=12)
        value = json.loads(result.stdout)
        require(result.returncode == 0, "CLI read/cleanup failed: " + str(value.get("code", "unknown")))
        return value

    def status(ready=False, access=None, fresh=False):
        value = cli("status")
        actual = ZOOM.binding(value)
        require(all(actual.get(key) == expected for key, expected in binding.items()),
                "Device/session/attachment changed; no cleanup write is permitted")
        require(str(value.get("buildVersion")) == args.expected_build, "Unexpected running App build")
        if "bootSessionID" not in binding:
            require(isinstance(actual.get("bootSessionID"), str) and bool(actual["bootSessionID"]), "Missing boot identity")
            binding["bootSessionID"] = actual["bootSessionID"]
        require(value.get("nativeControl") is None, "Another control transport owns the camera")
        if ready:
            require(value.get("phase") == "ready" and value.get("motionActive") is False, "Camera is not idle")
        if access:
            require(value.get("access") == access, "Access changed")
        if fresh:
            capture = value.get("capture") or {}
            frame = capture.get("frame") or {}
            require(ZOOM.finite(capture.get("age")) and 0 <= capture["age"] < 1
                    and frame.get("sessionID") == args.session and frame.get("deviceID") == args.device,
                    "No fresh same-session camera frame")
        return value

    def read_zoom():
        return ZOOM.capabilities(cli("zoom-status", "--session", args.session))

    def cancel_request(reason):
        nonlocal cancelled
        if not cancelled and request_id is not None:
            client.send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                         "params": {"requestId": request_id, "reason": reason}})
            cancelled = True
            report["cancelNotificationSent"] = True
            report["cancelSentUptime"] = clock.monotonic()

    def collect_messages(duration):
        messages = []
        def drain_buffer():
            while b"\n" in client.buffer:
                line, _, tail = client.buffer.partition(b"\n")
                client.buffer[:] = tail
                message = json.loads(line)
                # This test never requests camera images. Reject an unexpected
                # image before adding response data to the evidence journal.
                content = message.get("result", {}).get("content", [])
                require(not any(item.get("type") == "image" for item in content), "Unexpected image response")
                messages.append(message)
                require(len(messages) <= 256, "Unexpectedly many MCP responses")
        deadline = clock.monotonic() + duration
        while clock.monotonic() < deadline:
            drain_buffer()
            if client.selector.select(timeout=min(.05, max(0, deadline - clock.monotonic()))):
                data = client.proc.stdout.read1(65536)
                require(bool(data), "MCP helper exited during cancellation")
                client.buffer.extend(data)
                require(len(client.buffer) <= 1_000_000, "Unexpectedly large MCP response")
        # A read at the deadline must not leave an already-received cancelled
        # completion unchecked merely because the collection window just ended.
        drain_buffer()
        require(not client.buffer, "Incomplete MCP response at evidence deadline")
        return messages

    persist()
    with (out / "stderr.log").open("w") as stderr:
        try:
            require(args.zoom is True, "Explicit --zoom is required")
            require(not os.environ.get("POCKET3_BRIDGE_DIRECTORY"), "A live test cannot use an overridden IPC fixture")
            require(all(isinstance(value, str) and bool(value) for value in binding.values()), "Explicit binding is required")
            report["helperSHA256"] = hashlib.sha256(Path(args.binary).read_bytes()).hexdigest()
            status(ready=True, access="control", fresh=True)
            baseline = read_zoom()
            ZOOM.valid_target(args.target_raw, baseline)
            require(baseline["current"] == args.expected_raw, "Initial zoom changed")
            require(abs(args.target_raw - args.expected_raw) >= max(30, baseline["step"] * 10),
                    "Target is too close to establish in-motion cancellation")
            report["capabilities"] = baseline
            client = client_factory(args.binary, stderr)
            initialized, _, _ = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "Pocket3LiveZoomCancellation", "version": "1"}})
            require(initialized.get("protocolVersion") == "2025-11-25", "Unexpected MCP protocol")
            client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            listing, _, _ = client.request("tools/list", {})
            require(len(listing.get("tools", [])) == 6 and {x["name"] for x in listing["tools"]} == ZOOM.TOOLS, "Unexpected MCP tool set")
            status(ready=True, access="control", fresh=True)
            require(read_zoom()["current"] == args.expected_raw, "Zoom changed before submission")
            request_id = client.next_id
            client.next_id += 1
            report["requestID"] = request_id
            report["requestSentUptime"] = clock.monotonic()
            persist()
            write_attempted = True
            client.send({"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                         "params": {"name": "camera_set_zoom", "arguments": {
                             "rawValue": args.target_raw, "expectedSessionID": args.session}}})
            sign = 1 if args.target_raw > args.expected_raw else -1
            progress = set()
            deadline = clock.monotonic() + 2
            while clock.monotonic() < deadline:
                current = status(access="control")
                zoom = read_zoom()
                ZOOM.capabilities(zoom, baseline)
                raw = zoom["current"]
                report["samples"].append({"stage": "before-cancel", "uptime": clock.monotonic(),
                    "raw": raw, "phase": current["phase"], "motionActive": current["motionActive"]})
                require((raw - args.expected_raw) * sign >= 0, "Zoom moved in the wrong direction")
                require((args.target_raw - raw) * sign > baseline["step"], "Zoom completed or passed target before cancellation")
                if current["phase"] == "moving" and current["motionActive"] is True and (raw - args.expected_raw) * sign >= 2 * baseline["step"]:
                    progress.add(raw)
                if len(progress) >= 2:
                    break
                clock.sleep(.06)
            require(len(progress) >= 2, "No two distinct moving readbacks before cancel")
            report["distinctProgressReadbacks"] = sorted(progress)
            persist()
            cancel_request("Bounded live zoom cancellation acceptance")
            persist()
            deadline = clock.monotonic() + 7
            stable = []
            while clock.monotonic() < deadline:
                current = status()
                sample = {"stage": "after-cancel", "uptime": clock.monotonic(),
                          "phase": current["phase"], "motionActive": current["motionActive"], "access": current["access"]}
                report["samples"].append(sample)
                if current["phase"] == "ready" and current["motionActive"] is False and current["access"] == "observe":
                    zoom = read_zoom(); ZOOM.capabilities(zoom, baseline)
                    sample["raw"] = zoom["current"]
                    require((args.target_raw - sample["raw"]) * sign > baseline["step"], "Cancelled zoom reached or passed its original target")
                    require((sample["raw"] - args.expected_raw) * sign > 0, "No intermediate zoom to verify")
                    stable.append(sample)
                    if max(x["raw"] for x in stable) - min(x["raw"] for x in stable) > baseline["step"]:
                        stable = [sample]
                    if len(stable) >= 5 and stable[-1]["uptime"] - stable[0]["uptime"] >= 1:
                        break
                else:
                    stable = []
                clock.sleep(.1)
            require(len(stable) >= 5 and stable[-1]["uptime"] - stable[0]["uptime"] >= 1,
                    "No confirmed stable intermediate zoom after MCP cancellation")
            report["stableDurationSeconds"] = stable[-1]["uptime"] - stable[0]["uptime"]
            report["finalRaw"] = stable[-1]["raw"]
            # The SDK suppresses the cancelled request's response. Check the
            # transport still serves a new request and collect all queued IDs.
            followup_id = client.next_id; client.next_id += 1
            client.send({"jsonrpc": "2.0", "id": followup_id, "method": "tools/list", "params": {}})
            messages = collect_messages(.5)
            require(not any(x.get("id") == request_id for x in messages), "Cancelled request emitted a completion reply")
            response = [x for x in messages if x.get("id") == followup_id]
            require(len(response) == 1 and {x["name"] for x in response[0].get("result", {}).get("tools", [])} == ZOOM.TOOLS,
                    "MCP helper was not usable after cancellation")
            report["cancelledReplySuppressed"] = True
            report["helperRemainedUsable"] = True
            status(ready=True, access="observe", fresh=True)
            report.update(passed=True, status="complete")
        except BaseException as error:
            report.update(passed=False, status="failed", error=f"{type(error).__name__}: {error}")
            if write_attempted and client is not None:
                try:
                    cancel_request("Failed acceptance; cancel original request")
                except BaseException as cancel_error:
                    report["cancelError"] = str(cancel_error)
                try:
                    status()
                    report["clientStopSent"] = True
                    report["cleanupStop"] = cli("stop")
                    status()
                except BaseException as stop_error:
                    report["cleanupError"] = str(stop_error)
            persist(required=False)
        finally:
            try:
                if client is not None:
                    client.close()
            except BaseException as error:
                report.update(passed=False, status="failed", clientCloseFailure=f"{type(error).__name__}: {error}")
            finally:
                report["finishedAt"] = datetime.now(timezone.utc).isoformat()
                persist(required=False)
    return report, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    parser.add_argument("--output", default=str(Path(__file__).resolve().parents[1] / "artifacts/mcp-zoom-cancellation"))
    parser.add_argument("--zoom", action="store_true", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--expected-raw", type=int, required=True)
    parser.add_argument("--target-raw", type=int, required=True)
    args = parser.parse_args()
    def interrupt(signum, frame):
        raise KeyboardInterrupt(f"Signal {signum}")
    signal.signal(signal.SIGTERM, interrupt)
    report, output = run(args)
    print(json.dumps({k: report.get(k) for k in ["passed", "status", "finalRaw", "stableDurationSeconds", "clientStopSent", "error"]}
                     | {"report": str(output)}, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
