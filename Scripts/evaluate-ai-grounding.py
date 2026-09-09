#!/usr/bin/env python3
"""Score public COCO images through the installed App's image-only AI endpoint.

Does not launch or reconfigure the App, download models, connect cameras, or
invoke control tools. Dataset preparation is separate. A timeout aborts the run
because a killed CLI alone does not establish that its App request has stopped.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def image_location(entry: dict, manifest_directory: Path) -> tuple[Path, str]:
    """Resolve only the manifest's bounded COCO val2017 image cache."""
    filename = entry.get("fileName", "")
    if not re.fullmatch(r"[0-9]{12}\.jpg", filename):
        raise ValueError("Expected a COCO val2017 image filename")
    if entry.get("localPath") != "images/" + filename:
        raise ValueError("Image localPath must name the dedicated images cache")
    if type(entry.get("bytes")) is not int or not 0 < entry["bytes"] <= 8_000_000:
        raise ValueError("Image size must be a positive integer at most 8 MB")
    if not isinstance(entry.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
        raise ValueError("Image needs a fixed SHA-256")
    expected_url = "https://s3.amazonaws.com/images.cocodataset.org/val2017/" + filename
    if entry.get("downloadURL") != expected_url:
        raise ValueError("Downloads are restricted to the recorded official COCO S3 image object")
    directory = manifest_directory.resolve()
    image_cache = directory / "images"
    image = image_cache / filename
    if image_cache.is_symlink() or image.is_symlink() or image_cache.resolve() != directory / "images":
        raise ValueError("Dataset image cache must not redirect through a symbolic link")
    return image, expected_url


def valid_image_file(path: Path, entry: dict) -> bool:
    return path.is_file() and path.stat().st_size == entry["bytes"] and sha256(path) == entry["sha256"]


def prepare_data(entries: list[dict], manifest_directory: Path, *, opener=urllib.request.urlopen) -> dict:
    """Explicit image-only preparation; no App, model, or camera calls."""
    prepared = []
    for entry in entries:
        path, url = image_location(entry, manifest_directory)
        if valid_image_file(path, entry):
            prepared.append({"id": entry["id"], "downloaded": False, "sha256": entry["sha256"]})
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        staged = None
        started = time.monotonic()
        try:
            with tempfile.NamedTemporaryFile(prefix=".coco-", suffix=".partial", dir=path.parent, delete=False) as output:
                staged = Path(output.name)
                with opener(url, timeout=30) as response:
                    # Do not silently follow a fixture URL to unrelated content.
                    if response.geturl() != url:
                        raise ValueError("COCO image download unexpectedly redirected")
                    total = 0
                    while chunk := response.read(min(65536, entry["bytes"] - total + 1)):
                        total += len(chunk)
                        if total > entry["bytes"] or time.monotonic() - started > 60:
                            raise ValueError("COCO image exceeded its byte or duration bound")
                        output.write(chunk)
            if not valid_image_file(staged, entry):
                raise ValueError(f"Downloaded image size or SHA-256 differs: {entry['id']}")
            staged.replace(path)
            prepared.append({"id": entry["id"], "downloaded": True, "sha256": entry["sha256"]})
        finally:
            if staged is not None:
                staged.unlink(missing_ok=True)
    return {"prepared": True, "images": len(prepared),
            "downloaded": sum(item["downloaded"] for item in prepared),
            "reused": sum(not item["downloaded"] for item in prepared),
            "cameraUsed": False, "modelExecuted": False, "appContacted": False, "files": prepared}


def finite_number(value) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def reject_constant(value):
    raise ValueError(f"Non-JSON numeric constant: {value}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def score_answer(kind: str, answer: str, expected: dict) -> dict:
    result = {"jsonParsed": False, "schemaValid": False,
              "factuallyCorrect": False, "taskPassed": False}
    try:
        value = json.loads(answer, parse_constant=reject_constant, object_pairs_hook=unique_object)
    except (ValueError, TypeError) as error:
        result["parseError"] = str(error)
        return result
    result["jsonParsed"] = True
    result["parsedAnswer"] = value
    if not isinstance(value, dict):
        result["schemaError"] = "Expected one JSON object"
        return result
    if kind == "count":
        count_valid = type(value.get("count")) is int and value["count"] >= 0
        valid = (set(value) == {"count", "uncertain"}
                 and count_valid
                 and type(value["uncertain"]) is bool)
        if count_valid:
            result["factuallyCorrect"] = value["count"] == expected["count"]
            result["countAbsoluteError"] = abs(value["count"] - expected["count"])
            result["taskPassed"] = valid and result["factuallyCorrect"] and not value["uncertain"]
    elif kind == "point":
        point = value.get("point")
        point_valid = (point is None or (isinstance(point, list) and len(point) == 2
                       and all(finite_number(v) and 0 <= v <= 1 for v in point)))
        valid = (set(value) == {"point", "uncertain"} and point_valid
                 and type(value["uncertain"]) is bool)
        if point_valid and point is not None:
            x, y = point
            left, top, width, height = expected["bboxNormalizedXYWH"]
            inside = left <= x <= left + width and top <= y <= top + height
            result["factuallyCorrect"] = inside
            result["pointInsideAnnotatedBBox"] = inside
            result["centerErrorNormalizedXY"] = math.hypot(
                x - left - width / 2, y - top - height / 2)
            result["taskPassed"] = valid and inside and not value["uncertain"]
        elif valid:
            result["abstained"] = True
    elif kind == "absent":
        point = value.get("point")
        point_valid = (point is None or (isinstance(point, list) and len(point) == 2
                       and all(finite_number(v) and 0 <= v <= 1 for v in point)))
        valid = (set(value) == {"found", "point"} and type(value["found"]) is bool
                 and point_valid and ((value["found"] and point is not None)
                                      or (not value["found"] and point is None)))
        if type(value.get("found")) is bool and point_valid:
            result["factuallyCorrect"] = value["found"] is False and point is None
            result["taskPassed"] = valid and result["factuallyCorrect"]
            result["abstained"] = point is None
    else:
        raise ValueError(f"Unknown task kind: {kind}")
    result["schemaValid"] = valid
    if not valid:
        result["schemaError"] = f"Invalid {kind} keys, types, ranges, or nullability"
    return result


def typed_question(task: dict) -> str:
    """Remove only the legacy nested-JSON wrapper, never consult the gold label."""
    wrapper = "請讓你的 answer 欄位僅包含下列 JSON 格式，不要 Markdown 或其他文字。"
    question = task["question"]
    if question.count(wrapper) != 1:
        raise ValueError(f"Unexpected legacy prompt wrapper: {task['id']}")
    prefix, body = question.split(wrapper)
    if task["kind"] == "count":
        if "格式：" not in body:
            raise ValueError("Count question has no known legacy format boundary")
        return prefix + body.split("格式：", 1)[0] + "看不清是否還有其他目標時，請標示不確定。"
    if task["kind"] == "point":
        if "格式：" not in body:
            raise ValueError("Point question has no known legacy format boundary")
        return prefix + body.split("格式：", 1)[0] + "找不到或無法確定時，不要猜測座標，請標示不確定。"
    if task["kind"] == "absent":
        if "如果沒有可確認的目標" not in body:
            raise ValueError("Absent question has no known legacy format boundary")
        return (prefix + body.split("如果沒有可確認的目標", 1)[0]
                + "如果沒有可確認的目標，必須拒絕猜測位置。若確實看見，才回傳位置；"
                  "座標是原始照片左上為(0,0)、右下為(1,1)，x向右、y向下。")
    raise ValueError(f"Unknown task kind: {task['kind']}")


def score_typed_result(kind: str, payload, expected: dict) -> dict:
    """Check the native typed contract and reuse unchanged spatial/count truth.

    A point object may become an array representation. Values are never scaled,
    clamped, rounded, inferred from the model name, or repaired from ground truth.
    """
    normalized = dict(payload) if isinstance(payload, dict) else payload
    point_shape_valid = True
    if isinstance(payload, dict) and kind in ("point", "absent"):
        point = payload.get("point")
        point_shape_valid = point is None or (
            isinstance(point, dict) and set(point) == {"x", "y"}
            and all(finite_number(point[key]) and 0 <= point[key] <= 1 for key in ("x", "y")))
        if isinstance(point, dict) and set(point) == {"x", "y"}:
            normalized["point"] = [point["x"], point["y"]]
    score = score_answer(kind, json.dumps(normalized), expected)
    score["typedPayload"] = payload
    score["coordinateConversion"] = "object_to_array_only_no_rescale_clamp_or_rounding"
    if not isinstance(payload, dict):
        return score
    if kind == "count":
        valid = (set(payload) == {"count", "uncertain"} and type(payload["count"]) is int
                 and payload["count"] >= 0 and type(payload["uncertain"]) is bool)
    elif kind == "point":
        valid = (set(payload) == {"point", "uncertain"} and point_shape_valid
                 and type(payload["uncertain"]) is bool
                 and ((payload["uncertain"] and payload["point"] is None)
                      or (not payload["uncertain"] and payload["point"] is not None)))
    else:
        # Native presence schema allows found=true with an unknown point.
        # That is schema-valid but still a factual failure for this absent task.
        valid = (set(payload) == {"found", "point"} and point_shape_valid
                 and type(payload["found"]) is bool
                 and (payload["found"] or payload["point"] is None))
    score["schemaValid"] = valid
    score["taskPassed"] = (valid and score["factuallyCorrect"]
                           and (kind == "absent" or payload["uncertain"] is False))
    if valid:
        score.pop("schemaError", None)
    else:
        score["schemaError"] = f"Invalid native typed {kind} payload; no repairs applied"
    return score


def typed_envelope_valid(response: dict, kind: str) -> bool:
    return (type(response.get("schemaVersion")) is int and response["schemaVersion"] == 1
            and response.get("kind") == kind and "result" in response
            and response.get("origin") == "local_image_import"
            and response.get("coordinateSpace") == "normalized_top_left_0_1")


def percentile(values: list[float], fraction: float):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def summarize(records: list[dict]) -> dict:
    groups = {}
    for record in records:
        groups.setdefault(record["engine"], []).append(record)
    return {engine: {
        "completedCases": len(items),
        "transportSucceeded": sum(item["transportSucceeded"] for item in items),
        "hostRejectedGroundingOutput": sum(item.get("hostRejectedGroundingOutput", False) for item in items),
        "jsonParsed": sum(item["score"]["jsonParsed"] for item in items),
        "schemaValid": sum(item["score"]["schemaValid"] for item in items),
        "factuallyCorrect": sum(item["score"]["factuallyCorrect"] for item in items),
        "taskPassed": sum(item["score"]["taskPassed"] for item in items),
        "wallSecondsP50": statistics.median(item["wallSeconds"] for item in items),
        "wallSecondsP95": percentile([item["wallSeconds"] for item in items], .95),
        "byKind": {kind: {
            "cases": sum(item["kind"] == kind for item in items),
            "passed": sum(item["kind"] == kind and item["score"]["taskPassed"] for item in items)
        } for kind in ("count", "point", "absent")}
    } for engine, items in groups.items()}


def write_json(path: Path, value) -> None:
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def self_test() -> None:
    box = {"bboxNormalizedXYWH": [.1, .2, .3, .4]}
    assert score_answer("point", '{"point":[0.25,0.4],"uncertain":false}', box)["taskPassed"]
    assert not score_answer("point", '{"point":[0.9,0.9],"uncertain":false}', box)["taskPassed"]
    assert not score_answer("point", '{"point":[true,0.4],"uncertain":false}', box)["schemaValid"]
    assert not score_answer("point", '{"point":[NaN,0.4],"uncertain":false}', box)["schemaValid"]
    assert score_answer("point", '{"point":null,"uncertain":true}', box)["schemaValid"]
    assert not score_answer("point", '{"point":null,"uncertain":true}', box)["taskPassed"]
    assert score_answer("count", '{"count":2,"uncertain":false}', {"count": 2})["taskPassed"]
    schema_failure = score_answer("count", '{"count":2}', {"count": 2})
    assert schema_failure["factuallyCorrect"] and not schema_failure["schemaValid"] and not schema_failure["taskPassed"]
    schema_failure = score_answer("point", '{"point":[0.25,0.4]}', box)
    assert schema_failure["factuallyCorrect"] and not schema_failure["schemaValid"] and not schema_failure["taskPassed"]
    assert not score_answer("count", '{"count":true,"uncertain":false}', {"count": 1})["schemaValid"]
    assert not score_answer("count", '{"count":1,"count":2,"uncertain":false}', {"count": 2})["jsonParsed"]
    assert not score_answer("count", '{"count":2,"uncertain":true}', {"count": 2})["taskPassed"]
    assert not score_answer("count", '```json\n{"count":2}\n```', {"count": 2})["jsonParsed"]
    assert score_answer("absent", '{"found":false,"point":null}', {})["taskPassed"]
    assert not score_answer("absent", '{"found":false,"point":[0.5,0.5]}', {})["schemaValid"]
    assert not score_answer("absent", '{"found":true,"point":null}', {})["schemaValid"]
    assert not score_answer("absent", '{"found":true,"point":[0.5,0.5]}', {})["taskPassed"]
    typed = score_typed_result("point", {"point": {"x": .25, "y": .4}, "uncertain": False}, box)
    assert typed["schemaValid"] and typed["taskPassed"]
    assert typed["parsedAnswer"]["point"] == [.25, .4]
    for point in ({"x": 250, "y": 400}, {"x": True, "y": .4}, {"x": .25, "y": .4, "z": 0}, [.25, .4]):
        assert not score_typed_result("point", {"point": point, "uncertain": False}, box)["schemaValid"]
    assert not score_typed_result("point", {"point": {"x": .25, "y": .4}, "uncertain": True}, box)["schemaValid"]
    assert score_typed_result("point", {"point": None, "uncertain": True}, box)["schemaValid"]
    assert not score_typed_result("point", {"point": None, "uncertain": True}, box)["taskPassed"]
    assert score_typed_result("count", {"count": 2, "uncertain": False}, {"count": 2})["taskPassed"]
    assert not score_typed_result("count", {"count": 4, "uncertain": False}, {"count": 2})["factuallyCorrect"]
    assert score_typed_result("absent", {"found": False, "point": None}, {})["taskPassed"]
    assert score_typed_result("absent", {"found": True, "point": None}, {})["schemaValid"]
    assert not score_typed_result("absent", {"found": True, "point": None}, {})["factuallyCorrect"]
    sample = {"id": "no-gold", "kind": "count", "question": "單張照片。請讓你的 answer 欄位僅包含下列 JSON 格式，不要 Markdown 或其他文字。圖片中可見幾個杯子？格式：{}", "expected": {"count": 987}}
    assert "987" not in typed_question(sample) and "幾個杯子" in typed_question(sample)
    envelope = {"schemaVersion": 1, "kind": "point", "result": {}, "origin": "local_image_import", "coordinateSpace": "normalized_top_left_0_1"}
    assert typed_envelope_valid(envelope, "point")
    assert not typed_envelope_valid({**envelope, "coordinateSpace": "pixels"}, "point")
    with tempfile.TemporaryDirectory(prefix="p3-grounding-scorer-") as directory:
        cache_root = Path(directory)
        content = b"bounded existing test fixture"
        entry = {"id": "fixture", "fileName": "000000000001.jpg", "localPath": "images/000000000001.jpg",
                 "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest(),
                 "downloadURL": "https://s3.amazonaws.com/images.cocodataset.org/val2017/000000000001.jpg"}
        image, _ = image_location(entry, cache_root)
        image.parent.mkdir()
        image.write_bytes(content)
        def no_network(*unused_args, **unused_keywords):
            raise AssertionError("Existing image preparation must not access the network")
        prepared = prepare_data([entry], cache_root, opener=no_network)
        assert prepared["reused"] == 1 and prepared["downloaded"] == 0 and not prepared["appContacted"]
        for invalid in ({**entry, "localPath": "../outside.jpg"}, {**entry, "downloadURL": "https://example.com/image.jpg"}):
            try:
                image_location(invalid, cache_root)
            except ValueError:
                pass
            else:
                raise AssertionError("Unsafe image metadata was accepted")
    print(json.dumps({"selfTestPassed": True, "cameraUsed": False, "modelExecuted": False}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "Evaluation/Grounding/manifest.json")
    parser.add_argument("--binary", type=Path, default=Path("/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3"))
    parser.add_argument("--engines", nargs="+", choices=("apple", "mlx"), default=["apple", "mlx"])
    parser.add_argument("--endpoint", choices=("legacy", "typed"), default="legacy",
                        help="legacy=evaluate-image JSON in answer string; typed=evaluate-grounding native result")
    parser.add_argument("--case", action="append", default=[], help="Select exact task IDs; repeatable")
    parser.add_argument("--limit", type=int, help="First N selected tasks per engine")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=140, help="Per-request CLI timeout seconds")
    parser.add_argument("--max-seconds", type=float, default=1800, help="Whole-run deadline seconds")
    parser.add_argument("--output", type=Path, help="New output directory; existing paths are rejected")
    parser.add_argument("--validate-only", action="store_true", help="Check manifest, image hashes and tasks without contacting App")
    parser.add_argument("--prepare-data", action="store_true", help="Fetch only missing COCO images with fixed size/SHA checks, then exit; no App or model")
    parser.add_argument("--self-test", action="store_true", help="Test scorers only, no App or dataset")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not 1 <= args.repeats <= 10 or not 10 <= args.timeout <= 180 or not 10 <= args.max_seconds <= 7200:
        parser.error("repeats must be 1–10; timeout 10–180; max-seconds 10–7200")
    if args.limit is not None and args.limit < 1:
        parser.error("limit must be positive")
    manifest = json.loads(args.manifest.read_text())
    images = {entry["id"]: entry for entry in manifest["images"]}
    tasks = manifest["tasks"]
    if len(images) != len(manifest["images"]) or len({task["id"] for task in tasks}) != len(tasks):
        raise ValueError("Duplicate image or task IDs")
    if not tasks:
        raise ValueError("Dataset has no tasks")
    if args.case:
        unknown = set(args.case) - {task["id"] for task in tasks}
        if unknown:
            parser.error(f"Unknown task IDs: {sorted(unknown)}")
        tasks = [task for task in tasks if task["id"] in args.case]
    if args.limit:
        tasks = tasks[:args.limit]
    if args.prepare_data:
        selected_ids = {task["imageID"] for task in tasks}
        entries = [entry for entry in manifest["images"] if entry["id"] in selected_ids]
        print(json.dumps(prepare_data(entries, args.manifest.parent), ensure_ascii=False))
        return 0
    image_paths = {}
    for task in tasks:
        entry = images[task["imageID"]]
        image, _ = image_location(entry, args.manifest.parent)
        if not valid_image_file(image, entry):
            raise ValueError(f"Missing or changed fixture: {image}. Run --prepare-data explicitly to populate the cache.")
        if not task.get("question") or task["kind"] not in ("count", "point", "absent"):
            raise ValueError(f"Invalid task: {task['id']}")
        image_paths[task["imageID"]] = image
        if args.endpoint == "typed":
            typed_question(task)  # Validate prompt boundaries before contacting App.
    if args.validate_only:
        print(json.dumps({"manifestValid": True, "images": len(image_paths), "tasks": len(tasks),
                          "endpoint": args.endpoint, "cameraUsed": False, "modelExecuted": False}))
        return 0
    if not args.binary.is_file():
        raise ValueError("Installed CLI is missing; this runner does not build or launch the App")
    output = args.output or ROOT / "artifacts/ai-grounding" / (time.strftime("%Y%m%d-%H%M%S") + "-" + str(uuid.uuid4())[:8])
    output.mkdir(parents=True, exist_ok=False)
    endpoint = "evaluate-grounding" if args.endpoint == "typed" else "evaluate-image"
    report = {
        "dataset": manifest["dataset"], "manifestSHA256": sha256(args.manifest),
        "sourceManifest": str(args.manifest.relative_to(ROOT)) if args.manifest.is_relative_to(ROOT) else str(args.manifest),
        "binarySHA256": sha256(args.binary), "engines": args.engines, "repeats": args.repeats,
        "cameraUsed": False, "controlToolsAvailable": False, "modelDownloadsRequested": False,
        "modelExecuted": False, "modelRequestsSubmitted": 0, "endpoint": endpoint,
        "outputContract": args.endpoint, "benchmarkContractVersion": "coco-six-typed-v2" if args.endpoint == "typed" else "coco-six-legacy-v1",
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "limitations": manifest["limitations"], "records": [], "complete": False,
        "timingScope": "Whole CLI request including IPC/model work; cold load and warm requests are not separated automatically"
    }
    write_json(output / "report.json", report)
    started = time.monotonic()
    try:
        # Read-only preflight. No app launch, access change, camera connection,
        # automatic model download, unload, or global cancellation occurs here.
        state = subprocess.run([str(args.binary), "ai-status"], capture_output=True, text=True, timeout=15)
        if state.returncode:
            raise RuntimeError("App AI status unavailable: " + state.stderr[:2000])
        report["aiStatusBefore"] = json.loads(state.stdout)
        if report["aiStatusBefore"].get("apple", {}).get("isBusy"):
            raise RuntimeError("App is already running an AI request")
        for repeat in range(args.repeats):
            # Rotate engine order across repeats to reduce a fixed-order bias.
            engines = args.engines if repeat % 2 == 0 else list(reversed(args.engines))
            for task in tasks:
                for engine in engines:
                    remaining = args.max_seconds - (time.monotonic() - started)
                    if remaining < args.timeout:
                        raise TimeoutError("Whole-run deadline reached before starting another bounded request")
                    key = f"{repeat + 1:02d}-{engine}-{task['id']}"
                    question = typed_question(task) if args.endpoint == "typed" else task["question"]
                    began = time.monotonic()
                    item = {"taskID": task["id"], "kind": task["kind"], "imageID": task["imageID"],
                            "engine": engine, "repeat": repeat + 1, "question": question,
                            "outputContract": args.endpoint,
                            "expected": task["expected"], "transportSucceeded": False,
                            "score": {"jsonParsed": False, "schemaValid": False, "factuallyCorrect": False, "taskPassed": False}}
                    try:
                        report["modelRequestsSubmitted"] += 1
                        command = [str(args.binary), endpoint, "--engine", engine,
                                   "--image", str(image_paths[task["imageID"]]), "--question", question]
                        if args.endpoint == "typed":
                            command += ["--kind", task["kind"]]
                        proc = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
                        item.update(exitCode=proc.returncode, stderr=proc.stderr[:12000])
                        (output / (key + ".stdout.json")).write_text(proc.stdout)
                        if proc.returncode == 0:
                            response = json.loads(proc.stdout, parse_constant=reject_constant, object_pairs_hook=unique_object)
                            item["response"] = response
                            if args.endpoint == "typed":
                                item["transportSucceeded"] = isinstance(response, dict) and "result" in response
                            else:
                                answer = response.get("answer", {}).get("answer")
                                item["transportSucceeded"] = isinstance(answer, str)
                            if item["transportSucceeded"]:
                                report["modelExecuted"] = True
                                if args.endpoint == "typed":
                                    item["typedEnvelopeVerified"] = typed_envelope_valid(response, task["kind"])
                                    item["score"] = score_typed_result(task["kind"], response["result"], task["expected"])
                                    if not item["typedEnvelopeVerified"]:
                                        item["score"]["taskPassed"] = False
                                        item["error"] = "Typed endpoint envelope did not match its declared contract"
                                else:
                                    item["score"] = score_answer(task["kind"], answer, task["expected"])
                                frame = response.get("frame", {})
                                source = images[task["imageID"]]
                                item["fixtureMetadataVerified"] = (
                                    response.get("engine") == engine
                                    and frame.get("deviceID") == "local-evaluation"
                                    and frame.get("timestampSource") == "local_image_import"
                                    and frame.get("width") == source["width"]
                                    and frame.get("height") == source["height"])
                                if not item["fixtureMetadataVerified"]:
                                    item["score"]["taskPassed"] = False
                                    item["error"] = "Image-only endpoint provenance or dimensions did not match"
                        else:
                            item["error"] = "CLI request failed"
                            item["hostRejectedGroundingOutput"] = "grounding_output_invalid" in proc.stderr
                    except subprocess.TimeoutExpired:
                        item["error"] = "CLI timed out; App request termination not established"
                        report["requiresAIIdleRecheck"] = True
                        raise
                    except (ValueError, AttributeError) as error:
                        item["error"] = "Invalid endpoint response: " + str(error)
                    finally:
                        item["wallSeconds"] = time.monotonic() - began
                        report["records"].append(item)
                        report["summary"] = summarize(report["records"])
                        write_json(output / (key + ".json"), item)
                        write_json(output / "report.json", report)
                        print(f"{key}: schema={item['score']['schemaValid']} factual={item['score']['factuallyCorrect']} seconds={item['wallSeconds']:.2f}", flush=True)
        report["complete"] = True
    except (Exception, KeyboardInterrupt) as error:
        report["runError"] = type(error).__name__ + ": " + str(error)
        if isinstance(error, KeyboardInterrupt):
            report["requiresAIIdleRecheck"] = True
    finally:
        report["elapsedSeconds"] = time.monotonic() - started
        report["summary"] = summarize(report["records"])
        report["allTasksPassed"] = report["complete"] and all(r["score"]["taskPassed"] for r in report["records"])
        write_json(output / "report.json", report)
    print(json.dumps({"report": str(output / "report.json"), "complete": report["complete"],
                      "allTasksPassed": report["allTasksPassed"], "summary": report["summary"]}, ensure_ascii=False))
    return 0 if report["complete"] else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
