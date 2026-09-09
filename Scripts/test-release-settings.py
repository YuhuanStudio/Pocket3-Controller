#!/usr/bin/env python3
import base64,importlib.util,json,pathlib,plistlib,subprocess,sys,tempfile,unittest
spec=importlib.util.spec_from_file_location('release_settings',pathlib.Path(__file__).with_name('release-settings.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class ReleaseSettingsTests(unittest.TestCase):
 def test_accepts_public_project_configuration(self):
  key=base64.b64encode(bytes(range(32))).decode()
  value=module.settings({'repositoryURL':'https://github.com/studio/pocket3','feedURL':'https://example.org/appcast.xml','publicEDKey':key})
  self.assertEqual(value['SUPublicEDKey'],key)
  self.assertEqual(value['SUFeedURL'],'https://example.org/appcast.xml')
 def test_rejects_missing_untrusted_or_private_fields(self):
  key=base64.b64encode(bytes(range(32))).decode()
  for value in [
   {'feedURL':'https://example.org/appcast.xml'},
   {'publicEDKey':key},
   {'feedURL':'http://example.org/appcast.xml','publicEDKey':key},
   {'feedURL':'https://user:secret@example.org/appcast.xml','publicEDKey':key},
   {'feedURL':'https://example.org/appcast.xml','publicEDKey':'bad'},
   {'feedURL':'https://example.org/appcast.xml','publicEDKey':key,'privateKey':'secret'},
   {'repositoryURL':'https://github.com/YuhuanStudio/YunAudio'},
  ]:
   with self.subTest(value=list(value.keys())):
    with self.assertRaises(ValueError):module.settings(value)
 def test_cli_applies_only_public_fields_to_staging(self):
  with tempfile.TemporaryDirectory() as directory:
   folder=pathlib.Path(directory);settings=folder/'settings.json';info=folder/'Info.plist'
   settings.write_text(json.dumps({'feedURL':'https://example.org/pocket3/appcast.xml','publicEDKey':base64.b64encode(bytes(range(32))).decode()}))
   info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'studio.yuhuan.Pocket3Bridge'}))
   subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('release-settings.py')),str(settings),'--info-plist',str(info)],check=True,capture_output=True)
   value=plistlib.loads(info.read_bytes());self.assertEqual(value['CFBundleIdentifier'],'studio.yuhuan.Pocket3Bridge');self.assertEqual(value['SUFeedURL'],'https://example.org/pocket3/appcast.xml')
 def test_unconfigured_local_build_is_valid(self):self.assertEqual(module.settings({}),{})
if __name__=='__main__':unittest.main()
