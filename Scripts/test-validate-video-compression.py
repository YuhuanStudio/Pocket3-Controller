#!/usr/bin/env python3
import ast
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).with_name('validate-video-compression.py')

class VideoCompressionValidatorTests(unittest.TestCase):
    def test_default_is_hevc_noop_and_change_requires_flag(self):
        tree = ast.parse(SCRIPT.read_text())
        text = SCRIPT.read_text()
        self.assertIn("default='hevc'", text)
        self.assertIn("--allow-change", text)
        self.assertIn("current != target_raw", text)
        self.assertIn("result.get('noOp') is not True", text)
        self.assertIn("result.get('localSubmitted') is not False", text)
        self.assertIn("command = {'videoCompression': {'_0': target_raw}}", text)
        self.assertNotIn("command = {'value': {'videoCompression'", text)
        self.assertTrue(any(isinstance(node, ast.Try) for node in ast.walk(tree)))

    def test_script_never_exports_camera_images_or_controls_wifi_gimbal(self):
        text = SCRIPT.read_text()
        self.assertNotIn("snapshot", text)
        self.assertNotIn("move", text)
        self.assertNotIn("join-network", text)
        self.assertIn("cameraImagesStored': False", text)

if __name__ == '__main__':
    unittest.main()
