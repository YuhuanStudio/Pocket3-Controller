#!/usr/bin/env python3
"""Remove allowlisted historical test media; dry-run unless --apply is explicit."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import time
import uuid


PROJECT = Path(__file__).resolve().parents[1]
MINIMUM_AGE_SECONDS = 3600
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
RECEIPT_DIRECTORY = "media-cleanup"


def classify(relative_path: str):
    """Fixed first-stage inventory, never a user-supplied glob or destination."""
    path = PurePosixPath(relative_path)
    parts = path.parts
    if (path.is_absolute() or len(parts) < 3 or parts[0] != "artifacts"
            or any(p in {".", ".."} or p.startswith(".")
                   or p.endswith((".app", ".bundle")) for p in parts)
            or path.suffix.lower() not in {".jpg", ".png"}):
        return None
    directory = parts[1:-1]
    if directory[0] in {"hardware-resumed", "hardware-roll-2026-09-09"}:
        if path.suffix.lower() == ".jpg":
            return "camera_snapshot", "Remove historical camera image; retain original measurement reports."
        return "hardware_ui_capture", "Remove historical UI capture that may contain a camera preview."
    if parts == ("artifacts", "mcp-smoke", "frame.jpg"):
        return "camera_snapshot", "Remove historical MCP camera image; retain protocol and frame metadata."
    if (len(directory) == 2 and directory[0] == "model-zoom-check"
            and parts[-1] == "post-zoom.jpg"):
        return "simulated_output", "Regenerable simulated-camera output; retain model results and recorded hashes."
    archived_ui = {
        ("offline-2026-09-09", "pre-capture-language-fix", "parity"),
        ("offline-2026-09-09", "final", "parity"),
        ("offline-telemetry-2026-09-09", "pre-pitch-translation-fix"),
        ("offline-telemetry-2026-09-09", "final", "parity"),
        ("offline-roll-2026-09-09", "pre-button-layout-fix"),
        ("ui",),
    }
    if directory in archived_ui and path.suffix.lower() == ".png":
        return "archived_ui_capture", "Superseded, regenerable UI capture; retain the historical gate results."
    return None


def identity(value):
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


@contextmanager
def open_directory(parent_fd, name):
    descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def candidate_parent(artifacts_fd, relative_path):
    if classify(relative_path) is None:
        raise ValueError("Path is outside the media cleanup allowlist")
    parts = PurePosixPath(relative_path).parts[1:]
    descriptor = os.dup(artifacts_fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor, parts[-1]
    finally:
        os.close(descriptor)


def inventory(artifacts_fd, cutoff):
    selected, skipped = [], []

    def walk(descriptor, parts):
        for name in sorted(os.listdir(descriptor)):
            relative = "/".join(("artifacts", *parts, name))
            if name.startswith(".") or name.endswith((".app", ".bundle")):
                continue
            if not parts and name in {"parity", "evaluation", RECEIPT_DIRECTORY}:
                continue
            try:
                info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    skipped.append({"path": relative, "reason": "symlink"})
                elif stat.S_ISDIR(info.st_mode):
                    with open_directory(descriptor, name) as child:
                        walk(child, (*parts, name))
                elif (classification := classify(relative)) is not None:
                    if not stat.S_ISREG(info.st_mode):
                        skipped.append({"path": relative, "reason": "not_regular"})
                    elif info.st_mtime >= cutoff:
                        skipped.append({"path": relative, "reason": "modified_within_one_hour"})
                    else:
                        category, reason = classification
                        selected.append({"path": relative, "bytes": info.st_size,
                                         "category": category, "reason": reason,
                                         "identity": identity(info)})
            except OSError:
                skipped.append({"path": relative, "reason": "unavailable_or_changed"})

    walk(artifacts_fd, ())
    return selected, skipped


def append_receipt(descriptor, record):
    data = (json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    while data:
        written = os.write(descriptor, data)
        if written <= 0:
            raise OSError("Could not write the media cleanup receipt")
        data = data[written:]
    os.fsync(descriptor)


def remove_candidate(artifacts_fd, candidate, receipt_fd, cutoff):
    """Use descriptor-relative access throughout; no symlink may enter the path."""
    with candidate_parent(artifacts_fd, candidate["path"]) as (parent, name):
        descriptor = os.open(name, FILE_FLAGS, dir_fd=parent)
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or identity(info) != candidate["identity"]
                    or info.st_mtime >= cutoff):
                return False
            digest = hashlib.sha256()
            while chunk := os.read(descriptor, 1024 * 1024):
                digest.update(chunk)
            if identity(os.fstat(descriptor)) != candidate["identity"]:
                return False
            record = {key: value for key, value in candidate.items() if key != "identity"}
            record.update(event="prepared", sha256=digest.hexdigest(),
                          recordedAt=datetime.now(timezone.utc).isoformat())
            # A durable receipt is mandatory BEFORE unlink. Failure propagates;
            # the file stays in place and the run stops.
            append_receipt(receipt_fd, record)
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISREG(current.st_mode) or identity(current) != candidate["identity"]:
                append_receipt(receipt_fd, {"event": "skipped_after_prepare", "path": candidate["path"],
                                           "reason": "file_changed"})
                return False
            os.unlink(name, dir_fd=parent)
            os.fsync(parent)
            append_receipt(receipt_fd, {"event": "removed", "path": candidate["path"],
                                       "recordedAt": datetime.now(timezone.utc).isoformat()})
            return True
        finally:
            os.close(descriptor)


def run(project: Path, *, apply=False, now=None):
    """`project` exists for isolated tempdir tests; CLI always uses this repo."""
    now = time.time() if now is None else now
    cutoff = now - MINIMUM_AGE_SECONDS
    with open_directory(None, project) as project_fd:
        with open_directory(project_fd, "artifacts") as artifacts_fd:
            selected, skipped = inventory(artifacts_fd, cutoff)
            summary = {"mode": "apply" if apply else "dry_run", "minimumAgeSeconds": MINIMUM_AGE_SECONDS,
                       "candidates": [{k: v for k, v in item.items() if k != "identity"} for item in selected],
                       "candidateCount": len(selected), "candidateBytes": sum(x["bytes"] for x in selected),
                       "skipped": skipped, "removedCount": 0, "removedBytes": 0, "receipt": None}
            if not apply or not selected:
                return summary
            try:
                os.mkdir(RECEIPT_DIRECTORY, mode=0o700, dir_fd=artifacts_fd)
            except FileExistsError:
                pass
            with open_directory(artifacts_fd, RECEIPT_DIRECTORY) as receipt_directory_fd:
                filename = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + str(uuid.uuid4()) + ".jsonl"
                receipt_fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=receipt_directory_fd)
                try:
                    append_receipt(receipt_fd, {"event": "run_started", "schemaVersion": 1,
                                               "policy": "historical_test_media_first_stage",
                                               "minimumAgeSeconds": MINIMUM_AGE_SECONDS,
                                               "hardwareAccess": False, "validationRerun": False})
                    os.fsync(receipt_directory_fd)
                    os.fsync(artifacts_fd)
                    summary["receipt"] = f"artifacts/{RECEIPT_DIRECTORY}/{filename}"
                    for candidate in selected:
                        if remove_candidate(artifacts_fd, candidate, receipt_fd, cutoff):
                            summary["removedCount"] += 1
                            summary["removedBytes"] += candidate["bytes"]
                        else:
                            summary["skipped"].append({"path": candidate["path"], "reason": "file_changed"})
                    append_receipt(receipt_fd, {"event": "run_completed", "removedCount": summary["removedCount"],
                                               "removedBytes": summary["removedBytes"]})
                finally:
                    os.close(receipt_fd)
            return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Apply the fixed allowlist after writing durable receipts")
    args = parser.parse_args()
    try:
        summary = run(PROJECT, apply=args.apply)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Cleanup stopped; inspect artifacts/media-cleanup for any partial receipt. {error}\n")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
