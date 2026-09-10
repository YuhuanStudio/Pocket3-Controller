#!/usr/bin/env python3
"""Actual App ROI/video/export smoke; synthetic media only, never camera input.
Requires an idle development App and unused file workspace. Does not launch the
App, change access, download/unload models, or retry submitted model work.
"""
import argparse, hashlib, json, os, re, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/media-workspace" / str(uuid.uuid4()))
    args = parser.parse_args(); args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"passed": False, "cameraUsed": False, "syntheticMedia": True, "captures": []}
    deadline = time.monotonic() + 240; owned = False

    def check(condition, detail):
        if not condition: raise RuntimeError(detail)

    def call(*command):
        remaining = deadline - time.monotonic()
        check(remaining > 0, "Smoke deadline exceeded")
        proc = subprocess.run([str(args.binary), *command], capture_output=True, text=True, timeout=min(30, remaining))
        if proc.returncode: raise RuntimeError(proc.stderr[:6000])
        return json.loads(proc.stdout)

    def workspace(action="status", *options):
        return call("image-workspace", "--action", action, *options)

    def settled():
        until = min(deadline, time.monotonic() + 100)
        while time.monotonic() < until:
            state = workspace()
            if not state["busy"]:
                check(state["error"] is None, str(state["error"]))
                return state
            time.sleep(.05)
        raise RuntimeError("Owned workspace did not settle")

    def ready_to_run():
        until = min(deadline, time.monotonic() + 8)
        while time.monotonic() < until:
            state = workspace()
            if not state["busy"] and not state["aiBusy"]: return
            time.sleep(.1)
        raise RuntimeError("AI remained busy before submission; no model job was sent")

    def export_pair(stem, expected_frame, scope, question):
        paths = {}
        for fmt, suffix in [("json", "json"), ("markdown", "md")]:
            path = args.output / f"{stem}.{suffix}"
            workspace("export", "--format", fmt, "--output", str(path)); paths[fmt] = path
        data = json.loads(paths["json"].read_text()); markdown = paths["markdown"].read_text()
        check(data["frame"] == expected_frame and data["question"] == question, "Export changed accepted question/frame metadata")
        check(data["analysisScope"] == scope and expected_frame["id"] in markdown, "Export scope/frame missing")
        check(question in markdown and "data:image" not in markdown, "Markdown export did not preserve text-only result")
        check(not any(k in data for k in ["imageData", "videoData", "sourceURL", "path", "actions"]), "Unexpected media/path/action payload")
        return data

    try:
        before = call("status"); initial = workspace()
        check(before["phase"] == "idle" and before["capture"]["frames"] == 0 and not before["motionActive"], "Requires idle camera with zero frames")
        check(initial["source"] == "camera" and initial["frame"] is None and not initial["busy"] and not initial["aiBusy"], "Requires unused, idle file workspace")
        report.update(buildVersion=before["buildVersion"], helperSHA256=hashlib.sha256(args.binary.read_bytes()).hexdigest())
        environment = dict(os.environ); environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode-beta.app/Contents/Developer")
        fixtures = args.output / "fixtures"
        generated = subprocess.run(["xcrun", "swift", str(ROOT / "Scripts/make-media-fixture.swift"), str(fixtures)], env=environment, capture_output=True, text=True, timeout=90)
        check(generated.returncode == 0, generated.stderr[:6000]); report["fixtures"] = json.loads((fixtures / "fixtures.json").read_text())
        owned = True; workspace("import", "--image", str(fixtures / "media-shapes.png")); original = settled()
        check(original["frame"]["timestampSource"] == "local_image_import", "PNG did not use file source")
        roi = {"x": .5, "y": 0, "width": .5, "height": 1}
        workspace("region", "--region-json", json.dumps(roi)); ready_to_run()
        question = "How many blue circles are visible in this selected area? MEDIA-WORKSPACE-QUESTION"
        workspace("run", "--engine", "mlx", "--kind", "count", "--question", question); result = settled()
        report["roiResult"] = result
        frame = result["grounding"]["frame"]; provenance = frame["importedRegion"]
        check(provenance["sourceFrameID"] == original["frame"]["id"] and provenance["region"] == roi, "ROI provenance changed")
        check(frame["width"] == 320 and frame["height"] == 360 and provenance["originalWidth"] == 640 and provenance["originalHeight"] == 360, "Incorrect crop dimensions")
        check(result["responseSourceFrameID"] == original["frame"]["id"] and result["responseFrameID"] == frame["id"], "ROI result bound to wrong frame")
        count = result["grounding"]["result"]
        check(count["count"] == 1 and result["marker"] is None, "Model did not count the one blue circle in the selected area")
        check(bool(result["uncertainties"]), "Grounding result did not present its model-quality warning")
        report["roiExport"] = export_pair("roi-analysis", frame, "single_image", question)
        workspace("region", "--region-json", "null"); cleared = settled()
        check(not cleared["exportAvailable"] and not cleared["answer"] and cleared["responseFrameID"] is None, "Region change retained old result")
        workspace("import", "--image", str(fixtures / "media-two-scenes.mp4")); video = settled()
        check(video["video"] and video["frame"]["timestampSource"] == "local_video_import", "Video did not use file import")
        check(1.9 <= video["video"]["durationSeconds"] <= 2.1, "Unexpected generated clip duration")
        workspace("seek", "--seconds", "1.5"); selected = settled(); actual = selected["frame"]["presentationTime"]
        check(1 <= actual < 2 and abs(actual - 1.5) <= 1/30 + 1e-6, "Seek did not return a FRAME B timestamp")
        ready_to_run(); workspace("ocr"); ocr = settled(); report["videoOCR"] = ocr
        check("FRAMEB" in re.sub(r"\s+", "", ocr["answer"]).upper(), "Vision OCR did not read FRAME B")
        check(ocr["responseFrameID"] == selected["frame"]["id"], "OCR belongs to another selected frame")
        exported = export_pair("video-frame-analysis", selected["frame"], "single_video_frame", "")
        check(exported["sourceKind"] == "video" and exported["engine"] == "vision" and exported["action"] == "ocr", "Video export mislabeled its evidence")
        report["videoExport"] = exported
        ready_to_run()
        workspace("run", "--engine", "apple", "--kind", "ask", "--question", "Read the large visible frame label. This is one selected video frame.")
        answer = settled(); report["videoModelAnswer"] = answer
        check("FRAMEB" in re.sub(r"\s+", "", answer["answer"]).upper(), "Apple did not identify the selected FRAME B image")
        check(answer["responseFrameID"] == selected["frame"]["id"], "Model answer belongs to another video frame")
        ready_to_run()
        for language in ["en", "zh-Hant", "zh-Hans"]:
            cap = call("ui-capture", "--surface", "main", "--page", "camera", "--language", language, "--output", str(args.output / f"{language}.png"))
            check(cap["width"] == 2360 and cap["height"] == 1440 and cap["chromeIntegrated"], "Unexpected UI capture dimensions/chrome")
            check(all(cap.get(k) is False for k in ["cameraPreviewIncluded", "importedImageIncluded", "privateObservationContentIncluded"]), "UI capture exposed image or private analysis")
            report["captures"].append(cap)
        workspace("seek", "--seconds", "0.25"); workspace("seek", "--seconds", "1.25"); workspace("cancel")
        cancelled = settled(); report["rapidSeekCancelled"] = cancelled
        check(cancelled["frame"] and abs(cancelled["videoSeekTime"] - cancelled["frame"]["presentationTime"]) < 1e-6, "Displayed video time did not recover to the actual frame after cancel")
        check(not cancelled["exportAvailable"] and not cancelled["answer"], "Cancelled seek retained stale export")
        workspace("clear"); workspace("camera"); final = workspace(); after = call("status")
        check(final["source"] == "camera" and final["frame"] is None and not final["exportAvailable"], "File workspace did not clear")
        check(after["phase"] == "idle" and after["capture"]["frames"] == 0 and not after["motionActive"] and after["access"] == before["access"] and after["capture"]["sessionID"] == before["capture"]["sessionID"], "Camera state changed during file-only smoke")
        report.update(cameraStateUnchanged=True, passed=True)
    except Exception as error:
        report["error"] = str(error)
    finally:
        if owned and not report["passed"]:
            deadline = time.monotonic() + 25
            try:
                workspace("cancel"); settled(); workspace("clear"); workspace("camera")
                report["cleanup"] = "Cancelled and cleared only the owned file workspace"
            except Exception as error: report["cleanupError"] = str(error)
        (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"passed": report["passed"], "report": str(args.output / "result.json")}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
