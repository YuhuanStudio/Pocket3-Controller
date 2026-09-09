#!/usr/bin/env python3
"""Public build provenance/configuration tests; no signing, build or git mutation."""
import base64
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import product_metadata as product


COMMIT = "a" * 40


class ProductMetadataTests(unittest.TestCase):
    def test_public_beta_archive_keeps_bundle_identity_and_prerelease(self):
        info = {"CFBundleDisplayName": product.DISPLAY_NAME, "CFBundleName": product.DISPLAY_NAME,
                "CFBundleIdentifier": product.BUNDLE_IDENTIFIER, "CFBundleExecutable": product.EXECUTABLE,
                "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "9",
                "Pocket3ReleaseChannel": "beta", "Pocket3PrereleaseNumber": 1}
        result = product.metadata(info)
        self.assertEqual(result["archiveStem"], "Pocket3Controller-0.0.1-beta.1")
        self.assertEqual(result["buildVersion"], "9")
        self.assertEqual(result["displayVersion"], "0.0.1 beta 1")
        for key, value in (("CFBundleIdentifier", "renamed.app"), ("CFBundleExecutable", "NewExecutable"),
                           ("Pocket3PrereleaseNumber", True)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                product.metadata({**info, key: value})

    def test_git_provenance_distinguishes_clean_dirty_unborn_and_head_race_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            for status, first_head, second_head, expected_commit, expected_clean in [
                ("", COMMIT, COMMIT, COMMIT, True),
                (" M Sources/App.swift\n", COMMIT, COMMIT, COMMIT, False),
                ("?? Resources/ReleaseSettings.json\n", COMMIT, COMMIT, COMMIT, False),
                ("", None, None, None, False),
                ("", COMMIT, "b" * 40, None, False),
            ]:
                heads = iter([first_head, second_head])
                def git(argv, **options):
                    self.assertEqual(argv[:4], ["git", "--no-optional-locks", "-C", str(project)])
                    self.assertEqual(options["env"]["GIT_OPTIONAL_LOCKS"], "0")
                    command = argv[4:]
                    if command == ["rev-parse", "--show-toplevel"]:
                        text = str(project)
                    elif command[0] == "status":
                        self.assertIn("--untracked-files=all", command)
                        self.assertIn("--ignore-submodules=none", command)
                        text = status
                    else:
                        self.assertEqual(command, ["rev-parse", "--verify", "HEAD^{commit}"])
                        text = next(heads)
                    return SimpleNamespace(returncode=0 if text is not None else 128, stdout=text or "")
                with self.subTest(status=status, head=first_head), patch.object(product.subprocess, "run", side_effect=git):
                    result = product.source_metadata(project)
                self.assertEqual(result, {"sourceCommit": expected_commit, "sourceClean": expected_clean,
                                          "sourceDirty": not expected_clean})
            self.assertEqual(list(project.iterdir()), [])

    def test_build_provenance_never_upgrades_dirty_or_changed_source_to_clean(self):
        clean = {"sourceCommit": COMMIT, "sourceDirty": False, "sourceClean": True}
        dirty = {**clean, "sourceDirty": True, "sourceClean": False}
        unknown = {"sourceCommit": None, "sourceDirty": True, "sourceClean": False}
        self.assertEqual(product.build_source_metadata(clean, clean), clean)
        for before, after in [(dirty, clean), (clean, dirty), (unknown, clean),
                              (clean, {**clean, "sourceCommit": "b" * 40})]:
            result = product.build_source_metadata(before, after)
            self.assertFalse(result["sourceClean"])
            self.assertTrue(result["sourceDirty"])

    def test_staged_provenance_cannot_claim_clean_without_exact_commit_or_boolean_flags(self):
        self.assertEqual(product.staged_source_metadata({}),
                         {"sourceCommit": None, "sourceDirty": True, "sourceClean": False})
        for info in [{"Pocket3SourceDirty": False, "Pocket3SourceClean": True},
                     {"Pocket3SourceCommit": "not-a-commit"},
                     {"Pocket3SourceCommit": COMMIT, "Pocket3SourceDirty": 0, "Pocket3SourceClean": True},
                     {"Pocket3SourceCommit": COMMIT, "Pocket3SourceDirty": True, "Pocket3SourceClean": True}]:
            with self.subTest(info=info), self.assertRaises(ValueError):
                product.staged_source_metadata(info)

    def test_public_configuration_reuses_allowlist_and_requires_signed_feed(self):
        settings = {"repositoryURL": "https://github.com/studio/pocket3", "feedURL": "https://example.org/appcast.xml",
                    "publicEDKey": base64.b64encode(bytes(range(32))).decode()}
        info = product.validate_public_settings(settings)
        self.assertEqual(product.configured_update_settings(info), info)
        for invalid in ({}, {**settings, "privateKey": "forbidden"}, {**settings, "feedURL": "http://example.org/feed"}):
            with self.assertRaises(ValueError):
                product.validate_public_settings(invalid)
        for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
            with self.assertRaises(ValueError):
                product.configured_update_settings({**info, key: False})


if __name__ == "__main__":
    unittest.main()
