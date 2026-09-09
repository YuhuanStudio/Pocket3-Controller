#!/usr/bin/env python3
import argparse,json,pathlib,plistlib,statistics,subprocess,time
parser=argparse.ArgumentParser();parser.add_argument('--output',default='artifacts/evaluation/perception-release');args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];app=root/'dist/Pocket 3 Controller.app';cli=app/'Contents/MacOS/pocket3';image=root/'artifacts/evaluation/fixtures/coco-sample.png';out=root/args.output;out.mkdir(parents=True,exist_ok=True)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());configuration=info.get('Pocket3BuildConfiguration','unknown')
assert configuration=='release','Performance must be measured with the packaged Release app'
results=[]
for mode in ['cpu','gpu','neuralEngine','automatic']:
 trials=[]
 for iteration in range(6):
  start=time.monotonic();p=subprocess.run([str(cli),'evaluate-perception','--image',str(image),'--compute',mode],text=True,capture_output=True,timeout=140)
  result=json.loads(p.stdout) if p.returncode==0 else {'error':p.stderr}
  trials.append({'iteration':iteration,'wallSeconds':time.monotonic()-start,'result':result})
 summary={'buildConfiguration':configuration,'modeRequested':mode,'firstMeasuredTrial':trials[0],'warmTrials':trials[1:]}
 warm=[r['result']['inferenceSeconds'] for r in trials[1:] if 'inferenceSeconds' in r['result']]
 summary['warmMedianSeconds']=statistics.median(warm) if warm else None
 results.append(summary);(out/(mode+'.json')).write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
 print(mode,summary['warmMedianSeconds'],flush=True)
(out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
print('Preferred GPU/Neural Engine is a request; actual execution needs the Instruments trace.',flush=True)
