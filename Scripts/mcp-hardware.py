#!/usr/bin/env python3
"""Bounded live MCP acceptance: capture, right, left, stop, denied move.

Requires an already connected camera with control access and validated stopping.
This never connects, enables access, retries a move, or restores by issuing extra
movement. JPEG evidence and actual USB readback are saved locally. USB readback
does not establish a calibrated physical angle.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import selectors
import signal
import subprocess
import time
import uuid


MAX_STEP = 3600
READBACK_TOLERANCE = 720
ROUND_TRIP_TOLERANCE = 2 * READBACK_TOLERANCE
TOOLS = {"camera_status", "capture_frame", "move_gimbal", "stop_gimbal", "camera_zoom_status", "camera_set_zoom"}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def position(value):
    require(isinstance(value, dict), "Missing UVC position")
    require(all(number(value.get(axis)) and int(value[axis]) == value[axis]
                for axis in ("pan", "tilt")), "Invalid UVC position")
    return {axis: int(value[axis]) for axis in ("pan", "tilt")}


def distance(first, second):
    return max(abs(first[axis] - second[axis]) for axis in ("pan", "tilt"))


class MCPClient:
    def __init__(self, binary, stderr):
        self.proc = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=stderr,
                                     start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.next_id = 1

    def send(self, payload):
        self.proc.stdin.write((json.dumps(payload, allow_nan=False) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params, timeout=25):
        request_id = self.next_id
        self.next_id += 1
        sent = time.monotonic()
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = sent + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, _, tail = self.buffer.partition(b"\n")
                self.buffer[:] = tail
                message = json.loads(line)
                # Notifications and a late response to an earlier timed-out call
                # cannot satisfy this request (in particular a cleanup Stop).
                if message.get("id") != request_id:
                    continue
                require("error" not in message, f"JSON-RPC error: {message.get('error')}")
                result = message.get("result")
                require(isinstance(result, dict), "Missing JSON-RPC result")
                return result, sent, time.monotonic()
            if self.selector.select(timeout=min(0.5, max(0, deadline - time.monotonic()))):
                chunk = self.proc.stdout.read1(65536)
                require(bool(chunk), "MCP helper exited before replying")
                self.buffer.extend(chunk)
                require(len(self.buffer) <= 20_000_000, "MCP response exceeds evidence limit")
        try:
            self.send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                       "params": {"requestId": request_id, "reason": "Acceptance request timed out"}})
        except (OSError, ValueError):
            pass
        raise TimeoutError(f"MCP request {request_id} ({method}) timed out")

    def close(self):
        try:
            self.proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        self.selector.close()
        self.proc.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    parser.add_argument("--output", default="artifacts/mcp-hardware",
                        help="Parent directory; each run gets a unique evidence subdirectory")
    parser.add_argument("--motion", action="store_true", required=True,
                        help="Explicitly permit the bounded two-step test and Stop cleanup")
    args = parser.parse_args()
    run_id = str(uuid.uuid4())
    out = Path(args.output).resolve() / run_id
    out.mkdir(parents=True, exist_ok=False)
    report = {
        "id": run_id, "startedAt": datetime.now(timezone.utc).isoformat(),
        "passed": False, "status": "running", "motionExplicitlyEnabled": args.motion,
        "thresholds": {"maxStepUVC": MAX_STEP, "readbackToleranceUVC": READBACK_TOLERANCE,
                       "roundTripToleranceUVC": ROUND_TRIP_TOLERANCE, "frameAgeSeconds": 1},
        "scope": "Live packaged MCP helper and current App; no simulated motion",
        "limitations": ["UVC readback is not a calibrated physical angle",
                        "Fresh post-move evidence follows the App's settle-then-capture contract",
                        "No retry or extra restoration move is issued after any uncertain result"],
        "calls": [], "actions": [], "successfulMoves": 0,
    }
    result_path = out / "result.json"

    def persist():
        temporary = out / "result.json.tmp"
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
        temporary.replace(result_path)

    def record_result(result, label):
        # Never serialize image base64 into reports or print it to the console.
        evidence = []
        for index, item in enumerate(result.get("content", [])):
            if item.get("type") == "image":
                data = base64.b64decode(item.get("data", ""), validate=True)
                require(item.get("mimeType") == "image/jpeg", "Expected JPEG evidence")
                require(len(data) > 1000 and data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"),
                        "Invalid or unexpectedly small JPEG evidence")
                filename = f"{label}-{index}.jpg"
                (out / filename).write_bytes(data)
                evidence.append({"type": "image", "mimeType": "image/jpeg", "file": filename,
                                 "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            elif item.get("type") == "text":
                evidence.append({"type": "text", "text": item.get("text", "")})
            else:
                evidence.append({"type": item.get("type", "unknown")})
        return {"isError": result.get("isError", False),
                "structuredContent": result.get("structuredContent"), "content": evidence}

    def call(name, arguments=None, label=None, timeout=25):
        label = label or f"{len(report['calls']) + 1:02d}-{name}"
        entry = {"name": name, "arguments": arguments or {}, "label": label}
        report["calls"].append(entry)
        persist()
        try:
            result, sent, received = client.request("tools/call", {
                "name": name, "arguments": arguments or {}}, timeout=timeout)
            entry.update({"sentUptime": sent, "receivedUptime": received,
                          "elapsedSeconds": received - sent, "result": record_result(result, label)})
            persist()
            return result, sent, received
        except BaseException as error:
            entry["failure"] = f"{type(error).__name__}: {error}"
            persist()
            raise

    def structured(result):
        require(result.get("isError") is not True, "MCP tool returned an error; see recorded response")
        value = result.get("structuredContent")
        require(isinstance(value, dict), "Missing structured tool result")
        return value

    def status(label):
        value = structured(call("camera_status", label=label)[0])
        if report.get("sessionID"):
            require(value.get("capture", {}).get("sessionID") == report["sessionID"],
                    "Camera session changed during acceptance")
            require(value.get("selected", {}).get("id") == report["deviceID"],
                    "Selected device changed during acceptance")
        return value

    def checked_frame(result, sent, received, previous=None):
        value = structured(result)
        frame = value.get("frame", value)
        require(frame.get("sessionID") == report["sessionID"], "Image belongs to another session")
        require(frame.get("deviceID") == report["deviceID"], "Image belongs to another device")
        require(frame.get("timestampSource") == "host_callback_and_avfoundation_pts", "Unexpected image timestamp source")
        require(isinstance(frame.get("id"), str) and bool(frame["id"]), "Missing frame ID")
        require(number(frame.get("receivedUptime")), "Missing finite frame uptime")
        # Python's macOS monotonic clock and ProcessInfo.systemUptime use host
        # uptime. Initial capture may use an existing <= 1-second-old frame.
        require(0 <= received - frame["receivedUptime"] <= 1, "Returned image is stale or clock changed")
        if previous:
            require(frame["id"] != previous["id"], "Move returned the prior frame ID")
            require(frame["receivedUptime"] > max(sent, previous["receivedUptime"]),
                    "Move image predates the request or prior frame")
            require(number(frame.get("presentationTime")) and frame["presentationTime"] > previous["presentationTime"],
                    "Move image presentation time did not advance")
        require(all(number(frame.get(axis)) and 0 < frame[axis] <= 1280 for axis in ("width", "height")),
                "Invalid JPEG dimensions")
        require(sum(item.get("type") == "image" for item in result.get("content", [])) == 1,
                "Expected exactly one image from capture/move")
        return frame

    def stop(label):
        action = structured(call("stop_gimbal", label=label, timeout=8)[0])
        report.setdefault("stops", []).append(action)
        require(all(action.get(flag) is True for flag in ("accepted", "completed", "verified")),
                "Stop did not return confirmed completion")
        require(action.get("verification") == "hold_current_target_and_stable_uvc_readback",
                "Stop did not use real UVC hold/readback verification")
        require(distance(position(action.get("target")), position(action.get("observed"))) <= 1080,
                "Stop readback residual exceeds production limit")
        persist()

    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"Received signal {signum}; stopping without restoration moves")

    signal.signal(signal.SIGTERM, interrupted)
    client = None
    stderr = (out / "stderr.log").open("w")
    persist()
    try:
        client = MCPClient(str(Path(args.binary).resolve()), stderr)
        init, _, _ = client.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "Pocket3HardwareAcceptance", "version": "1"}})
        report["protocolVersion"] = init.get("protocolVersion")
        require(init.get("protocolVersion") == "2025-11-25", "Unexpected MCP protocol version")
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        listing, _, _ = client.request("tools/list", {})
        require({tool["name"] for tool in listing.get("tools", [])} == TOOLS, "Unexpected MCP tool set")
        initial = status("initial-status")
        require(initial.get("phase") == "ready" and initial.get("motionActive") is False,
                "Camera must be ready with no active motion")
        require(initial.get("access") == "control" and initial.get("stopValidated") is True,
                "App must already have control access and validated stopping")
        gimbal = initial.get("gimbal") or {}
        require(gimbal.get("writable") is True, "UVC control is not writable")
        original = position(gimbal.get("position"))
        low, high = position(gimbal.get("minimum")), position(gimbal.get("maximum"))
        require(all(low[axis] <= original[axis] <= high[axis] for axis in ("pan", "tilt")),
                "Original position exceeds declared UVC range")
        require(original["pan"] + MAX_STEP + READBACK_TOLERANCE <= high["pan"]
                and original["pan"] - 2 * READBACK_TOLERANCE >= low["pan"],
                "Insufficient pan range for a right/left pair with readback tolerance")
        report.update({"sessionID": initial["capture"]["sessionID"],
                       "deviceID": initial["selected"]["id"], "originalPosition": original,
                       "registryID": gimbal.get("registryID"), "bootSessionID": gimbal.get("bootSessionID")})
        require(bool(report["sessionID"]) and bool(report["deviceID"]), "Missing live session identity")
        frame = checked_frame(*call("capture_frame", {"maxDimension": 1280}, "initial-capture"))
        for direction, offset in (("right", MAX_STEP), ("left", -MAX_STEP)):
            before = status(f"before-{direction}")
            require(before.get("phase") == "ready" and before.get("access") == "control"
                    and before.get("stopValidated") is True and before.get("motionActive") is False,
                    "Access or readiness changed before movement")
            before_position = position(before["gimbal"]["position"])
            result, sent, received = call("move_gimbal", {"direction": direction}, direction)
            value = structured(result)
            action = value.get("action") or {}
            report["actions"].append({"direction": direction, "motion": action})
            persist()
            require(all(action.get(flag) is True for flag in ("accepted", "completed", "verified")),
                    f"{direction} move lacks confirmed completion; no retry or second move")
            require(action.get("verification") == "stable_uvc_readback_with_tolerance"
                    and isinstance(action.get("id"), str) and bool(action["id"]),
                    "Move lacks actual UVC verification and action ID")
            target, observed = position(action.get("target")), position(action.get("observed"))
            expected = {"pan": before_position["pan"] + offset, "tilt": before_position["tilt"]}
            require(distance(target, expected) <= READBACK_TOLERANCE,
                    "Move target is inconsistent with a single bounded step")
            require(distance(target, observed) <= READBACK_TOLERANCE, "Move readback exceeded tolerance")
            frame = checked_frame(result, sent, received, previous=frame)
            report["successfulMoves"] += 1
            persist()
        require(len({entry["motion"]["id"] for entry in report["actions"]}) == 2, "Duplicate motion IDs")
        stop("stop-after-pair")
        stopped = status("status-after-stop")
        require(stopped.get("access") == "observe" and stopped.get("motionActive") is False,
                "Stop did not revoke control access or clear motion")
        denied, _, _ = call("move_gimbal", {"direction": "right"}, "denied-after-stop")
        require(denied.get("isError") is True, "Move was not denied after Stop revoked access")
        require(not any(item.get("type") == "image" for item in denied.get("content", [])),
                "Denied move unexpectedly returned an image")
        failures = [json.loads(item["text"]) for item in denied.get("content", []) if item.get("type") == "text"]
        require(any(failure.get("code") == "movement_denied" for failure in failures),
                "Move failed for a reason other than revoked movement permission")
        report["deniedAfterStop"] = True
        stop("final-stop")
        final = status("final-status")
        require(final.get("phase") == "ready" and final.get("access") == "observe"
                and final.get("motionActive") is False, "Unexpected final camera state")
        final_position = position(final["gimbal"]["position"])
        report["finalPosition"] = final_position
        report["finalResidualUVC"] = {axis: final_position[axis] - original[axis] for axis in ("pan", "tilt")}
        report["finalMaxResidualUVC"] = distance(final_position, original)
        require(report["finalMaxResidualUVC"] <= ROUND_TRIP_TOLERANCE,
                "Final position exceeds the two-move readback tolerance; no restoration move issued")
        report.update({"passed": True, "status": "completed"})
    except BaseException as error:
        report.update({"passed": False, "status": "interrupted" if isinstance(error, KeyboardInterrupt) else "failed",
                       "failure": f"{type(error).__name__}: {error}"})
        # A Stop is the only mutation permitted after failure. No move is retried.
        if client:
            try:
                stop("failure-stop")
                report["cleanupStopConfirmed"] = True
            except BaseException as cleanup_error:
                report["cleanupStopFailure"] = f"{type(cleanup_error).__name__}: {cleanup_error}"
                # If stdio failed, the packaged CLI still has an independent IPC
                # path to Stop. This is another hold request, never a move retry.
                try:
                    fallback = subprocess.run([str(Path(args.binary).resolve()), "stop"],
                                              capture_output=True, text=True, timeout=8)
                    report["fallbackStop"] = {"exitCode": fallback.returncode,
                                              "stdout": fallback.stdout, "stderr": fallback.stderr}
                except BaseException as fallback_error:
                    report["fallbackStopFailure"] = f"{type(fallback_error).__name__}: {fallback_error}"
            if report.get("originalPosition"):
                try:
                    current = status("failure-final-status")
                    final_position = position(current["gimbal"]["position"])
                    report["finalPosition"] = final_position
                    report["finalResidualUVC"] = {axis: final_position[axis] - report["originalPosition"][axis]
                                                  for axis in ("pan", "tilt")}
                    report["finalMaxResidualUVC"] = distance(final_position, report["originalPosition"])
                except BaseException as final_error:
                    report["finalPositionFailure"] = f"{type(final_error).__name__}: {final_error}"
    finally:
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        persist()
        if client:
            client.close()
        stderr.close()
    print(json.dumps({key: report.get(key) for key in
                      ("id", "passed", "status", "successfulMoves", "deniedAfterStop", "finalMaxResidualUVC", "failure")}
                     | {"report": str(result_path)}, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
