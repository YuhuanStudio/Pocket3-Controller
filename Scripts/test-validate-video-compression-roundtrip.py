#!/usr/bin/env python3
import ast
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).with_name('validate-video-compression-roundtrip.py')

class VideoCompressionRoundTripTests(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text()
        self.tree = ast.parse(self.text)

    def test_dry_run_is_default_and_execution_is_explicit(self):
        self.assertIn("--execute", self.text)
        self.assertIn("writesPermitted': 2 if args.execute else 0", self.text)
        self.assertIn("if not args.execute:", self.text)
        self.assertIn("dry_run_complete", self.text)

    def test_roundtrip_requires_independent_h264_then_exact_restore(self):
        self.assertIn("write(0, baseline, 'switch_to_h264')", self.text)
        self.assertIn("command = {'videoCompression': {'_0': compression_raw}}", self.text)
        self.assertNotIn("command = {'value': {'videoCompression'", self.text)
        self.assertIn("if observed_raw != 0", self.text)
        self.assertIn("write(original_raw, changed, 'restore_original')", self.text)
        self.assertIn("if restored_raw != original_raw or restored != baseline", self.text)
        self.assertIn("if emergency_raw == 0", self.text)
        self.assertIn("restore_after_unconfirmed_switch", self.text)
        self.assertIn("no retry is permitted", self.text)

    def test_scope_excludes_camera_images_wifi_and_motion(self):
        self.assertIn("cameraImagesStored': False", self.text)
        self.assertNotIn('join-network', self.text)
        self.assertNotIn("'snapshot'", self.text)
        self.assertNotIn("'move'", self.text)
        self.assertTrue(any(isinstance(node, ast.Try) for node in ast.walk(self.tree)))

if __name__ == '__main__':
    unittest.main()
