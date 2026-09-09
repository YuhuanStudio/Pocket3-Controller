#!/usr/bin/env python3
"""Run actual MLX and Core AI inference from a copied app with .build hidden."""
import json,os,pathlib,subprocess,tempfile,time
root=pathlib.Path(__file__).resolve().parents[1];app=root/'dist/Pocket 3 Controller.app';build=root/'.build';hidden=root/'.build.portable-inference'
if hidden.exists():raise SystemExit('Restore the previous hidden build directory first.')
subprocess.run(['osascript','-e','tell application id "studio.yuhuan.Pocket3Bridge" to quit'],check=True,timeout=30)
report={'buildTreeHidden':True,'cameraUsed':False,'checks':{}}
with tempfile.TemporaryDirectory(prefix='p3-portable-',dir='/tmp') as directory:
 copied=pathlib.Path(directory)/'Pocket 3 Controller.app';subprocess.run(['ditto',str(app),str(copied)],check=True)
 subprocess.run(['codesign','--verify','--deep','--strict',str(copied)],check=True)
 cli=copied/'Contents/MacOS/pocket3'
 env={k:os.environ[k] for k in ['HOME','TMPDIR','LANG','LC_ALL','USER','LOGNAME'] if k in os.environ}
 env.update({'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HF_HUB_OFFLINE':'1'})
 log=(root/'artifacts/portable-inference-app.log').open('w');process=None
 build.rename(hidden)
 try:
  process=subprocess.Popen([str(copied/'Contents/MacOS/Pocket3MCP'),'--hardware-validation'],env=env,stdout=log,stderr=log)
  def call(*args):
   p=subprocess.run([str(cli),*args],capture_output=True,text=True,timeout=140)
   if p.returncode:raise RuntimeError(p.stderr)
   return json.loads(p.stdout)
  for _ in range(60):
   if process.poll() is not None:raise RuntimeError('Copied app exited during launch')
   try:call('ai-status');break
   except (RuntimeError,subprocess.TimeoutExpired):time.sleep(.2)
  else:raise RuntimeError('Copied app did not expose its bridge')
  answer=call('evaluate-image','--engine','mlx','--image',str(root/'artifacts/evaluation/fixtures/text.png'),'--question','請讀出 SERIAL 後面的序號。')
  report['mlx']=answer;report['checks']['mlxInference']='TEST-4826' in answer['answer']['answer']
  detected=call('evaluate-perception','--image',str(root/'artifacts/evaluation/fixtures/coco-sample.png'),'--compute','automatic')
  report['coreAI']=detected;report['checks']['coreAIInference']=sum(o['label']=='cat' for o in detected['objects'])==2
  unloaded=call('model-unload');report['memoryAfterUnload']=unloaded
  report['checks']['weightsReleased']=unloaded['activeMemoryBytes']<20_000_000 and unloaded['cacheMemoryBytes']==0
  report['passed']=all(report['checks'].values())
  if not report['passed']:raise RuntimeError('A copied-app inference check failed')
 except Exception as error:
  report['passed']=False;report['error']=str(error)
  raise
 finally:
  if process and process.poll() is None:
   subprocess.run(['osascript','-e','tell application id "studio.yuhuan.Pocket3Bridge" to quit'],timeout=30,check=False)
   try:process.wait(timeout=15)
   except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=10)
  hidden.rename(build);log.close()
  (root/'artifacts/portable-inference.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
  subprocess.run(['open','-n',str(app),'--args','--hardware-validation'],check=False)
print(json.dumps({'passed':report['passed'],'checks':report['checks'],'buildTreeHidden':True,'cameraUsed':False},indent=2))
