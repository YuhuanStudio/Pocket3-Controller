#!/usr/bin/env python3
"""One explicit packaged-MCP zoom round trip, without saving photographs.

The App must already be connected and access must be set by its operator.
Normal mode requires control; --expect-denied checks one valid request in manual
mode. Never connects, pairs, changes access via setup, or retries an uncertain
SET. A failure-only same-binding global Stop can revoke control to observe.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import signal
import sys
import time
import uuid

_SPEC = importlib.util.spec_from_file_location("pocket3_mcp_hardware", Path(__file__).with_name("mcp-hardware.py"))
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)
MCPClient = _MODULE.MCPClient
TOOLS = _MODULE.TOOLS
PROJECT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def raw(value):
    return finite(value) and value == int(value) and 0 <= value <= 65535


def binding(status):
    selected, capture, gimbal = (status.get(key) or {} for key in ("selected", "capture", "gimbal"))
    return {"deviceID": selected.get("id"), "sessionID": capture.get("sessionID"),
            "registryID": gimbal.get("registryID"), "bootSessionID": gimbal.get("bootSessionID")}


def capabilities(value, baseline=None):
    require(isinstance(value, dict), "Missing zoom capabilities")
    low, high, step, current = (value.get(key) for key in ("minimum", "maximum", "step", "current"))
    require(value.get("writable") is True and all(raw(n) for n in (low, high, step, current))
            and 0 < step and low <= current <= high, "Expected finite writable integer zoom limits and a positive step")
    if baseline is not None:
        require(all(value[key] == baseline[key] for key in ("minimum", "maximum", "step", "writable")),
                "Zoom capabilities changed; do not restore")
    return value


def valid_target(target, value):
    require(raw(target) and value["minimum"] <= target <= value["maximum"]
            and (target - value["minimum"]) % value["step"] == 0, "Target is outside the advertised raw range/step")


def confirmed_zoom(value, target, baseline):
    require(all(value.get(flag) is True for flag in ("accepted", "completed", "verified")),
            "Zoom was not confirmed; no SET retry")
    require(value.get("verification") == "stable_uvc_zoom_readback_with_advertised_tolerance",
            "Zoom did not report real stable UVC readback")
    current = capabilities(value.get("capabilities"), baseline)
    tolerance = value.get("toleranceRaw")
    require(raw(tolerance) and tolerance <= min(baseline["step"], (baseline["maximum"] - baseline["minimum"]) // 100),
            "Zoom tolerance exceeds the production advertised-step/range bound")
    require(value.get("target") == target and raw(value.get("observed"))
            and value["observed"] == current["current"] and abs(value["observed"] - target) <= tolerance,
            "Zoom target/readback mismatch")
    require(raw(value.get("sampleCount")) and value["sampleCount"] >= 3
            and finite(value.get("stableDurationSeconds")) and value["stableDurationSeconds"] >= 0.2,
            "Zoom did not report the required stable readback window")
    return value


def error_codes(result):
    codes = []
    for item in result.get("content", []):
        if item.get("type") == "text":
            try:
                value = json.loads(item.get("text", ""))
            except (ValueError, TypeError):
                continue
            if isinstance(value, dict) and isinstance(value.get("code"), str):
                codes.append(value["code"])
    return codes


def evidence(result):
    """Replace image payloads with digest/size immediately; never write JPEGs."""
    records = []
    for item in result.get("content", []):
        if item.get("type") == "image":
            data = base64.b64decode(item.get("data", ""), validate=True)
            require(item.get("mimeType") == "image/jpeg" and len(data) > 1000
                    and data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"), "Invalid JPEG evidence")
            records.append({"type": "image", "mimeType": "image/jpeg", "bytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest(), "saved": False})
        else:
            records.append({"type": item.get("type", "unknown")})
    return {"isError": result.get("isError", False), "structuredContent": result.get("structuredContent"),
            "errorCodes": error_codes(result), "content": records}


def run(args, client_factory=MCPClient, clock=time):
    out = Path(args.output).resolve() / str(uuid.uuid4())
    out.mkdir(parents=True, exist_ok=False)
    report = {"runID": out.name, "startedAt": datetime.now(timezone.utc).isoformat(),
              "passed": False, "status": "running", "simulation": False, "zoomExplicitlyEnabled": args.zoom,
              "mode": "manual-denial" if args.expect_denied else "control-round-trip",
              "requestedTargetRaw": args.target_raw, "imageFilesSaved": False,
              "bindingGuarantee": "client checks device/session/USB attachment before mutations; only zoom RPC binds expectedSessionID atomically",
              "accessPolicy": "operator-managed; no setup calls; failure-only global Stop may revoke control to observe",
              "stopValidatedRequired": False, "calls": [], "actions": [], "restoreAttempted": False,
              "restored": False, "limitations": ["Raw zoom is not a calibrated x multiplier",
                  "Do not operate or reconnect the App concurrently; matching session does not prove exclusive operator ownership",
                  "No uncertain SET is retried; global Stop has no atomic expected-session parameter"]}
    path = out / "result.json"
    expected = {"deviceID": args.device, "sessionID": args.session, "registryID": args.registry}
    baseline, confirmed_target, write_attempted = None, False, False
    client = None

    def persist(strict=True):
        try:
            temporary = out / "result.json.tmp"
            temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
            temporary.replace(path)
        except (OSError, TypeError, ValueError) as error:
            # Fail the ordinary workflow, but never make disk availability a
            # prerequisite for an independent binding read/Stop or child close.
            errors = report.setdefault("persistenceErrors", [])
            if len(errors) < 8:
                errors.append(f"{type(error).__name__}: {error}")
            report.update(passed=False, status="failed")
            if len(errors) == 1:
                print("MCP zoom evidence persistence failed; safety cleanup remains enabled", file=sys.stderr)
            if strict:
                raise

    def structured(result):
        require(result.get("isError") is not True, "MCP error: " + ", ".join(error_codes(result)))
        value = result.get("structuredContent")
        require(isinstance(value, dict), "Missing structured MCP result")
        return value

    def call(name, arguments=None, label=None, cleanup=False):
        nonlocal write_attempted
        entry = {"name": name, "arguments": arguments or {}, "label": label or name}
        report["calls"].append(entry); persist(strict=not cleanup)
        try:
            if name == "camera_set_zoom":
                write_attempted = True
            result, sent, received = client.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=12)
            entry.update(sentUptime=sent, receivedUptime=received, elapsedSeconds=received-sent, result=evidence(result))
            persist(strict=not cleanup)
            return result, sent, received
        except BaseException as error:
            entry["failure"] = f"{type(error).__name__}: {error}"
            persist(strict=False)
            raise

    def status(label, ready=True, access=None, fresh=True, cleanup=False):
        value = structured(call("camera_status", label=label, cleanup=cleanup)[0])
        actual = binding(value)
        require(all(actual.get(key) == expected[key] for key in expected), "Device/session/USB attachment changed; no cleanup mutation")
        require(isinstance(actual.get("bootSessionID"), str) and bool(actual["bootSessionID"]), "Missing USB boot identity")
        if "bootSessionID" not in expected:
            expected["bootSessionID"] = actual["bootSessionID"]
            report["binding"] = dict(expected)
        if ready:
            require(value.get("phase") == "ready" and value.get("motionActive") is False, "Camera is not idle/ready")
        if access is not None:
            require(value.get("access") == access, "Access changed; the harness never enables it")
        if fresh:
            capture = value.get("capture") or {}
            frame = capture.get("frame") or {}
            require(finite(capture.get("age")) and 0 <= capture["age"] <= 1
                    and frame.get("sessionID") == expected["sessionID"] and frame.get("deviceID") == expected["deviceID"],
                    "No fresh same-session camera frame")
        require(value.get("nativeControl") is None, "Unexpected native controller ownership")
        return value

    def zoom_status(label):
        value = structured(call("camera_zoom_status", {"expectedSessionID": expected["sessionID"]}, label)[0])
        return capabilities(value, baseline)

    def capture(label, previous=None, after=None):
        # MCP has no after argument. One bounded wait before the explicit read
        # lets the next callback arrive; the returned host timestamp must prove
        # freshness anyway. Never invent a frame or resend the zoom on failure.
        if after is not None:
            clock.sleep(0.15)
        result, _, received = call("capture_frame", {"maxDimension": 1280}, label)
        value = structured(result)
        frame = value.get("frame", value)
        require(frame.get("sessionID") == expected["sessionID"] and frame.get("deviceID") == expected["deviceID"],
                "Frame belongs to another connection")
        require(frame.get("timestampSource") == "host_callback_and_avfoundation_pts"
                and isinstance(frame.get("id"), str) and bool(frame["id"])
                and finite(frame.get("receivedUptime")) and finite(frame.get("presentationTime")), "Missing live frame metadata")
        require(0 <= received - frame["receivedUptime"] <= 1, "Stale frame or host clock mismatch")
        if previous is not None:
            require(frame["id"] != previous["id"] and frame["receivedUptime"] > previous["receivedUptime"]
                    and frame["presentationTime"] > previous["presentationTime"], "Post-action frame did not advance")
        if after is not None:
            require(frame["receivedUptime"] > after, "Post-action frame predates the confirmed zoom response")
        require(all(raw(frame.get(axis)) and 0 < frame[axis] <= 1280 for axis in ("width", "height")), "Invalid delivered JPEG dimensions")
        require(sum(item.get("type") == "image" for item in result.get("content", [])) == 1, "Expected one actual JPEG")
        report.setdefault("frames", []).append({"label": label, "metadata": frame})
        persist()
        return frame

    def restore(label):
        require(confirmed_target and not report["restoreAttempted"], "No known un-restored target; restoration is not permitted")
        current = zoom_status(label + "-zoom-status")
        require(current["current"] == args.target_raw, "Raw target changed or is not exact; no restoration SET")
        status(label + "-binding", access="control")
        report["restoreAttempted"] = True; persist()
        result, _, received = call("camera_set_zoom", {"rawValue": baseline["current"], "expectedSessionID": expected["sessionID"]}, label)
        action = structured(result)
        report["actions"].append({"label": label, "zoom": action}); persist()
        confirmed_zoom(action, baseline["current"], baseline)
        require(action["observed"] == baseline["current"], "Restoration only reached tolerance, not exact original raw value")
        status(label + "-after-binding", access="control")
        final = zoom_status(label + "-after-zoom-status")
        report["finalRaw"] = final["current"]
        report["finalResidualRaw"] = final["current"] - baseline["current"]
        require(final["current"] == baseline["current"], "Original raw value was not restored exactly")
        report["restored"] = True; persist()
        return received

    persist()
    with (out / "stderr.log").open("w") as stderr:
        try:
            require(args.zoom is True, "--zoom is required")
            require(all(isinstance(value, str) and value for value in expected.values()), "Explicit device/session/registry binding is required")
            client = client_factory(str(Path(args.binary).resolve()), stderr)
            initialized, _, _ = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "Pocket3MCPZoomAcceptance", "version": "1"}})
            require(initialized.get("protocolVersion") == "2025-11-25", "Unexpected MCP protocol version")
            client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            listing, _, _ = client.request("tools/list", {})
            tools = listing.get("tools", [])
            require(len(tools) == 6 and {item["name"] for item in tools} == TOOLS, "Unexpected MCP tool set")
            schema = next(item["inputSchema"] for item in tools if item["name"] == "camera_set_zoom")
            require(set(schema.get("required", [])) == {"rawValue", "expectedSessionID"}
                    and schema.get("additionalProperties") is False
                    and schema.get("properties", {}).get("rawValue", {}).get("type") == "integer", "Unexpected zoom schema")
            report["protocolVersion"] = initialized["protocolVersion"]
            initial = status("initial-status", access="manual" if args.expect_denied else "control")
            report["appVersion"], report["buildVersion"] = initial.get("appVersion"), initial.get("buildVersion")
            report["initialStopValidated"] = initial.get("stopValidated")
            before = None if args.expect_denied else capture("before-zoom")
            baseline = zoom_status("baseline-zoom-status")
            report["baseline"] = dict(baseline)
            valid_target(args.target_raw, baseline)
            valid_target(baseline["current"], baseline)
            require(args.target_raw != baseline["current"], "A no-op target cannot establish zoom or a meaningful denial")
            if args.expected_raw is not None:
                require(baseline["current"] == args.expected_raw, "Fresh baseline differs from --expected-raw")
            current = zoom_status("pre-set-zoom-status")
            require(current["current"] == baseline["current"], "Baseline changed before SET")
            status("pre-set-binding", access="manual" if args.expect_denied else "control")
            result, _, received = call("camera_set_zoom", {"rawValue": args.target_raw, "expectedSessionID": expected["sessionID"]}, "target-zoom")
            if args.expect_denied:
                require(result.get("isError") is True and error_codes(result) == ["access_denied"], "Manual-mode zoom was not denied by the expected access gate")
                require(not any(item.get("type") == "image" for item in result.get("content", [])), "Denied zoom returned an unexpected image")
                status("after-denied-binding", access="manual")
                final = zoom_status("after-denied-zoom-status")
                require(final["current"] == baseline["current"], "Raw value changed during denied request")
                report.update(deniedInManual=True, finalRaw=final["current"], finalResidualRaw=0)
            else:
                action = structured(result)
                report["actions"].append({"label": "target-zoom", "zoom": action}); persist()
                confirmed_zoom(action, args.target_raw, baseline)
                require(action["observed"] == args.target_raw, "Confirmed target is only within tolerance; no automatic restore from non-exact target")
                confirmed_target = True
                status("post-target-binding", access="control")
                after_frame = capture("after-zoom", previous=before, after=received)
                restore_received = restore("restore-original")
                capture("after-restore", previous=after_frame, after=restore_received)
                status("final-status", access="control")
                report["finalRaw"] = zoom_status("final-zoom-status")["current"]
                require(report["finalRaw"] == baseline["current"], "Final raw baseline changed")
            report.update(passed=True, status="completed")
        except BaseException as error:
            report.update(passed=False, status="interrupted" if isinstance(error, KeyboardInterrupt) else "failed",
                          failure=f"{type(error).__name__}: {error}")
            if client and confirmed_target and not report["restoreAttempted"] and not report.get("persistenceErrors"):
                try:
                    restore("failure-restore-original")
                except BaseException as cleanup_error:
                    report["restoreFailure"] = f"{type(cleanup_error).__name__}: {cleanup_error}"
            if client and write_attempted and not report["restored"]:
                try:
                    # No fallback CLI or blind global Stop after a reconnect.
                    status("failure-stop-binding", ready=False, access="manual" if args.expect_denied else "control", fresh=False, cleanup=True)
                    stop = structured(call("stop_gimbal", label="failure-stop", cleanup=True)[0])
                    report["cleanupStop"] = stop
                    report["cleanupStopConfirmed"] = all(stop.get(flag) is True for flag in ("accepted", "completed", "verified"))
                    status("after-failure-stop-binding", ready=False, fresh=False, cleanup=True)
                except BaseException as stop_error:
                    report["cleanupStopConfirmed"] = False
                    report["cleanupStopFailure"] = f"{type(stop_error).__name__}: {stop_error}"
                report["cleanupUncertain"] = not report.get("cleanupStopConfirmed", False)
            if write_attempted and not report["restored"] and not report.get("deniedInManual"):
                report["restorationIncomplete"] = True
        finally:
            try:
                if client:
                    client.close()
            except BaseException as close_error:
                report.update(passed=False, status="failed", clientCloseFailure=f"{type(close_error).__name__}: {close_error}")
            finally:
                report["finishedAt"] = datetime.now(timezone.utc).isoformat()
                persist(strict=False)
    return report, path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(PROJECT / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3"))
    parser.add_argument("--output", default=str(PROJECT / "artifacts/mcp-zoom-hardware"), help="Parent of a unique per-run report directory")
    parser.add_argument("--zoom", action="store_true", required=True, help="Permit one target and one conditional restoration; failure Stop may revoke access")
    parser.add_argument("--target-raw", type=int, required=True, help="Integer device raw value, not an x multiplier")
    parser.add_argument("--device", required=True, help="Exact selected.id from current camera_status")
    parser.add_argument("--session", required=True, help="Exact capture.sessionID from current camera_status")
    parser.add_argument("--registry", required=True, help="Exact gimbal.registryID from current camera_status")
    parser.add_argument("--expected-raw", type=int, help="Optional additional guard against an unexpected initial raw value")
    parser.add_argument("--expect-denied", action="store_true", help="Separate manual-access denial run; operator sets manual beforehand")
    args = parser.parse_args()
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    report, path = run(args)
    print(json.dumps({key: report.get(key) for key in ("runID", "passed", "status", "mode", "restored", "deniedInManual", "finalRaw", "finalResidualRaw", "cleanupStopConfirmed", "failure")}
                     | {"report": str(path)}, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
