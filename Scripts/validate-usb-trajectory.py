#!/usr/bin/env python3
"""One bounded development probe. Never retries or changes a network."""
import argparse
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--direction", choices=["left", "right", "up", "down"], required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
cli = root / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3"


def call(*arguments):
    result = subprocess.run([str(cli), *arguments], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


report = {"direction": args.direction, "physicalMotionVerified": False}
probe_started = False
try:
    call("validation-setup", "--access", "observe")
    report["beforeImage"] = call("snapshot", "--output", str(args.output / "before.jpg"))
    before = call("status")
    report["before"] = {key: before.get(key) for key in ("phase", "capture", "gimbal")}
    origin = before["gimbal"]["position"]
    probe_started = True
    report["probe"] = call("validation-trajectory-probe", "--direction", args.direction,
        "--expected-pan-raw", str(origin["pan"]), "--expected-tilt-raw", str(origin["tilt"]))
    call("validation-setup", "--access", "observe")
    report["afterImage"] = call("snapshot", "--output", str(args.output / "after.jpg"))
except Exception as error:
    report["driverError"] = str(error)
finally:
    # The service probe always invokes its independent Stop path. A driver
    # timeout is uncertain; request Stop once as cleanup, with no retry move.
    if probe_started and "probe" not in report:
        try:
            report["cleanupStop"] = call("stop")
        except Exception as error:
            report["cleanupError"] = str(error)
    try:
        call("validation-setup", "--access", "manual")
        after = call("status")
        report["after"] = {key: after.get(key) for key in ("phase", "capture", "gimbal")}
    except Exception as error:
        report["finalStatusError"] = str(error)
    probe = report.get("probe", {})
    samples = probe.get("samples", [])
    report["completedUSBReadbackExperiment"] = (
        "driverError" not in report and not probe.get("failure") and len(samples) == 24
        and (probe.get("stop") or {}).get("verified") is True
    )
    (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "samples": len(samples),
        "failure": probe.get("failure") or report.get("driverError"),
        "completedUSBReadbackExperiment": report["completedUSBReadbackExperiment"],
        "physicalMotionVerified": False}, ensure_ascii=False))
