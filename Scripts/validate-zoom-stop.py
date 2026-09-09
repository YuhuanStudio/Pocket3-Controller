#!/usr/bin/env python3
"""One bounded USB zoom request, interrupted after observed in-flight progress.

Requires an already connected development App in manual mode. No connection,
pairing, image capture, restoration or uncertain SET retry is performed. Stop
uses the existing global endpoint: binding checks are client-side, not atomic.
Do not operate or reconnect the App concurrently with this diagnostic.
"""
import argparse
import datetime
import json
import math
from pathlib import Path
import subprocess
import time
import uuid


TOLERANCE = 1
MINIMUM_STABLE_SECONDS = 0.8
PROGRESS_WINDOW_SECONDS = 2.5
POST_STOP_WINDOW_SECONDS = 2.0
MAXIMUM_READ_SECONDS = 0.25


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def parse_object(text):
    require(len(text) <= 131072, "CLI response exceeded the diagnostic budget")
    def invalid_constant(value):
        raise ValueError("Nonfinite JSON value: " + value)
    value = json.loads(text, parse_constant=invalid_constant)
    require(isinstance(value, dict), "CLI did not return a JSON object")
    return value


class ZoomProcess:
    def __init__(self, process, stdout, stderr):
        self.process, self.stdout, self.stderr = process, stdout, stderr

    def running(self):
        return self.process.poll() is None

    def cancel(self):
        # Only our own CLI child, never the App. Disconnecting its IPC request
        # cancels pending service work; a separate global Stop handles slew.
        if self.running():
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1)

    def collect(self, timeout=4):
        self.process.wait(timeout=timeout)
        result = {"returncode": self.process.returncode}
        for name, path in (("result", self.stdout), ("error", self.stderr)):
            with path.open() as stream:
                text = stream.read(131073)
            if text.strip():
                try:
                    result[name] = parse_object(text)
                except (ValueError, RuntimeError):
                    result[name + "Excerpt"] = text[:2000]
        return result


class CLI:
    def __init__(self, binary):
        self.binary = str(binary)

    def call(self, *arguments):
        require(arguments[0] in ("status", "zoom-status", "stop"), "Unexpected diagnostic operation")
        result = subprocess.run([self.binary, *map(str, arguments)], capture_output=True,
                                text=True, timeout=8 if arguments[0] == "stop" else 3)
        if result.returncode:
            raise RuntimeError(result.stderr.strip()[:2000] or "CLI request failed")
        return parse_object(result.stdout)

    def start_zoom(self, target, session, folder):
        stdout, stderr = folder / "zoom-request.stdout.txt", folder / "zoom-request.stderr.txt"
        with stdout.open("w") as output, stderr.open("w") as errors:
            process = subprocess.Popen([self.binary, "validation-zoom", "--raw", str(target),
                                        "--session", session], stdout=output, stderr=errors, text=True)
        return ZoomProcess(process, stdout, stderr)


def connection_identity(status):
    capture, gimbal, selected = (status.get(key) or {} for key in ("capture", "gimbal", "selected"))
    return {"deviceID": selected.get("id"), "captureSession": capture.get("sessionID"),
            "registryID": gimbal.get("registryID"), "bootSessionID": gimbal.get("bootSessionID")}


def status_summary(status):
    capture = status.get("capture") or {}
    frame = capture.get("frame") or {}
    return {"identity": connection_identity(status), "phase": status.get("phase"),
            "motionActive": status.get("motionActive"), "access": status.get("access"),
            "appVersion": status.get("appVersion"), "buildVersion": status.get("buildVersion"),
            "frameID": frame.get("id"), "frameAge": capture.get("age"),
            "panTilt": (status.get("gimbal") or {}).get("position")}


def validate_capabilities(value, baseline=None):
    low, high, step, current = (value.get(key) for key in ("minimum", "maximum", "step", "current"))
    require(value.get("writable") is True and all(type(n) is int for n in (low, high, step, current)),
            "Writable integer zoom limits/current/step are required")
    require(0 <= low <= current <= high <= 65535 and step == 1 and high - low >= 100,
            "This diagnostic requires the observed step1 / tolerance1 USB zoom profile")
    if baseline is not None:
        require(all(value[key] == baseline[key] for key in ("minimum", "maximum", "step", "writable")),
                "Zoom capabilities changed")


def validate_stop(stop, origin, destination, last_progress):
    hold = stop.get("zoomStop")
    require(isinstance(hold, dict), "Stop returned no pending zoom hold; a stationary Stop is not moving-stop proof")
    require(hold.get("submitted") is True and hold.get("verified") is True and not hold.get("failure"),
            "Zoom hold was not confirmed")
    require(hold.get("verification") == "fresh_uvc_zoom_hold_with_advertised_tolerance"
            and type(hold.get("toleranceRaw")) is int and hold["toleranceRaw"] == TOLERANCE,
            "Unexpected zoom hold verification/tolerance contract")
    duration, count = hold.get("stableDurationSeconds"), hold.get("sampleCount")
    require(finite(duration) and MINIMUM_STABLE_SECONDS - 1e-9 <= duration <= 1.2 + 1e-9
            and type(count) is int and count >= 3, "Stop did not report the full 0.8-second stable window")
    target, observed = hold.get("target"), hold.get("observed")
    require(type(target) is int and type(observed) is int and abs(observed - target) <= TOLERANCE,
            "Zoom hold target/readback is missing or outside tolerance")
    sign = 1 if destination > origin else -1
    require(sign * (target - origin) > TOLERANCE and sign * (destination - target) > TOLERANCE,
            "Hold was not strictly between origin and destination; in-flight interruption is unproven")
    require(sign * (target - last_progress) >= -TOLERANCE, "Hold target moved backwards from the last progress read")
    require(stop.get("completed") is True and stop.get("verified") is True,
            "Global Stop did not confirm all active axes; inspect zoomStop independently")
    return target


def run(args, cli, clock=time):
    folder = args.output / str(uuid.uuid4())
    folder.mkdir(parents=True, exist_ok=False)
    report = {"runID": folder.name, "startedAt": utc_now(), "passed": False, "status": "running",
              "requestedBinding": {"deviceID": args.device, "captureSession": args.session, "registryID": args.registry},
              "requestedRawTarget": args.target_raw, "photographsCaptured": False,
              "fullAdvertisedRangeOptIn": bool(getattr(args, "full_advertised_range", False)),
              "scope": "one zoom SET, progress-triggered global Stop, internal summary and independent post-Stop raw window",
              "bindingGuarantee": "client checked before/after requests; global Stop has no atomic expected-session endpoint",
              "internalStopSamplesExported": False, "restorePolicy": "leave the verified held raw position; no restoration SET",
              "baselineSamples": [], "progressSamples": [], "postStopSamples": []}
    job, binding, stop_attempted = None, None, False

    def save():
        (folder / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")

    def check_status():
        status = cli.call("status")
        require(connection_identity(status) == binding, "Connection changed; old-session cleanup was withheld")
        return status

    def zoom_read():
        started = clock.monotonic()
        value = cli.call("zoom-status", "--session", args.session)
        finished = clock.monotonic()
        require(0 <= finished - started <= MAXIMUM_READ_SECONDS, "Zoom read was too slow to use as fresh evidence")
        validate_capabilities(value, report.get("capabilities"))
        return value, {"startedMonotonic": started, "receivedMonotonic": finished,
                       "hostReceivedAt": utc_now(), "current": value["current"]}

    def send_stop():
        nonlocal stop_attempted
        check_status()
        stop_attempted = True  # Never resend an uncertain Stop/hold request.
        report["stopRequestedMonotonic"] = clock.monotonic()
        # Artifact I/O must not delay or suppress the safety request.
        result = cli.call("stop")
        report["stop"] = result
        report["stopReturnedMonotonic"] = clock.monotonic()
        report["afterStop"] = status_summary(check_status())
        save()
        return result

    save()
    try:
        initial = cli.call("status")
        identity = connection_identity(initial)
        require(all(identity.get(key) == value for key, value in report["requestedBinding"].items()), "Explicit device/session/registry binding does not match")
        require(isinstance(identity["bootSessionID"], str) and identity["bootSessionID"], "Missing USB boot-session identity")
        binding = identity; report["binding"] = binding; report["before"] = status_summary(initial)
        capture = initial.get("capture") or {}
        require(initial.get("phase") == "ready" and initial.get("motionActive") is False
                and initial.get("access") == "manual" and initial.get("controlTransport") == "usb_position",
                "The App must be ready, manual, and idle on USB; finish other operations first")
        frame = capture.get("frame") or {}
        require(finite(capture.get("age")) and 0 <= capture["age"] < 1
                and frame.get("sessionID") == args.session and frame.get("deviceID") == args.device,
                "A fresh preview from the explicit device/session is required; no image is saved")
        baseline, first = zoom_read(); report["capabilities"] = baseline
        origin = baseline["current"]; report["originalRaw"] = origin
        require(type(args.target_raw) is int and baseline["minimum"] <= args.target_raw <= baseline["maximum"], "Target is outside advertised zoom limits")
        advertised_span = baseline["maximum"] - baseline["minimum"]
        maximum_delta = advertised_span if report["fullAdvertisedRangeOptIn"] else min(100, advertised_span // 3)
        require(20 <= abs(args.target_raw - origin) <= maximum_delta,
                "Target must be at least 20 raw units away; the default limit is 100 raw / one third of the range. Full-range testing requires --full-advertised-range")
        report["baselineSamples"].append(first)
        for _ in range(3):
            clock.sleep(0.1)
            state = check_status()
            require(state.get("phase") == "ready" and state.get("motionActive") is False,
                    "Another operation started during baseline")
            value, sample = zoom_read(); report["baselineSamples"].append(sample)
            baseline_values = [item["current"] for item in report["baselineSamples"]]
            require(abs(value["current"] - origin) <= TOLERANCE and max(baseline_values) - min(baseline_values) <= TOLERANCE,
                    "Zoom was not stationary before the diagnostic")
        check_status(); save()
        job = cli.start_zoom(args.target_raw, args.session, folder)
        report["zoomStartedMonotonic"] = clock.monotonic(); save()
        deadline = clock.monotonic() + PROGRESS_WINDOW_SECONDS
        sign = 1 if args.target_raw > origin else -1
        previous = origin; progress_count = 0
        while clock.monotonic() <= deadline:
            before = check_status()
            value, sample = zoom_read()
            after = check_status()
            require(clock.monotonic() <= deadline, "Progress observation exceeded its time budget")
            sample.update({"phaseBefore": before.get("phase"), "phaseAfter": after.get("phase"),
                           "motionBefore": before.get("motionActive"), "motionAfter": after.get("motionActive")})
            report["progressSamples"].append(sample); save()
            current = value["current"]
            require(sign * (current - origin) >= -TOLERANCE and sign * (current - previous) >= -TOLERANCE,
                    "Zoom moved opposite the requested direction")
            require(job.running(), "Zoom request finished before a moving Stop could be observed")
            if (before.get("phase") == after.get("phase") == "moving"
                    and before.get("motionActive") is True and after.get("motionActive") is True
                    and sign * (current - previous) > TOLERANCE
                    and sign * (current - origin) >= 3 and sign * (args.target_raw - current) >= 10):
                progress_count += 1; previous = current
                if progress_count >= 2:
                    report["stopTrigger"] = sample
                    report["distinctProgressReadbacks"] = progress_count
                    hold_target = validate_stop(send_stop(), origin, args.target_raw, current)
                    report["zoomRequestOutcome"] = job.collect()
                    require(not (report["zoomRequestOutcome"].get("result") or {}).get("verified"),
                            "The original zoom request reported completion; interruption evidence conflicts")
                    break
            clock.sleep(0.05)
        else:
            raise RuntimeError("No two distinct in-flight progress reads within the bounded window; no automatic retry")

        # The endpoint exposes its internal 0.8s summary, not raw internal
        # samples. Record a separate full post-Stop window instead of inventing
        # timestamps for the service's unexported samples.
        end = clock.monotonic() + POST_STOP_WINDOW_SECONDS
        while clock.monotonic() <= end and len(report["postStopSamples"]) < 24:
            state = check_status()
            require(state.get("phase") == "ready" and state.get("motionActive") is False, "Motion resumed after Stop")
            _, sample = zoom_read(); check_status()
            require(clock.monotonic() <= end, "Post-Stop observation exceeded its time budget")
            report["postStopSamples"].append(sample); save()
            values = [item["current"] for item in report["postStopSamples"]]
            require(abs(sample["current"] - hold_target) <= TOLERANCE and max(values) - min(values) <= TOLERANCE,
                    "Post-Stop readback was not stable within the entire tolerance1 window")
            span = sample["startedMonotonic"] - report["postStopSamples"][0]["receivedMonotonic"]
            if len(values) >= 3 and span >= MINIMUM_STABLE_SECONDS:
                report["postStopStableDurationSeconds"] = span
                break
            clock.sleep(0.08)
        else:
            raise RuntimeError("The independent post-Stop stable window was incomplete")
        final = check_status(); report["final"] = status_summary(final)
        require(final.get("phase") == "ready" and final.get("motionActive") is False, "Final motion state is not idle")
        report["finalRaw"] = report["postStopSamples"][-1]["current"]
        report["residualFromOriginalRaw"] = report["finalRaw"] - origin
        report["remainingToRequestedTargetRaw"] = args.target_raw - report["finalRaw"]
        report["passed"] = True
    except Exception as error:
        report["failure"] = str(error)
    finally:
        if job is not None:
            # If progress/admission failed, close our own pending request before
            # the one cleanup Stop, so a late request cannot intentionally run
            # after cleanup. No fresh zoom or restoration command is issued.
            if not stop_attempted:
                try:
                    job.cancel()
                except Exception as error:
                    report["cleanupFailure"] = "CLI cancellation failed: " + str(error)
                try:
                    report["cleanupStop"] = send_stop()
                    require(report["cleanupStop"].get("verified") is True, "Cleanup Stop was not confirmed")
                except Exception as error:
                    report["cleanupFailure"] = report.get("cleanupFailure") or str(error)
            try:
                if job.running():
                    job.cancel()
                if "zoomRequestOutcome" not in report:
                    report["zoomRequestOutcome"] = job.collect()
            except Exception as error:
                report["cleanupFailure"] = report.get("cleanupFailure") or str(error)
        report["passed"] = bool(report["passed"] and not report.get("failure") and not report.get("cleanupFailure"))
        report["status"] = "complete" if report["passed"] else "not_confirmed"
        report["finishedAt"] = utc_now(); save()
    return report, folder / "result.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    parser.add_argument("--device", required=True)
    parser.add_argument("--session", required=True, help="Exact capture session, not BLE session")
    parser.add_argument("--registry", required=True, help="Exact gimbal.registryID from status")
    parser.add_argument("--target-raw", type=int, required=True)
    parser.add_argument("--full-advertised-range", action="store_true",
                        help="Explicitly allow the single target to span the full advertised raw range; moving-stop evidence requirements stay unchanged")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(all(value.strip() for value in (args.device, args.session, args.registry)), "Explicit binding values must be nonempty")
    report, path = run(args, CLI(args.binary))
    print(json.dumps({"passed": report["passed"], "report": str(path), "failure": report.get("failure"),
                      "cleanupFailure": report.get("cleanupFailure"), "finalRaw": report.get("finalRaw")}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
