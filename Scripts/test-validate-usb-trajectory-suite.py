#!/usr/bin/env python3
import ast, pathlib, unittest
SCRIPT = pathlib.Path(__file__).with_name('validate-usb-trajectory-suite.py')
class TrajectorySuiteTests(unittest.TestCase):
    def test_bounded_privacy_and_stop_on_failure(self):
        text = SCRIPT.read_text(); ast.parse(text)
        self.assertIn("['right', 'left', 'up', 'down'] * 5", text)
        self.assertIn("'cameraImagesStored': False", text)
        self.assertNotIn('snapshot', text); self.assertNotIn('.jpg', text)
        self.assertIn("report['status'] = 'failed'; report['failedTrial'] = index; break", text)
        self.assertIn("len(report['trials']) == 20", text)
if __name__ == '__main__': unittest.main()
