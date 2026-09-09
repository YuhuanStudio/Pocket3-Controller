#!/usr/bin/env python3
"""Verify advertised camera modes on an already authorized development App."""
import argparse,json,pathlib,statistics,subprocess,time,uuid
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary',default='dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('artifacts/capture-formats'))
p.add_argument('--mode',action='append',help='Limit to exact advertised IDs; repeat to select multiple')
a=p.parse_args();out=a.output/str(uuid.uuid4());out.mkdir(parents=True)
def call(*args,timeout=135):
 r=subprocess.run([a.binary,*args],capture_output=True,text=True,timeout=timeout)
 if r.returncode:
  try:error=json.loads(r.stderr)
  except ValueError:error={'message':r.stderr}
  raise RuntimeError(json.dumps(error,ensure_ascii=False))
 return json.loads(r.stdout)
initial=call('status')
if initial.get('permission')!='authorized':raise SystemExit('Grant the App camera permission before running the format matrix.')
device_id=(initial.get('selected')or{}).get('id')
if not device_id:raise SystemExit('Explicitly connect the intended camera once before running the matrix.')
modes=call('formats',device_id)
if a.mode:
 wanted=set(a.mode);modes=[m for m in modes if m['id'] in wanted]
 if {m['id'] for m in modes}!=wanted:raise SystemExit('A selected format was not advertised by this camera.')
report={'deviceID':device_id,'scope':'Actual App format negotiation; no direction/preset commands or stored audio','results':[],'status':'running'}
def save(): (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
save()
try:
 for mode in modes:
  entry={'requested':mode,'passed':False};report['results'].append(entry);save()
  try:
   started=time.monotonic();state=call('validation-connect','--mode',mode['id'])
   entry['connectSeconds']=time.monotonic()-started
   if state['selected']['id']!=device_id:raise RuntimeError('Selected device changed; aborting matrix.')
   session=state['capture']['sessionID'];samples=[]
   time.sleep(10)
   for _ in range(5):
    state=call('status',timeout=20);capture=state['capture'];frame=capture.get('frame')or{}
    samples.append({'frames':capture['frames'],'fps':capture['recentFPS'],'age':capture.get('age'),'width':frame.get('width'),'height':frame.get('height'),'session':capture['sessionID']})
    if state['selected']['id']!=device_id or capture['sessionID']!=session:raise RuntimeError('Camera session changed during a format trial.')
    time.sleep(.5)
   fps=statistics.median(x['fps'] for x in samples)
   entry.update(samples=samples,medianFPS=fps,fpsTolerance=max(1,mode['frameRate']*.05))
   assert all(x['width']==mode['width'] and x['height']==mode['height'] and isinstance(x['age'],(int,float)) and 0<=x['age']<1 for x in samples),'Received shape/freshness mismatch'
   assert samples[-1]['frames']>samples[0]['frames'],'Video did not advance'
   assert abs(fps-mode['frameRate'])<=entry['fpsTolerance'],'Measured rate does not match requested rate'
   call('validation-setup','--access','observe')
   entry['image']=call('snapshot','--max-dimension','960','--output',str(out/(mode['id']+'.jpg')))
   entry['passed']=True
  except (RuntimeError,AssertionError,subprocess.TimeoutExpired) as error:
   entry['error']=str(error)
   state=call('status')
   if not any(d['id']==device_id for d in state.get('devices',[])):
    report['status']='interrupted';save();raise RuntimeError('Camera was disconnected; no further modes attempted.')
  save();print(json.dumps({'mode':mode['id'],'passed':entry['passed'],'fps':entry.get('medianFPS'),'error':entry.get('error')},ensure_ascii=False),flush=True)
 report['status']='completed';report['streamMetricPasses']=[r['requested']['id'] for r in report['results'] if r['passed']];report['contentReview']='pending: inspect orientation, padding, and scene quality independently of stream metrics'
except BaseException as error:
 report['status']='interrupted';report['error']=str(error)
 raise
finally:
 # Release the test stream and access. Do not reconnect or move to restore.
 try:call('validation-pause')
 except Exception:pass
 save()
print(json.dumps({'status':report['status'],'streamMetricPasses':report.get('streamMetricPasses',[]),'report':str(out/'result.json')},ensure_ascii=False,indent=2))
