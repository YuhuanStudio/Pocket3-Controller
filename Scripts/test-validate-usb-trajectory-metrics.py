#!/usr/bin/env python3
import ast
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).with_name('validate-usb-trajectory-metrics.py')

class MetricsTrajectoryTests(unittest.TestCase):
    def test_metrics_only_contract(self):
        text = SCRIPT.read_text()
        ast.parse(text)
        self.assertIn("'cameraImagesStored': False", text)
        self.assertNotIn('snapshot', text)
        self.assertNotIn('.jpg', text)
        self.assertIn('validation-trajectory-probe', text)
        self.assertIn("call('stop')", text)
        self.assertIn("call('validation-setup', '--access', 'manual')", text)

if __name__ == '__main__':
    unittest.main()
