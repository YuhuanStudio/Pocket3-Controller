#!/usr/bin/env python3
"""Exercise the actual App image workspace using synthetic files, with no camera.

Requires a development App already running with --hardware-validation. This
does not start/stop capture, modify access, download models or join a network.
Model correctness is evaluated separately by evaluate-ai-grounding.py.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/image-workspace" / str(uuid.uuid4()))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"passed": False, "cameraUsed": False, "capturesIncludeImages": False, "cases": []}

    def call(*command):
        deadline = time.monotonic() + 5
        while True:
            result = subprocess.run([str(args.binary), *command], capture_output=True, text=True, timeout=125)
            if result.returncode == 0:
                return json.loads(result.stdout)
            # The UI's shared model status refreshes asynchronously after its
            # own workspace task finishes. Only a pre-submission busy rejection
            # is retried; never retry a submitted model job, timeout or failure.
            try:
                code = json.loads(result.stderr).get("code")
            except ValueError:
                code = None
            if command[:3] == ("image-workspace", "--action", "run") and code == "ai_busy" and time.monotonic() < deadline:
                report["readinessWaits"] = report.get("readinessWaits", 0) + 1
                time.sleep(0.1)
                continue
            raise RuntimeError(result.stderr)

    def workspace(action="status", *options):
        return call("image-workspace", "--action", action, *options)

    def settled():
        deadline = time.monotonic() + 110
        while time.monotonic() < deadline:
            state = workspace()
            if not state["busy"]:
                assert state["error"] is None, state
                return state
            time.sleep(0.05)
        raise RuntimeError("Workspace did not settle; inspect current AI state before further tests")

    def imported(path):
        workspace("import", "--image", str(path))
        state = settled()
        assert state["source"] == "image" and state["ready"] and not state["cameraActionReady"], state
        assert state["frame"]["timestampSource"] == "local_image_import", state
        return state

    before = call("status")
    assert before["phase"] == "idle" and not before["motionActive"] and before["capture"]["frames"] == 0, "Requires inactive capture"
    initial = workspace()
    assert initial["source"] == "camera" and initial["frame"] is None and not initial["busy"], "Requires an unused image workspace"
    report["buildVersion"] = before["buildVersion"]
    report["helperSHA256"] = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    report["initialCameraAccess"] = before["access"]
    fixtures = ROOT / "artifacts/evaluation/fixtures"
    private_image = args.output / "PRIVATE-WORKSPACE-FILENAME.png"
    shutil.copyfile(fixtures / "colours.png", private_image)
    try:
        loaded = imported(private_image)
        for engine, kind, question in [
            ("apple", "ask", "Describe the visible shapes and colours. PRIVATE-WORKSPACE-QUESTION"),
            ("mlx", "count", "How many coloured circles are visible?"),
            ("mlx", "locate", "Locate the centre of the blue circle. PRIVATE-WORKSPACE-QUESTION"),
        ]:
            workspace("run", "--engine", engine, "--kind", kind, "--question", question)
            result = settled()
            assert result["answer"] and result["responseFrameID"] == loaded["frame"]["id"], result
            if kind == "locate":
                assert result["marker"] and all(0 <= n <= 1 for n in result["marker"].values()), result
            report["cases"].append({"engine": engine, "kind": kind, "result": result})
        report["captures"] = []
        for language in ["en", "zh-Hant", "zh-Hans"]:
            capture = call("ui-capture", "--surface", "main", "--page", "camera", "--language", language,
                           "--output", str((args.output / (language + ".png")).resolve()))
            assert capture["cameraPreviewIncluded"] is False and capture["chromeIntegrated"], capture
            assert capture["width"] == 2360 and capture["height"] == 1440, capture
            report["captures"].append(capture)
        # Replacement clears the old result and binds OCR to the new file.
        next_image = imported(fixtures / "text.png")
        assert next_image["frame"]["id"] != loaded["frame"]["id"] and not next_image["answer"] and next_image["marker"] is None
        workspace("ocr")
        ocr = settled()
        assert ocr["answer"] and ocr["responseFrameID"] == next_image["frame"]["id"], ocr
        report["cases"].append({"kind": "ocr", "result": ocr})
        # Cancel the same UI-owned operation immediately; deterministic blocked
        # responder tests separately cover cancellation after generation begins.
        workspace("run", "--engine", "mlx", "--kind", "ask", "--question", "Describe every visible detail.")
        workspace("cancel")
        cancelled = settled()
        assert not cancelled["answer"] and cancelled["marker"] is None and cancelled["responseFrameID"] is None
        report["cancelled"] = cancelled
        workspace("clear")
        workspace("camera")
        cleared = workspace()
        assert cleared["source"] == "camera" and cleared["frame"] is None and not cleared["answer"]
        after = call("status")
        assert after["phase"] == "idle" and after["capture"]["frames"] == 0 and after["access"] == before["access"]
        assert after["capture"]["sessionID"] == before["capture"]["sessionID"] and not after["motionActive"]
        report["cameraStateUnchanged"] = True
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if not report["passed"]:
            try:
                workspace("cancel")
                settled()
                workspace("clear")
                workspace("camera")
                report["cleanup"] = "Cancelled and cleared only the image workspace"
            except Exception as error:
                report["cleanupError"] = str(error)
        private_image.unlink(missing_ok=True)
        (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"passed": report["passed"], "report": str(args.output / "result.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
