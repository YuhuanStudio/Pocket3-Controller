#!/usr/bin/env python3
"""Repeated live status reads cover the autorelease-pool startup crash."""
from pathlib import Path
import json
import subprocess
import time
import argparse

p=argparse.ArgumentParser()
p.add_argument("--seconds", type=int, default=60)
p.add_argument("--binary", default="dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
p.add_argument("--output", default="artifacts/startup-regression.json")
a=p.parse_args()
records=[]
start=time.monotonic()
while time.monotonic()-start < a.seconds:
    r=subprocess.run([a.binary,"status"],capture_output=True,text=True,timeout=15)
    if r.returncode:raise RuntimeError(r.stderr)
    d=json.loads(r.stdout)
    assert d['phase']=='ready', d
    assert d.get('gimbal') is not None, d
    assert d['gimbal']['position']['pan'] is not None
    assert 'pan-tilt-abs' in d['gimbal']['controls']
    assert d['capture'].get('age',99)<1
    records.append({'seconds':time.monotonic()-start,'frames':d['capture']['frames'],'session':d['capture']['sessionID'],'position':d['gimbal']['position'],'age':d['capture']['age']})
    time.sleep(0.2)
assert len(records)>=10
assert len({r['session'] for r in records})==1
assert records[-1]['frames'] > records[0]['frames']
out=Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
report={'passed':True,'durationSeconds':time.monotonic()-start,'statusReads':len(records),'records':records}
out.write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='records'},indent=2))
