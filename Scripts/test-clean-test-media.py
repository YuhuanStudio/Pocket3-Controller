#!/usr/bin/env python3
"""Cleanup safety tests: all writes/deletions are confined to temporary fixtures."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("clean_test_media", Path(__file__).with_name("clean-test-media.py"))
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)


class MediaCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pocket3-media-cleanup-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        (self.root / "artifacts").mkdir(parents=True)
        self.now = time.time()

    def file(self, relative, content=b"synthetic test bytes", age=7200):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        os.utime(path, (self.now - age, self.now - age))
        return path

    def test_dry_run_is_metadata_only_and_preserves_reports_fixtures_and_current_parity(self):
        old = self.file("artifacts/hardware-resumed/old.jpg")
        for relative in ["artifacts/hardware-resumed/result.json", "artifacts/hardware-resumed/run.log",
                         "artifacts/evaluation/fixtures/text.png", "artifacts/parity/current.png",
                         "artifacts/new-hardware-batch/image.jpg", "artifacts/previous/Old.app/image.png",
                         "research/camera.jpg", "Resources/Icon.png", "artifacts/hardware-resumed/.private.jpg"]:
            self.file(relative)
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*"))
        with patch.object(cleanup.hashlib, "sha256", side_effect=AssertionError("Dry-run read image contents")):
            result = cleanup.run(self.root, now=self.now)
        self.assertEqual(result["mode"], "dry_run")
        self.assertEqual([x["path"] for x in result["candidates"]], [str(old.relative_to(self.root))])
        self.assertEqual(result["removedCount"], 0)
        self.assertIsNone(result["receipt"])
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*")))

    def test_apply_fsyncs_receipt_before_unlink_and_keeps_fresh_and_future_files(self):
        payload = b"not a photograph; deterministic cleanup fixture"
        old = self.file("artifacts/hardware-resumed/old.jpg", payload)
        fresh = self.file("artifacts/hardware-resumed/fresh.jpg", age=3599)
        future = self.file("artifacts/hardware-resumed/future.jpg", age=-10)
        report = self.file("artifacts/hardware-resumed/result.json", b'{"passed":false}')
        receipt_synced = []
        real_fsync, real_unlink = os.fsync, os.unlink

        def synced(fd):
            real_fsync(fd)
            if stat.S_ISREG(os.fstat(fd).st_mode):
                receipt_synced.append(fd)

        def unlink_after_receipt(name, *, dir_fd=None):
            self.assertTrue(receipt_synced)
            receipts = list((self.root / "artifacts/media-cleanup").glob("*.jsonl"))
            events = [json.loads(line) for line in receipts[0].read_text().splitlines()]
            prepared = [event for event in events if event["event"] == "prepared"]
            self.assertEqual(prepared[0]["path"], "artifacts/hardware-resumed/old.jpg")
            self.assertEqual(prepared[0]["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertEqual(prepared[0]["bytes"], len(payload))
            self.assertEqual(prepared[0]["category"], "camera_snapshot")
            self.assertTrue(prepared[0]["reason"])
            real_unlink(name, dir_fd=dir_fd)

        with patch.object(cleanup.os, "fsync", side_effect=synced), patch.object(cleanup.os, "unlink", side_effect=unlink_after_receipt):
            result = cleanup.run(self.root, apply=True, now=self.now)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists() and future.exists() and report.exists())
        self.assertEqual(result["removedCount"], 1)
        self.assertEqual(result["removedBytes"], len(payload))
        receipt = self.root / result["receipt"]
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        events = [json.loads(line) for line in receipt.read_text().splitlines()]
        self.assertEqual([x["event"] for x in events], ["run_started", "prepared", "removed", "run_completed"])
        self.assertIs(events[0]["hardwareAccess"], False)
        self.assertIs(events[0]["validationRerun"], False)
        self.assertEqual(json.loads(report.read_text()), {"passed": False})

    def test_symlink_files_directories_and_special_files_never_enter_plan(self):
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        target = outside / "keep.jpg"
        target.write_bytes(b"outside")
        folder = self.root / "artifacts/hardware-resumed"
        folder.mkdir()
        (folder / "linked.jpg").symlink_to(target)
        (folder / "nested").symlink_to(outside, target_is_directory=True)
        os.mkfifo(folder / "pipe.jpg")
        result = cleanup.run(self.root, apply=True, now=self.now)
        self.assertEqual(result["candidateCount"], 0)
        self.assertTrue(target.exists() and (folder / "linked.jpg").is_symlink())
        self.assertEqual({x["reason"] for x in result["skipped"]}, {"symlink", "not_regular"})
        self.assertIsNone(result["receipt"])

    def test_artifacts_and_receipt_directory_symlinks_are_rejected(self):
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        artifacts = self.root / "artifacts"
        artifacts.rmdir()
        artifacts.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            cleanup.run(self.root, apply=True, now=self.now)
        artifacts.unlink()
        artifacts.mkdir()
        old = self.file("artifacts/hardware-resumed/old.jpg")
        (artifacts / "media-cleanup").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            cleanup.run(self.root, apply=True, now=self.now)
        self.assertTrue(old.exists())
        self.assertEqual(list(outside.iterdir()), [])

    def test_parent_replaced_by_symlink_after_scan_cannot_escape_repository(self):
        old = self.file("artifacts/hardware-resumed/old.jpg")
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        target = outside / "old.jpg"
        target.write_bytes(b"external must remain")
        original = cleanup.inventory

        def swap(*args):
            result = original(*args)
            old.parent.rename(old.parent.with_name("preserved-original"))
            old.parent.symlink_to(outside, target_is_directory=True)
            return result

        with patch.object(cleanup, "inventory", side_effect=swap), self.assertRaises(OSError):
            cleanup.run(self.root, apply=True, now=self.now)
        self.assertEqual(target.read_bytes(), b"external must remain")
        self.assertTrue(self.root.joinpath("artifacts/preserved-original/old.jpg").exists())

    def test_changed_file_is_skipped_and_failed_predelete_receipt_never_unlinks(self):
        old = self.file("artifacts/hardware-resumed/old.jpg")
        original = cleanup.inventory

        def changed(*args):
            result = original(*args)
            old.write_bytes(b"new active contents")
            return result

        with patch.object(cleanup, "inventory", side_effect=changed):
            result = cleanup.run(self.root, apply=True, now=self.now)
        self.assertEqual(result["removedCount"], 0)
        self.assertEqual(old.read_bytes(), b"new active contents")
        os.utime(old, (self.now - 7200, self.now - 7200))
        real_fsync = os.fsync
        regular_syncs = 0

        def failed_sync(fd):
            nonlocal regular_syncs
            if stat.S_ISREG(os.fstat(fd).st_mode):
                regular_syncs += 1
                if regular_syncs == 2:  # Header succeeded; prepared receipt cannot become durable.
                    raise OSError("simulated durable receipt failure")
            real_fsync(fd)

        with patch.object(cleanup.os, "fsync", side_effect=failed_sync), self.assertRaises(OSError):
            cleanup.run(self.root, apply=True, now=self.now)
        self.assertTrue(old.exists())

    def test_final_recheck_rejects_symlink_inserted_after_prepared_receipt(self):
        old = self.file("artifacts/hardware-resumed/old.jpg")
        outside = Path(self.temporary.name) / "outside.jpg"
        outside.write_bytes(b"keep outside")
        append = cleanup.append_receipt

        def replace(fd, record):
            append(fd, record)
            if record["event"] == "prepared":
                old.rename(old.with_suffix(".preserved"))
                old.symlink_to(outside)

        with patch.object(cleanup, "append_receipt", side_effect=replace):
            result = cleanup.run(self.root, apply=True, now=self.now)
        self.assertEqual(result["removedCount"], 0)
        self.assertTrue(old.is_symlink() and outside.exists() and old.with_suffix(".preserved").exists())
        records = [json.loads(line) for line in (self.root / result["receipt"]).read_text().splitlines()]
        self.assertIn("skipped_after_prepare", [x["event"] for x in records])

    def test_allowlist_rejects_traversal_protected_directories_and_unlisted_media(self):
        for relative in ["/tmp/old.jpg", "artifacts/hardware-resumed/../../outside.jpg",
                         "artifacts/parity/old.png", "artifacts/evaluation/fixtures/old.png",
                         "artifacts/offline-2026-09-09/unlisted/old.png",
                         "artifacts/hardware-resumed/Old.app/Resources/Icon.png",
                         "artifacts/hardware-resumed/result.json", "artifacts/hardware-resumed/video.mov",
                         "artifacts/model-zoom-check/model/other.jpg"]:
            self.assertIsNone(cleanup.classify(relative), relative)
        for relative in ["artifacts/hardware-resumed/portrait/session/1080.jpg",
                         "artifacts/hardware-roll-2026-09-09/one-step/before.jpg",
                         "artifacts/offline-2026-09-09/final/parity/main.png",
                         "artifacts/model-zoom-check/model/post-zoom.jpg"]:
            self.assertIsNotNone(cleanup.classify(relative), relative)


if __name__ == "__main__":
    unittest.main()
