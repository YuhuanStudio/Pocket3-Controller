#!/usr/bin/env python3
"""Exercise the local installer using only newly created temporary fixtures.

No App is launched, and neither dist nor /Applications is read or changed.
The real macOS atomic exchange is exercised when running on Darwin.
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("install-built-app.py")
spec = importlib.util.spec_from_file_location("install_built_app", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pocket3-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / installer.APP_NAME
        self.alias = self.root / installer.LEGACY_NAME

    def bundle(self, path, marker):
        contents = path / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleName": "Pocket 3 Controller",
            "CFBundleDisplayName": "Pocket 3 Controller",
            "CFBundleIdentifier": "studio.yuhuan.Pocket3Bridge",
            "CFBundleExecutable": "Pocket3MCP",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "7",
            "Pocket3ReleaseChannel": "beta",
            "Pocket3PrereleaseNumber": 1,
        }))
        (contents / "fixture-marker").write_text(marker)
        return path

    def marker(self, path):
        return (path / "Contents/fixture-marker").read_text()

    def incoming(self):
        return list(self.root.glob(".Pocket3Controller-incoming-*.bundle-backup"))

    def test_install_absent_destination(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        self.assertEqual(installer.install(source, self.destination), [])
        self.assertFalse(os.path.lexists(source))
        self.assertEqual(self.marker(self.destination), "new")
        self.assertFalse(self.destination.is_symlink())
        self.assertEqual(self.incoming(), [])

    @unittest.skipUnless(sys.platform == "darwin", "Uses the actual renamex_np exchange")
    def test_install_preserves_existing_real_bundle(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        self.bundle(self.destination, "old")
        old_inode = self.destination.stat().st_ino
        preserved = installer.install(source, self.destination)
        self.assertEqual(self.marker(self.destination), "new")
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].parent, self.root)
        self.assertEqual(self.marker(preserved[0]), "old")
        self.assertEqual(preserved[0].stat().st_ino, old_inode)
        self.assertEqual(self.incoming(), [])

    def test_install_preserves_relative_absolute_and_dangling_links(self):
        for kind in ("relative", "absolute", "dangling"):
            with self.subTest(kind=kind):
                folder = self.root / kind
                folder.mkdir()
                source = self.bundle(folder / "staging/New.app", "new")
                destination = folder / installer.APP_NAME
                target = folder / "untouched-target.app"
                if kind != "dangling":
                    self.bundle(target, "target")
                    original_inode = target.stat().st_ino
                link = str(target) if kind == "absolute" else target.name
                destination.symlink_to(link)
                preserved = installer.install(source, destination)
                self.assertEqual(self.marker(destination), "new")
                self.assertEqual(len(preserved), 1)
                self.assertTrue(preserved[0].is_symlink())
                self.assertEqual(os.readlink(preserved[0]), link)
                self.assertEqual(preserved[0].parent, destination.parent)
                if kind == "dangling":
                    self.assertFalse(os.path.lexists(target))
                else:
                    self.assertEqual(self.marker(target), "target")
                    self.assertEqual(target.stat().st_ino, original_inode)
                    self.assertEqual(preserved[0].resolve(), target.resolve())

    def test_legacy_alias_absent_and_repeated_call(self):
        self.bundle(self.destination, "new")
        self.assertEqual(installer.ensure_legacy_alias(self.destination, self.alias), [])
        self.assertTrue(self.alias.is_symlink())
        self.assertEqual(os.readlink(self.alias), self.destination.name)
        inode = self.alias.lstat().st_ino
        self.assertEqual(installer.ensure_legacy_alias(self.destination, self.alias), [])
        self.assertEqual(self.alias.lstat().st_ino, inode)
        self.assertEqual(self.marker(self.destination), "new")

    def test_legacy_real_bundle_is_retained(self):
        self.bundle(self.destination, "new")
        self.bundle(self.alias, "legacy")
        inode = self.alias.stat().st_ino
        preserved = installer.ensure_legacy_alias(self.destination, self.alias)
        self.assertEqual(len(preserved), 1)
        self.assertEqual(self.marker(preserved[0]), "legacy")
        self.assertEqual(preserved[0].stat().st_ino, inode)
        self.assertEqual(os.readlink(self.alias), self.destination.name)
        self.assertEqual(self.marker(self.destination), "new")

    def test_legacy_link_target_is_untouched(self):
        self.bundle(self.destination, "new")
        target = self.bundle(self.root / "legacy-target.app", "legacy-target")
        self.alias.symlink_to(target.name)
        preserved = installer.ensure_legacy_alias(self.destination, self.alias)
        self.assertEqual(len(preserved), 1)
        self.assertTrue(preserved[0].is_symlink())
        self.assertEqual(os.readlink(preserved[0]), target.name)
        self.assertEqual(self.marker(target), "legacy-target")
        self.assertEqual(os.readlink(self.alias), self.destination.name)

    def test_unrelated_files_at_destination_or_alias_are_retained(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        self.destination.write_text("unrelated destination")
        with self.assertRaises(ValueError):
            installer.install(source, self.destination)
        self.assertEqual(self.destination.read_text(), "unrelated destination")
        self.assertEqual(self.marker(source), "new")
        self.alias.write_text("unrelated legacy path")
        with self.assertRaises(ValueError):
            installer.ensure_legacy_alias(self.destination, self.alias)
        self.assertEqual(self.alias.read_text(), "unrelated legacy path")

    def test_staged_symlink_and_source_inside_destination_are_rejected(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        link = self.root / "staged-link.app"
        link.symlink_to(source)
        with self.assertRaises(ValueError):
            installer.install(link, self.destination)
        with self.assertRaises(ValueError):
            installer.install(source, source)
        # A staged bundle nested in an existing destination must not be moved
        # out of that destination and silently become its replacement.
        with self.assertRaises(ValueError):
            installer.install(source, source.parent)
        self.assertEqual(self.marker(source), "new")
        self.assertEqual(os.readlink(link), str(source))

    def test_incoming_name_collision_never_overwrites(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        collision = self.root / ".Pocket3Controller-incoming-fixed.bundle-backup"
        collision.write_text("unrelated collision")
        with patch.object(installer.uuid, "uuid4", return_value=SimpleNamespace(hex="fixed")):
            with self.assertRaises(FileExistsError):
                installer.install(source, self.destination)
        self.assertEqual(collision.read_text(), "unrelated collision")
        self.assertEqual(self.marker(source), "new")
        self.assertFalse(os.path.lexists(self.destination))

    def test_alias_temporary_and_backup_collisions_never_overwrite(self):
        self.bundle(self.destination, "new")
        self.bundle(self.alias, "legacy")
        temporary = self.root / ".Pocket3Controller-alias-fixed"
        temporary.write_text("temporary collision")
        with patch.object(installer.uuid, "uuid4", return_value=SimpleNamespace(hex="fixed")):
            with self.assertRaises(FileExistsError):
                installer.ensure_legacy_alias(self.destination, self.alias)
        self.assertEqual(temporary.read_text(), "temporary collision")
        self.assertEqual(self.marker(self.alias), "legacy")
        temporary.unlink()
        backup = self.root / ".Pocket3Controller-legacy-fixed.bundle-backup"
        backup.write_text("backup collision")
        with patch.object(installer.uuid, "uuid4", return_value=SimpleNamespace(hex="fixed")):
            with self.assertRaises(FileExistsError):
                installer.ensure_legacy_alias(self.destination, self.alias)
        self.assertEqual(backup.read_text(), "backup collision")
        self.assertEqual(self.marker(self.alias), "legacy")
        self.assertFalse(os.path.lexists(temporary))

    def test_failed_exchange_retains_both_bundles(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        self.bundle(self.destination, "old")
        with patch.object(installer, "exchange", side_effect=OSError("fixture exchange failure")):
            with self.assertRaises(OSError):
                installer.install(source, self.destination)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(len(self.incoming()), 1)
        self.assertEqual(self.marker(self.incoming()[0]), "new")

    def test_failed_link_replacement_restores_the_old_link(self):
        source = self.bundle(self.root / "staging/New.app", "new")
        target = self.bundle(self.root / "old-target.app", "old-target")
        self.destination.symlink_to(target.name)
        original_rename = Path.rename

        def failing_rename(path, destination):
            if path.name.startswith(".Pocket3Controller-incoming-"):
                raise OSError("fixture replacement failure")
            return original_rename(path, destination)

        with patch.object(Path, "rename", failing_rename):
            with self.assertRaises(OSError):
                installer.install(source, self.destination)
        self.assertEqual(os.readlink(self.destination), target.name)
        self.assertEqual(self.marker(target), "old-target")
        self.assertEqual(len(self.incoming()), 1)
        self.assertEqual(self.marker(self.incoming()[0]), "new")

    def test_failed_alias_replacement_restores_the_real_legacy_bundle(self):
        self.bundle(self.destination, "new")
        self.bundle(self.alias, "legacy")
        original_rename = Path.rename

        def failing_rename(path, destination):
            if path.name.startswith(".Pocket3Controller-alias-"):
                raise OSError("fixture alias failure")
            return original_rename(path, destination)

        with patch.object(Path, "rename", failing_rename):
            with self.assertRaises(OSError):
                installer.ensure_legacy_alias(self.destination, self.alias)
        self.assertFalse(self.alias.is_symlink())
        self.assertEqual(self.marker(self.alias), "legacy")
        self.assertEqual(self.marker(self.destination), "new")
        self.assertEqual(list(self.root.glob(".Pocket3Controller-alias-*")), [])


if __name__ == "__main__":
    unittest.main()
