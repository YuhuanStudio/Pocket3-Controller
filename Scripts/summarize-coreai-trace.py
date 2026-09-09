#!/usr/bin/env python3
"""Export only the target app's profiling summary, excluding process environment."""
import argparse,collections,json,pathlib,statistics,xml.etree.ElementTree as E
p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);a=p.parse_args()
def load(name):
 root=E.parse(a.directory/name).getroot();ids={e.get('id'):e for e in root.iter() if e.get('id')}
 def resolve(e):
  while e.get('ref'):e=ids[e.get('ref')]
  return e
 def text(e):
  e=resolve(e);return e.get('fmt') or e.text or ''
 return list(root.iter('row')),resolve,text
rows,resolve,text=load('coreai-launch-profile.xml');events=collections.defaultdict(list);intervals=[];target=None
for row in rows:
 cells=list(row);proc=resolve(cells[2]);pid=next(proc.iter('pid'),None)
 if pid is not None:target=int(pid.text)
 name=text(cells[15]);duration=int(resolve(cells[1]).text or 0)
 events[name].append(duration/1e6)
 if name=='call.MPSGraph':intervals.append((int(resolve(cells[0]).text),int(resolve(cells[0]).text)+duration))
gpu,resolve,text=load('coreai-launch-gpu.xml');matched=0;overlaps=0;devices=set();channels=collections.Counter()
for row in gpu:
 cells=list(row);proc=resolve(cells[10]);pid=next(proc.iter('pid'),None)
 if pid is None or int(pid.text)!=target:continue
 matched+=1;devices.add(text(cells[11]));channels[text(cells[2])]+=1
 start=int(resolve(cells[0]).text or 0);end=start+int(resolve(cells[1]).text or 0)
 if any(start < hi and end > lo for lo,hi in intervals):overlaps+=1
ane,_,_=load('coreai-launch-ane.xml')
report={'target':'Pocket3MCP','coreAIEvents':{k:{'count':len(v),'medianMilliseconds':statistics.median(v)} for k,v in events.items()},'targetGPUIntervals':matched,'gpuIntervalsOverlappingCoreAIMPSGraph':overlaps,'gpuDevices':sorted(devices),'gpuChannels':dict(channels),'aneIntervalsInTrace':len(ane),'interpretation':'Core AI MPSGraph calls and target-process Metal GPU work observed. No ANE interval observed in this recording; this is not a universal no-ANE claim.','cameraUsed':False,'build':'Debug','environmentExcluded':True}
(a.directory/'coreai-summary.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
