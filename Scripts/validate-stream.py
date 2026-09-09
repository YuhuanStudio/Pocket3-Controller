#!/usr/bin/env python3
"""Record a bounded real-camera stream check after the operator connects it."""
import argparse,json,pathlib,subprocess,time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds',type=int,default=1800)
parser.add_argument('--audio',action='store_true',help='Include the camera microphone; required for full audiovisual acceptance')
parser.add_argument('--binary',default='dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
parser.add_argument('--output',type=pathlib.Path,default=pathlib.Path('artifacts/hardware-stream'))
args=parser.parse_args()
if not 1<=args.seconds<=1800:parser.error('--seconds must be 1–1800')
def call(*values):
 result=subprocess.run([args.binary,*values],capture_output=True,text=True,timeout=25)
 if result.returncode:raise RuntimeError(result.stderr)
 return json.loads(result.stdout)
args.output.mkdir(parents=True,exist_ok=True)
command=['validation-stream-start','--seconds',str(args.seconds)]
if args.audio:command+=['--audio']
call(*command)
last_count=-1
run_directory=None
try:
 while True:
  value=call('validation-stream-status');report=value.get('report') or {}
  if run_directory is None and report.get('id'):
   run_directory=args.output/report['id'];run_directory.mkdir(parents=True,exist_ok=False)
  count=report.get('sampleCount',0)
  if count!=last_count and run_directory is not None:
   with (run_directory/'samples.jsonl').open('a') as file:file.write(json.dumps(report.get('latestSample'))+'\n')
   last_count=count
   print(f"{report.get('elapsedSeconds',0):.0f}/{args.seconds}s · {len(report.get('failures',[]))} failed conditions",flush=True)
  if not value['running']:break
  time.sleep(1)
except (KeyboardInterrupt,Exception):
 try:call('validation-stream-cancel')
 finally:raise
finally:
 try:
  deadline=time.monotonic()+10
  while True:
   final=call('validation-stream-status','--full')
   if not final['running'] or time.monotonic()>=deadline:break
   time.sleep(.1)
  destination=run_directory or args.output
  (destination/'report.json').write_text(json.dumps(final,ensure_ascii=False,indent=2)+'\n')
 except Exception:pass
if not report.get('passed'):raise SystemExit('Stream validation did not pass; inspect the report.')
if not report.get('fullAcceptanceRun'):print('Passed only the requested short/video-only check; full 30-minute audiovisual acceptance is still pending.')
