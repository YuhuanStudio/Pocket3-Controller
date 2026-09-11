#!/usr/bin/env python3
"""Capture each app surface and verify its actual AppKit presentation."""
import json, pathlib, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
cli=root/'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3'
out=root/'artifacts/parity';out.mkdir(parents=True,exist_ok=True)
def persisted_language():
 result=subprocess.run(['/usr/bin/defaults','read','studio.yuhuan.Pocket3Bridge','com.yuhuanstudio.yunaudio.language'],capture_output=True,text=True)
 return result.returncode,result.stdout.strip()
original_language=persisted_language()
checks=json.loads(subprocess.check_output([str(cli),'ui-check'],text=True))
(out/'ui-check.json').write_text(json.dumps(checks,indent=2)+'\n')
if not checks['passed']: raise SystemExit(json.dumps(checks))
results=[]
for appearance in ['light','dark']:
 for surface,pages in [('main',['camera','engines','diagnostics']),('settings',['general','appearance','camera','permissions','shortcuts','diagnostics','about']),('updates',['updates']),('panel',['panel'])]:
  for page in pages:
   path=out/f'{surface}-{page}-{appearance}.png'
   result=json.loads(subprocess.check_output([str(cli),'ui-capture','--surface',surface,'--page',page,'--appearance',appearance,'--output',str(path)],text=True))
   if surface=='main':
    assert result['width']==2360 and result['height']==1440,result
    assert result['chromeIntegrated'],result
   if surface=='settings':assert result['chromeIntegrated'],result
   results.append(result)
# The settings language control and the live main window must both change.
for surface,page in [('main','camera'),('settings','general'),('settings','about')]:
 path=out/f'{surface}-{page}-en.png'
 results.append(json.loads(subprocess.check_output([str(cli),'ui-capture','--surface',surface,'--page',page,'--appearance','light','--language','en','--output',str(path)],text=True)))
# Measure the original compact banner in the actual window, including a long
# message that must not expand vertically or push controls over the footer.
for name,appearance,language,message in [
 ('cancelled','dark','zh-Hant','動作已取消'),
 ('long-error','light','en','The camera connection changed while an adjustment was waiting for confirmation. Reconnect Pocket 3 in Webcam mode, wait for a fresh preview, and check the connection status before starting another action. If this message appears again, review the diagnostics page for the current session and its available controls.'),
]:
 path=out/f'main-banner-{name}.png'
 result=json.loads(subprocess.check_output([str(cli),'ui-capture','--surface','main','--page','camera',
  '--appearance',appearance,'--language',language,'--message',message,'--output',str(path)],text=True))
 layout=result['layout'];banner=layout['banner'];footer=layout['footer']
 assert 27 <= banner[1][1] <= 32, {'banner':banner,'fixture':name}
 for column in ['source','previewColumn','inspector']:
  origin,size=layout[column]
  assert origin[1] >= banner[0][1]+banner[1][1]-1, result
  assert origin[1]+size[1] <= footer[0][1]+1, result
 results.append(result)
# Battery/pose presentation is a declared data fixture, never a fake live
# connection. Exercise the shared components in all supported languages.
for language in ['en','zh-Hant','zh-Hans']:
 for state in ['full','low','falling','low-falling']:
  path=out/f'telemetry-{state}-{language}.png'
  result=json.loads(subprocess.check_output([str(cli),'ui-capture','--surface','telemetry-fixture','--page',state,
   '--appearance','light' if language=='en' else 'dark','--language',language,'--output',str(path)],text=True))
  assert result.get('simulation') is True and result['width']==680 and 200<=result['height']<=1100,result
  results.append(result)
for language in ['en','zh-Hant','zh-Hans']:
 for state in ['negative','maximum','unavailable']:
  path=out/f'roll-{state}-{language}.png'
  result=json.loads(subprocess.check_output([str(cli),'ui-capture','--surface','roll-fixture','--page',state,
   '--appearance','light' if language=='en' else 'dark','--language',language,'--output',str(path)],text=True))
  assert result.get('simulation') is True and result['width']==536 and 80<=result['height']<=400,result
  results.append(result)
for language in ['en','zh-Hant','zh-Hans']:
 path=out/f'gimbal-range-{language}.png'
 result=json.loads(subprocess.check_output([str(cli),'ui-capture','--surface','gimbal-range-fixture',
  '--appearance','light' if language=='en' else 'dark','--language',language,'--output',str(path)],text=True))
 assert result.get('simulation') is True and result['width']==680 and 160<=result['height']<=420,result
 assert result['cameraPreviewIncluded'] is False and result['importedImageIncluded'] is False,result
 results.append(result)
for language in ['en','zh-Hant','zh-Hans']:
 for state in ['available','stale','manual']:
  path=out/f'settings-readback-{state}-{language}.png'
  result=json.loads(subprocess.check_output([str(cli),'ui-capture','--surface','settings-readback-fixture','--page',state,
   '--appearance','light' if language=='en' else 'dark','--language',language,'--output',str(path)],text=True))
  assert result.get('simulation') is True and result['width']==680 and 180<=result['height']<=700,result
  results.append(result)
(out/'captures.json').write_text(json.dumps(results,indent=2)+'\n')
assert persisted_language()==original_language,'UI capture changed the saved interface language'
print(json.dumps({'interfaceChecks':checks,'captures':len(results),'languagePreferenceUnchanged':True,'directory':str(out)},indent=2))
