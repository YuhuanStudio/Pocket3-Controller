#!/usr/bin/env python3
"""Pure temporary-file release checks; no git mutation, network, app or hardware."""
import hashlib
import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("prepare_release", Path(__file__).with_name("prepare-github-release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
REPOSITORY = "YuhuanStudio/Pocket3-Controller"
COMMIT = "a" * 40


class PrepareGitHubReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.info = {"CFBundleDisplayName": "Pocket 3 Controller", "CFBundleName": "Pocket 3 Controller",
            "CFBundleIdentifier": "studio.yuhuan.Pocket3Bridge", "CFBundleExecutable": "Pocket3MCP",
            "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "9",
            "Pocket3ReleaseChannel": "beta", "Pocket3PrereleaseNumber": 1,
            "Pocket3BuildConfiguration": "release", "Pocket3SigningKind": "local_development",
            "Pocket3SourceCommit": COMMIT, "Pocket3SourceDirty": False, "Pocket3SourceClean": True}
        self.settings = {"repositoryURL": "https://github.com/" + REPOSITORY,
            "feedURL": "https://example.org/pocket3/appcast.xml",
            "publicEDKey": base64.b64encode(bytes(range(32))).decode()}
        self.info.update(release.validate_public_settings(self.settings))
        self.provenance = {"sourceCommit": COMMIT, "sourceDirty": False, "sourceClean": True}
        identity = release.metadata(self.info)
        contents = self.root / "dist" / release.APP_NAME / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
        (contents / "MacOS/Pocket3MCP").write_bytes(b"app fixture")
        (contents / "MacOS/pocket3").write_bytes(b"helper fixture")
        (self.root / "Resources").mkdir()
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.root / "Resources/ReleaseSettings.json").write_text(json.dumps(self.settings))
        (self.root / "artifacts").mkdir()
        (self.root / "docs/releases").mkdir(parents=True)
        (self.root / "docs/releases/0.0.1-beta.1.md").write_text(
            "# Pocket 3 Controller 0.0.1 beta 1\n\nCurated fixture notes; no device information.\n")
        app_hash = release.digest(contents / "MacOS/Pocket3MCP")
        helper_hash = release.digest(contents / "MacOS/pocket3")
        self.manifest = {"status": "complete", "verified": True, **identity, **self.provenance,
            "appExecutableSHA256": app_hash, "helperExecutableSHA256": helper_hash,
            "signing": "local_development", "notarized": False,
            "updateSettings": release.validate_public_settings(self.settings), "artifacts": []}
        self.payload = {"status": "complete", "passed": True, "verified": True,
            "manifestUnchanged": True, "artifactsUnchanged": True, "runID": "payload-run",
            "manifestBuildVersion": "9", "manifestAppExecutableSHA256": app_hash, "artifacts": {}}
        for extension in ("zip", "dmg"):
            name = identity["archiveStem"] + "." + extension
            path = self.root / "dist" / name
            path.write_bytes(("verified " + extension + " fixture").encode())
            entry = {"file": name, "bytes": path.stat().st_size, "sha256": release.digest(path)}
            self.manifest["artifacts"].append(entry)
            self.payload["artifacts"][extension] = {**entry, "verified": True,
                "app": {"verified": True, **self.provenance, "updateSettings": release.validate_public_settings(self.settings),
                        "appExecutableSHA256": app_hash, "helperExecutableSHA256": helper_hash}}
        self.gate = {"status": "complete", "passed": True, "configuration": "release",
            "runID": "gate-run", "releaseArtifactRunID": "payload-run", **identity, **self.provenance,
            "sourceUnchangedDuringGate": True,
            "appExecutableSHA256": app_hash, "checks": sorted(release.REQUIRED_CHECKS)}
        self.save_evidence()
        self.source = {"commit": COMMIT, "tag": "v0.0.1-beta.1", "clean": True, "tagMatchesHEAD": True}
        self.source_patch = patch.object(release, "source_identity", side_effect=lambda *args: dict(self.source))
        self.source_patch.start()
        self.addCleanup(self.source_patch.stop)

    def save_evidence(self):
        manifest_path = self.root / "dist/release-artifacts.json"
        manifest_path.write_text(json.dumps(self.manifest))
        self.payload["manifestSHA256"] = release.digest(manifest_path)
        (self.root / "artifacts/release-artifacts-verification.json").write_text(json.dumps(self.payload))
        (self.root / "artifacts/verification-gate.json").write_text(json.dumps(self.gate))

    def test_check_is_read_only_and_unnotarised_beta_is_explicitly_allowed(self):
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        with patch.object(release.subprocess, "run", side_effect=AssertionError("No process expected")):
            plan = release.prepare(self.root, REPOSITORY, check=True)
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))
        self.assertFalse(plan["published"])
        self.assertFalse(plan["remoteChecked"])
        self.assertFalse(plan["notarizedDeclaredByManifest"])
        self.assertIn("not notarised", " ".join(plan["warnings"]))
        self.assertTrue(plan["source"]["binarySourceCommitRecorded"])
        self.assertTrue(plan["signedUpdateFeedConfigured"])
        self.assertEqual(plan["archiveStem"], "Pocket3Controller-0.0.1-beta.1")
        self.assertNotIn("command", plan)

    def test_prepare_snapshots_only_allowlisted_assets_and_emits_unexecuted_draft_argv(self):
        (self.root / "artifacts/private-camera-photo.jpg").write_bytes(b"must not copy")
        (self.root / "artifacts/device-report.json").write_text('{"serial":"private"}')
        with patch.object(release.subprocess, "run", side_effect=AssertionError("No gh/network expected")):
            plan = release.prepare(self.root, REPOSITORY)
        output = Path(plan["command"]["cwd"])
        asset_names = {item["file"] for item in plan["assets"]}
        self.assertEqual(len(asset_names), 4)
        self.assertEqual({path.name for path in output.iterdir()}, asset_names | {"release-plan.json"})
        argv = plan["command"]["argv"]
        for flag in ("--draft", "--prerelease", "--verify-tag", "--latest=false"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--repo") + 1], REPOSITORY)
        self.assertEqual(argv[argv.index("--notes-file") + 1], "./release-notes.md")
        self.assertNotIn("./release-plan.json", argv)
        self.assertFalse(plan["command"]["executed"])
        self.assertNotIn("private", (output / "release-notes.md").read_text())
        for line in (output / "checksums-0.0.1-beta.1.txt").read_text().splitlines():
            expected, name = line.split("  ")
            self.assertEqual(expected, release.digest(output / name))
        with self.assertRaisesRegex(ValueError, "already exists"):
            release.prepare(self.root, REPOSITORY)

    def test_repo_is_required_and_cannot_be_a_url_flag_or_yunaudio(self):
        for value in (None, "", "https://github.com/a/b", "a/b/c", "--repo=x/y", "a/b\n", "YuhuanStudio/YunAudio"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.repository_name(value)

    def test_rejects_changed_binary_helper_or_archive(self):
        paths = [self.root / "dist" / release.APP_NAME / "Contents/MacOS/Pocket3MCP",
            self.root / "dist" / release.APP_NAME / "Contents/MacOS/pocket3",
            self.root / "dist" / self.manifest["artifacts"][0]["file"]]
        for path in paths:
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                release.prepare(self.root, REPOSITORY, check=True)
            path.write_bytes(original)

    def test_rejects_stale_partial_gate_or_wrong_payload_run(self):
        for key, bad in (("passed", False), ("status", "running"), ("configuration", "debug"),
                ("buildVersion", "7"), ("releaseArtifactRunID", "old-run"), ("checks", ["build"])):
            old = self.gate[key]
            self.gate[key] = bad
            self.save_evidence()
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.prepare(self.root, REPOSITORY, check=True)
            self.gate[key] = old
        self.save_evidence()

    def test_rejects_forged_extra_asset_and_symlink(self):
        self.manifest["artifacts"].append({"file": "photo.jpg", "bytes": 1, "sha256": "a" * 64})
        self.save_evidence()
        with self.assertRaisesRegex(ValueError, "one ZIP and one DMG"):
            release.prepare(self.root, REPOSITORY, check=True)
        self.manifest["artifacts"].pop()
        self.save_evidence()
        archive = self.root / "dist" / self.manifest["artifacts"][0]["file"]
        retained = archive.with_suffix(".retained")
        archive.rename(retained)
        archive.symlink_to(retained.name)
        with self.assertRaisesRegex(ValueError, "indirect"):
            release.prepare(self.root, REPOSITORY, check=True)

    def test_manifest_rewrite_and_recorded_commit_mismatch_are_rejected(self):
        path = self.root / "dist/release-artifacts.json"
        path.write_text(path.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "Manifest changed"):
            release.prepare(self.root, REPOSITORY, check=True)
        self.gate["sourceCommit"] = "b" * 40
        self.save_evidence()
        with self.assertRaisesRegex(ValueError, "source commit"):
            release.prepare(self.root, REPOSITORY, check=True)

    def test_source_changed_during_copy_never_gets_a_publish_command(self):
        actual_copy = release.shutil.copyfile
        def changed_copy(source, destination):
            result = actual_copy(source, destination)
            self.gate["runID"] = "changed-run"
            self.save_evidence()
            return result
        output = self.root / "dist/review"
        with patch.object(release.shutil, "copyfile", side_effect=changed_copy):
            with self.assertRaisesRegex(ValueError, "changed while preparing"):
                release.prepare(self.root, REPOSITORY, output)
        self.assertFalse((output / "release-plan.json").exists())

    def test_missing_dirty_and_stale_source_provenance_is_never_publishable(self):
        for record in (self.gate, self.manifest, self.payload["artifacts"]["zip"]["app"]):
            for key, value in (("sourceCommit", None), ("sourceCommit", "b" * 40),
                               ("sourceDirty", True), ("sourceClean", False)):
                original = record[key]
                record[key] = value
                self.save_evidence()
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    release.prepare(self.root, REPOSITORY, check=True)
                record[key] = original
        self.gate["sourceUnchangedDuringGate"] = False
        self.save_evidence()
        with self.assertRaisesRegex(ValueError, "Source changed"):
            release.prepare(self.root, REPOSITORY, check=True)

    def test_staging_source_and_public_settings_must_match_checked_in_configuration(self):
        path = self.root / "dist" / release.APP_NAME / "Contents/Info.plist"
        for key, value in (("Pocket3SourceCommit", "b" * 40), ("Pocket3SourceDirty", True),
                           ("SUPublicEDKey", base64.b64encode(bytes(reversed(range(32)))).decode()),
                           ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False)):
            changed = dict(self.info)
            changed[key] = value
            path.write_bytes(plistlib.dumps(changed))
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.prepare(self.root, REPOSITORY, check=True)
        path.write_bytes(plistlib.dumps(self.info))
        (self.root / "Resources/ReleaseSettings.json").write_text(json.dumps({**self.settings, "privateKey": "forbidden"}))
        with self.assertRaisesRegex(ValueError, "private key"):
            release.prepare(self.root, REPOSITORY, check=True)

    def test_archive_cannot_keep_different_feed_while_staging_app_looks_correct(self):
        for record in (self.manifest, self.payload["artifacts"]["zip"]["app"]):
            original = dict(record["updateSettings"])
            record["updateSettings"]["SUFeedURL"] = "https://example.org/different-feed.xml"
            self.save_evidence()
            with self.assertRaisesRegex(ValueError, "update settings"):
                release.prepare(self.root, REPOSITORY, check=True)
            record["updateSettings"] = original

    def test_git_source_requires_exact_tag_and_clean_worktree(self):
        self.source_patch.stop()
        def response(project, arguments):
            if arguments == ["rev-parse", "--show-toplevel"]: return str(self.root)
            if arguments[0] == "status": return ""
            return COMMIT
        with patch.object(release, "git_read", side_effect=response):
            self.assertEqual(release.source_identity(self.root, "v0.0.1-beta.1")["commit"], COMMIT)
        for dirty, tag_hash in ((" M Sources/example.swift", COMMIT), ("?? new-source.swift", COMMIT), ("", "b" * 40)):
            def changed(project, arguments):
                if arguments[0] == "status": return dirty
                if arguments[-1].startswith("refs/tags/"): return tag_hash
                return response(project, arguments)
            with self.subTest(dirty=dirty, tag_hash=tag_hash), patch.object(release, "git_read", side_effect=changed):
                with self.assertRaises(ValueError): release.source_identity(self.root, "v0.0.1-beta.1")


if __name__ == "__main__":
    unittest.main()
