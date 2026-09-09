#!/usr/bin/env python3
"""Ask the running app's local model; camera ownership stays in the app."""
import argparse,json,pathlib,subprocess,sys
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('question');p.add_argument('--engine',choices=['apple','mlx'],default='apple')
p.add_argument('--app',type=pathlib.Path,default=pathlib.Path('/Applications/Pocket 3 MCP.app'))
p.add_argument('--fixture',type=pathlib.Path,help='Offline evaluation image; requires the app to be launched with --hardware-validation')
a=p.parse_args();cli=a.app/'Contents/MacOS/pocket3'
command=[str(cli),'evaluate-image' if a.fixture else 'ask','--engine',a.engine,'--question',a.question]
if a.fixture:command+=['--image',str(a.fixture.resolve())]
process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:stdout,stderr=process.communicate(timeout=125)
except (KeyboardInterrupt,subprocess.TimeoutExpired):
    # Closing the helper's connection cancels this request on the app side.
    process.terminate();process.wait(timeout=5);raise SystemExit('Observation cancelled')
if process.returncode:raise SystemExit(stderr.strip())
reply=json.loads(stdout)
print(json.dumps(reply,ensure_ascii=False,indent=2))
