#!/usr/bin/env python3
import importlib.util,pathlib,unittest

path=pathlib.Path(__file__).with_name('format_matrix_validation.py')
spec=importlib.util.spec_from_file_location('format_matrix_validation',path)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class FormatMatrixValidationTests(unittest.TestCase):
    mode={'width':1080,'height':1920,'frameRate':30}
    def samples(self):
        return [{'width':1080,'height':1920,'deviceID':'camera','inputPixelFormat':'nv12',
            'outputPixelFormat':'BGRA','rotationDegrees':0,'mirrored':False,'age':.02,
            'frames':frames,'fps':29.95,'session':'session'} for frames in (100,115,130)]
    def test_valid_portrait_metrics(self):
        fps,tolerance=module.validate_samples(self.mode,'nv12','camera','session',self.samples())
        self.assertAlmostEqual(fps,29.95);self.assertEqual(tolerance,1.5)
    def test_each_contract_failure_is_rejected(self):
        changes=[('width',1920),('deviceID','other'),('inputPixelFormat','uyvy'),
            ('outputPixelFormat','2vuy'),('rotationDegrees',None),('mirrored',None),('age',1.0)]
        for key,value in changes:
            with self.subTest(key=key):
                samples=self.samples();samples[1][key]=value
                with self.assertRaises(RuntimeError):module.validate_samples(self.mode,'nv12','camera','session',samples)
    def test_session_stall_and_rate_fail_independently(self):
        samples=self.samples();samples[1]['session']='replacement'
        with self.assertRaisesRegex(RuntimeError,'session changed'):module.validate_samples(self.mode,'nv12','camera','session',samples)
        samples=self.samples();samples[-1]['frames']=samples[0]['frames']
        with self.assertRaisesRegex(RuntimeError,'did not advance'):module.validate_samples(self.mode,'nv12','camera','session',samples)
        samples=self.samples()
        for sample in samples:sample['fps']=25
        with self.assertRaisesRegex(RuntimeError,'rate'):module.validate_samples(self.mode,'nv12','camera','session',samples)
    def test_empty_samples_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError,'No status'):module.validate_samples(self.mode,'nv12','camera','session',[])

if __name__=='__main__':unittest.main()
