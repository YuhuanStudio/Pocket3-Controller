#!/usr/bin/env python3
import ast, pathlib, unittest
SCRIPT = pathlib.Path(__file__).with_name('validate-roll-metrics.py')
class RollMetricsTests(unittest.TestCase):
    def test_no_image_and_reversible_contract(self):
        text = SCRIPT.read_text(); ast.parse(text)
        self.assertIn("'cameraImagesStored': False", text)
        self.assertNotIn('snapshot', text); self.assertNotIn('.jpg', text)
        self.assertIn("call('validation-roll'", text)
        self.assertIn("call('stop')", text)
        self.assertIn("'restoration'", text)
if __name__ == '__main__': unittest.main()
