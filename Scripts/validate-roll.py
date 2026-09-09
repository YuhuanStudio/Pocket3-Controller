#!/usr/bin/env python3
"""One advertised Roll step and restoration on an already connected camera.

Requires an explicitly launched development App. Does not connect the camera,
pair Bluetooth, or change Wi-Fi. Stop/restoration never cross a capture session.
"""
import argparse
import datetime
import json
import pathlib
import subprocess
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
cli = root / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
report = {"runID": str(uuid.uuid4()), "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "passed": False, "status": "running", "physicalCameraAccess": True,
          "scope": "one advertised raw Roll step, exact readback and restoration; not physical calibration or moving-stop validation"}

def save():
    (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

def call(*arguments):
    result = subprocess.run([str(cli), *map(str, arguments)], capture_output=True, text=True, timeout=20)
    if result.returncode:
        try:
            error = json.loads(result.stderr)
        except json.JSONDecodeError:
            error = {"code": "malformed_cli_error"}
        raise RuntimeError(json.dumps(error, ensure_ascii=False))
    return json.loads(result.stdout)

def same_connection():
    current = call("status")
    return (current.get("capture", {}).get("sessionID") == report["sessionID"]
            and current.get("gimbal", {}).get("registryID") == report["registryID"])

save()
attempted = False
try:
    before = call("status")
    assert before.get("phase") == "ready", "Connect the camera and end other actions first"
    frame = before.get("capture", {}).get("frame")
    assert frame and before["capture"].get("age", 10) < 1, "A fresh camera frame is required"
    report["sessionID"] = before["capture"]["sessionID"]
    report["registryID"] = before.get("gimbal", {}).get("registryID")
    assert report["registryID"], "An exact USB attachment is required"
    report["buildVersion"] = before.get("buildVersion")
    report["before"] = call("roll-status", "--session", report["sessionID"])
    capability = report["before"]
    low, high, step, initial = (capability.get(key) for key in ["minimum", "maximum", "step", "current"])
    assert capability.get("writable") and all(type(value) is int for value in [low, high, step, initial])
    assert -32768 <= low <= initial <= high <= 32767 and step > 0 and (initial - low) % step == 0
    target = initial + step if initial + step <= high else initial - step
    assert low <= target <= high and target != initial, "No single-step target is available"
    report["target"] = target
    call("validation-setup", "--access", "observe")
    report["beforeImage"] = call("snapshot", "--output", args.output / "before.jpg", "--max-dimension", "1280")
    assert same_connection(), "Connection changed before Roll write"
    attempted = True
    report["movement"] = call("validation-roll", "--raw", target, "--session", report["sessionID"])
    save()
    assert report["movement"].get("verified") and report["movement"].get("observed") == target, "Roll target was not confirmed"
    call("validation-setup", "--access", "observe")
    report["afterImage"] = call("snapshot", "--output", args.output / "after.jpg", "--max-dimension", "1280")
    first = report["beforeImage"]["metadata"]
    second = report["afterImage"]["metadata"]
    assert first["sessionID"] == second["sessionID"] == report["sessionID"]
    assert second["id"] != first["id"] and second["receivedUptime"] > first["receivedUptime"], "A distinct fresh post-action frame is required"
    assert same_connection(), "Connection changed after Roll write"
except Exception as error:
    report["failure"] = str(error)
finally:
    if attempted:
        try:
            assert same_connection(), "Connection changed; old-session cleanup was not sent"
            report["stop"] = call("stop")
            assert report["stop"].get("verified"), "Stop was not confirmed; automatic restoration was withheld"
            assert same_connection(), "Connection changed before restoration"
            report["restoration"] = call("validation-roll", "--raw", report["before"]["current"], "--session", report["sessionID"])
            report["restored"] = bool(report["restoration"].get("verified")
                and report["restoration"].get("observed") == report["before"]["current"])
            report["finalStop"] = call("stop")
        except Exception as error:
            report["cleanupFailure"] = str(error)
    report["passed"] = bool(not report.get("failure") and not report.get("cleanupFailure")
        and report.get("movement", {}).get("verified") and report.get("restored") and report.get("finalStop", {}).get("verified"))
    report["status"] = "complete" if report["passed"] else "failed"
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
print(json.dumps({"passed": report["passed"], "report": str(args.output / "result.json"),
                  "failure": report.get("failure"), "cleanupFailure": report.get("cleanupFailure")}, ensure_ascii=False))
raise SystemExit(0 if report["passed"] else 1)
