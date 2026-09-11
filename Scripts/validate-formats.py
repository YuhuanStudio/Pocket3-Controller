#!/usr/bin/env python3
"""Verify advertised camera modes without storing frames or changing camera controls."""
import argparse,json,pathlib,statistics,subprocess,time,uuid
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary',default='dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('artifacts/capture-formats'))
p.add_argument('--mode',action='append',help='Limit to exact advertised IDs; repeat to select multiple')
p.add_argument('--pixel-format',choices=('nv12','uyvy'),default='nv12')
p.add_argument('--settle-seconds',type=float,default=4.0)
p.add_argument('--samples',type=int,default=5)
a=p.parse_args();out=a.output/str(uuid.uuid4());out.mkdir(parents=True)
if not 1 <= a.samples <= 20: raise SystemExit('--samples must be in 1...20')
if not 1 <= a.settle_seconds <= 30: raise SystemExit('--settle-seconds must be in 1...30')
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
else:
 modes=[m for m in modes if a.pixel_format in {item['id'] for item in m.get('supportedInputFormats',[])}]
report={'deviceID':device_id,'pixelFormat':a.pixel_format,
 'scope':'Actual App format negotiation and stream metrics only; no stored frames/audio, camera controls, BLE, body settings or Wi-Fi',
 'cameraImagesStored':False,'cameraWritesSent':False,'results':[],'status':'running'}
def save(): (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
save()
try:
    for mode in modes:
        entry={'requested':mode,'passed':False};report['results'].append(entry);save()
        try:
            formats={item['id'] for item in mode.get('supportedInputFormats',[])}
            if a.pixel_format not in formats: raise RuntimeError(f'{a.pixel_format} is not advertised for {mode["id"]}')
            started=time.monotonic();state=call('validation-connect','--mode',mode['id'],'--pixel-format',a.pixel_format)
            entry['connectSeconds']=time.monotonic()-started
            if state['selected']['id']!=device_id:raise RuntimeError('Selected device changed; aborting matrix.')
            if state.get('requestedMode',{}).get('width')!=mode['width'] or state.get('requestedMode',{}).get('height')!=mode['height'] or state.get('requestedPixelFormat')!=a.pixel_format:
                raise RuntimeError('Service did not retain the exact requested mode and pixel format.')
            session=state['capture']['sessionID'];samples=[]
            time.sleep(a.settle_seconds)
            for _ in range(a.samples):
                state=call('status',timeout=20);capture=state['capture'];frame=capture.get('frame')or{}
                samples.append({'frames':capture['frames'],'fps':capture['recentFPS'],'age':capture.get('age'),
                    'width':frame.get('width'),'height':frame.get('height'),'session':capture['sessionID'],
                    'deviceID':frame.get('deviceID'),'inputPixelFormat':frame.get('inputPixelFormat'),
                    'inputPixelFormatFourCC':frame.get('inputPixelFormatFourCC'),'outputPixelFormat':frame.get('outputPixelFormat'),
                    'rotationDegrees':frame.get('rotationDegrees'),'mirrored':frame.get('mirrored')})
                if state['selected']['id']!=device_id or capture['sessionID']!=session:raise RuntimeError('Camera session changed during a format trial.')
                time.sleep(.5)
            fps=statistics.median(x['fps'] for x in samples)
            entry.update(samples=samples,medianFPS=fps,fpsTolerance=max(1,mode['frameRate']*.05))
            shape_ok=all(x['width']==mode['width'] and x['height']==mode['height'] and x['deviceID']==device_id
                and x['inputPixelFormat']==a.pixel_format and x['outputPixelFormat']=='BGRA'
                and isinstance(x['rotationDegrees'],int) and isinstance(x['mirrored'],bool)
                and isinstance(x['age'],(int,float)) and 0<=x['age']<1 for x in samples)
            if not shape_ok: raise RuntimeError('Received shape/format/freshness mismatch')
            if len(samples)>1 and samples[-1]['frames']<=samples[0]['frames']: raise RuntimeError('Video did not advance')
            if abs(fps-mode['frameRate'])>entry['fpsTolerance']: raise RuntimeError('Measured rate does not match requested rate')
            entry['passed']=True
        except (RuntimeError,subprocess.TimeoutExpired) as error:
            entry['error']=str(error)
            state=call('status')
            if not any(d['id']==device_id for d in state.get('devices',[])):
                report['status']='interrupted';save();raise RuntimeError('Camera was disconnected; no further modes attempted.')
        save();print(json.dumps({'mode':mode['id'],'passed':entry['passed'],'fps':entry.get('medianFPS'),'error':entry.get('error')},ensure_ascii=False),flush=True)
    report['status']='completed';report['streamMetricPasses']=[r['requested']['id'] for r in report['results'] if r['passed']]
    report['contentReview']='not performed: metrics-only mode stores no camera image; orientation and padding require a separately authorized visual review'
except BaseException as error:
 report['status']='interrupted';report['error']=str(error)
 raise
finally:
 # Release the test stream and access. Do not reconnect or move to restore.
 try:call('validation-pause')
 except Exception:pass
 save()
print(json.dumps({'status':report['status'],'streamMetricPasses':report.get('streamMetricPasses',[]),'report':str(out/'result.json')},ensure_ascii=False,indent=2))
