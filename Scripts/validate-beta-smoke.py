#!/usr/bin/env python3
"""Bounded real-camera beta smoke test with same-session cleanup.

Requires the development App already open and one explicitly named camera.
Does not pair Bluetooth, change Wi-Fi, record audio, or modify native settings.
"""
import argparse
import datetime
import hashlib
import json
import math
import pathlib
import subprocess
import time
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
app = root / "dist/Pocket 3 Controller.app"
cli = app / "Contents/MacOS/pocket3"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--mode", default="1920x1080@30")
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
report = {"runID": str(uuid.uuid4()), "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "passed": False, "status": "running", "physicalCameraAccess": True,
          "cameraSettingsWritten": False, "macNetworkChanged": False,
          "scope": "preview, actual manual input/release, zoom roundtrip, privacy pause and reconnect; not full-range or mechanical stopping calibration",
          "sessionGuard": "Client checks session, device and USB attachment before and after each operation. Stop/manual-input/position-probe RPCs do not provide an atomic expected-session guard; do not reconnect or operate the App concurrently.",
          "restorationToleranceRaw": 1080,
          "checks": {}}

def save():
    (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

def call(*arguments):
    result = subprocess.run([str(cli), *map(str, arguments)], capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[:4000] or f"CLI exited with code {result.returncode}")
    return json.loads(result.stdout)

def require(condition, message):
    # Safety checks must remain active when Python is invoked with -O.
    if not condition:
        raise RuntimeError(message)

def record(name, value):
    report[name] = value
    (args.output / (name + ".json")).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    save()
    return value

def status():
    return call("status")

def identity(s):
    capture, gimbal, selected = (s.get(key) or {} for key in ("capture", "gimbal", "selected"))
    return {"sessionID": capture.get("sessionID"), "registryID": gimbal.get("registryID"),
            "bootSessionID": gimbal.get("bootSessionID"), "deviceID": selected.get("id")}

def bind_connection(s):
    global connected
    binding = identity(s)
    require(all(isinstance(value, str) and value for value in binding.values()), "Missing capture/USB attachment identity")
    require(binding["deviceID"] == args.device, "Connected camera does not match --device")
    report.update(binding)
    report.setdefault("connections", []).append(binding)
    connected = True
    save()

def same_connection(s=None):
    expected = {key: report.get(key) for key in ("sessionID", "registryID", "bootSessionID", "deviceID")}
    return all(expected.values()) and identity(status() if s is None else s) == expected

def checked_status():
    s = status()
    require(same_connection(s), "Connection changed; old-session operations were not sent")
    return s

def checked_call(*arguments):
    checked_status()
    result = call(*arguments)
    checked_status()
    return result

def fresh_capture():
    for _ in range(40):
        s = checked_status()
        capture = s.get("capture") or {}
        age, fps = capture.get("age"), capture.get("recentFPS")
        if (s.get("phase") == "ready" and isinstance(age, (int, float)) and math.isfinite(age)
                and 0 <= age < 1 and isinstance(fps, (int, float)) and math.isfinite(fps) and fps >= 20):
            return s
        time.sleep(.1)
    raise RuntimeError("The camera did not reach a fresh stable preview")

def restore_position():
    original = report["originalPosition"]
    tolerance = report["restorationToleranceRaw"]
    # This endpoint accepts exactly one absolute axis and a fresh exact raw
    # origin. Four nominal UVC degrees stays inside its five-degree bound.
    # Stop after any uncertain write; finally performs Stop only, never a retry.
    for attempt in range(8):
        s = checked_status()
        current = s["gimbal"]["position"]
        require(s.get("phase") == "ready" and not s.get("motionActive"), "Finish the current operation before restoring position")
        require(all(type(current.get(axis)) is int for axis in ("pan", "tilt")), "Missing integer UVC readback")
        residual = {axis: current[axis] - original[axis] for axis in ("pan", "tilt")}
        if max(map(abs, residual.values())) <= tolerance:
            return {"verified": True, "original": original, "observed": current,
                    "residualRaw": residual, "toleranceRaw": tolerance, "commands": attempt}
        require(max(map(abs, residual.values())) <= 36000, "Restoration residual exceeds the small-gesture budget")
        axis = max(residual, key=lambda key: abs(residual[key]))
        delta = max(-14400, min(14400, original[axis] - current[axis]))
        target = current[axis] + delta
        result = call("validation-position-probe", "--" + axis, target / 3600,
                      "--expected-pan-raw", current["pan"], "--expected-tilt-raw", current["tilt"])
        record(f"position-restoration-step-{attempt + 1}", result)
        checked_status()
        require(result.get("accepted") and result.get("completed") and result.get("verified"), "Position restoration was not confirmed; no retry")
        require((result.get("target") or {}).get(axis) == target, "Position restoration returned another target")
        observed = (result.get("observed") or {}).get(axis)
        require(type(observed) is int and abs(observed - original[axis]) < abs(residual[axis]), "Position restoration did not make confirmed progress; no retry")
    raise RuntimeError("Position restoration exceeded its bounded step budget")

save()
connected = False
position_dirty = False
zoom_dirty = False
try:
    initial = record("initial", status())
    require(initial.get("appVersion") == "0.0.1-beta.1", "Open the beta candidate before running this test")
    require(len(initial["devices"]) == 1 and initial["devices"][0]["id"] == args.device, "Camera selection is ambiguous")
    # validation-connect currently uses selected.id (or the first device); the
    # CLI has no --device flag. Reject a stale selection before it can reconnect.
    require((initial.get("selected") or {}).get("id", args.device) == args.device, "Select the explicitly named camera in the App first")
    require(not initial.get("motionActive") and initial.get("phase") in ("idle", "paused", "ready", "stalled", "error"), "End current camera operations first")
    report["appExecutableSHA256"] = hashlib.sha256((app / "Contents/MacOS/Pocket3MCP").read_bytes()).hexdigest()
    # Bind the successful connect reply immediately: freshness may subsequently
    # fail, but cleanup still belongs to this new connection.
    response = record("connect-reply", call("validation-connect", "--mode", args.mode, "--pixel-format", "nv12"))
    bind_connection(response)
    s = record("connected", fresh_capture())
    report["originalPosition"] = s["gimbal"]["position"]
    width, height = map(int, args.mode.split("@")[0].split("x"))
    require((s["capture"]["frame"]["width"], s["capture"]["frame"]["height"]) == (width, height), "Preview dimensions do not match the requested mode")
    checked_call("validation-setup", "--access", "observe")
    image = record("preview", checked_call("snapshot", "--output", args.output / "preview.jpg", "--max-dimension", "1280"))
    require(image["metadata"]["sessionID"] == report["sessionID"] and image["bytes"] > 0, "Snapshot is empty or belongs to another session")
    report["checks"]["freshPreviewAndSnapshot"] = True

    require(s["gimbal"]["maximum"]["pan"] - report["originalPosition"]["pan"] >= 36000, "Insufficient headroom for the right-button test")
    position_dirty = True
    manual = record("manual-release", checked_call("validation-manual-control", "--gesture", "button", "--ending", "release"))
    require(manual.get("passed") and manual["after"]["position"] != manual["before"]["position"], "Manual input/release failed or produced no position change")
    require(all((manual.get(key) or {}).get("registryID") == report["registryID"]
                and (manual.get(key) or {}).get("bootSessionID") == report["bootSessionID"]
                for key in ("before", "after")), "Manual input evidence belongs to another USB attachment")
    record("position-restoration", restore_position())
    position_dirty = False
    report["checks"]["manualInputReleaseAndRestoration"] = True

    zoom = record("zoom-before", checked_call("zoom-status", "--session", report["sessionID"]))
    low, high, step, current = (zoom.get(key) for key in ["minimum", "maximum", "step", "current"])
    require(zoom.get("writable") and all(type(value) is int for value in [low, high, step, current])
            and step > 0 and 0 <= low <= current <= high <= 65535 and (current - low) % step == 0,
            "Zoom does not provide a writable, restorable raw value and step")
    delta = max(1, min(10, (high - low) // step)) * step
    target = current + delta if current + delta <= high else current - delta
    require(low <= target <= high and target != current, "No different bounded zoom target is available")
    zoom_dirty = True
    moved = record("zoom-target", checked_call("validation-zoom", "--raw", target, "--session", report["sessionID"]))
    require(moved.get("accepted") and moved.get("completed") and moved.get("verified") and moved.get("target") == target, "Zoom target was not confirmed")
    restored = record("zoom-restoration", checked_call("validation-zoom", "--raw", current, "--session", report["sessionID"]))
    require(restored.get("accepted") and restored.get("completed") and restored.get("verified") and restored.get("target") == current, "Zoom restoration was not confirmed; no retry")
    zoom_dirty = False
    report["checks"]["zoomRoundTrip"] = True
    record("stop", checked_call("stop"))
    require(report["stop"].get("verified"), "Stop was not confirmed")

    checked_status()
    paused = record("paused", call("validation-pause"))
    require(paused["phase"] == "paused" and paused["capture"].get("frame") is None and not paused.get("motionActive"), "Privacy pause did not clear the frame and stop motion")
    connected = False
    report["checks"]["privacyPause"] = True
    old_session = report["sessionID"]
    response = record("reconnect-reply", call("validation-connect", "--mode", args.mode, "--pixel-format", "nv12"))
    bind_connection(response)
    s = record("reconnected", fresh_capture())
    require(s["capture"]["sessionID"] != old_session and s["selected"]["id"] == args.device, "Reconnect did not create a new session for the selected camera")
    report["checks"]["reconnectNewSession"] = True
except Exception as error:
    report["failure"] = str(error)
finally:
    report["restorationPending"] = {"position": position_dirty, "zoom": zoom_dirty}
    if connected:
        try:
            stopped = record("final-stop", checked_call("stop"))
            require(stopped.get("verified"), "Cleanup stop was not confirmed")
            final = record("cleanup-status", checked_status())
            if position_dirty:
                original = report["originalPosition"]
                report["positionRestorationIncomplete"] = {
                    "original": original, "observed": final["gimbal"]["position"],
                    "reason": "An operation failed or was uncertain; no restoration write was retried after Stop"}
            if zoom_dirty:
                report["zoomRestorationIncomplete"] = {
                    "original": report["zoom-before"]["current"],
                    "reason": "An operation failed or was uncertain; no zoom write was retried after Stop"}
        except Exception as error:
            report["cleanupFailure"] = str(error)
    report["passed"] = bool(not report.get("failure") and not report.get("cleanupFailure")
                            and len(report["checks"]) == 5 and all(report["checks"].values()))
    report["status"] = "complete" if report["passed"] else "failed"
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
print(json.dumps({"passed": report["passed"], "checks": report["checks"], "failure": report.get("failure"),
                  "cleanupFailure": report.get("cleanupFailure"), "report": str(args.output / "result.json")}, ensure_ascii=False))
raise SystemExit(0 if report["passed"] else 1)
