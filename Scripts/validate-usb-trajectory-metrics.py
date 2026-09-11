#!/usr/bin/env python3
"""One bounded USB trajectory probe that never stores camera images."""
import argparse
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--direction', choices=['left', 'right', 'up', 'down'], required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
cli = root / 'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3'

def call(*values):
    result = subprocess.run([str(cli), *values], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)

report = {'direction': args.direction, 'cameraImagesStored': False, 'physicalMotionVerified': False}
probe_started = False
try:
    call('validation-setup', '--access', 'observe')
    before = call('status', '--json')
    report['before'] = {key: before.get(key) for key in ('phase', 'capture', 'gimbal')}
    origin = before['gimbal']['position']
    probe_started = True
    report['probe'] = call('validation-trajectory-probe', '--direction', args.direction,
        '--expected-pan-raw', str(origin['pan']), '--expected-tilt-raw', str(origin['tilt']))
except Exception as error:
    report['driverError'] = str(error)
finally:
    if probe_started and 'probe' not in report:
        try: report['cleanupStop'] = call('stop')
        except Exception as error: report['cleanupError'] = str(error)
    try:
        call('validation-setup', '--access', 'manual')
        after = call('status', '--json')
        report['after'] = {key: after.get(key) for key in ('phase', 'capture', 'gimbal')}
    except Exception as error: report['finalStatusError'] = str(error)
    probe = report.get('probe', {})
    report['completedUSBReadbackExperiment'] = (
        'driverError' not in report and not probe.get('failure') and len(probe.get('samples', [])) == 24
        and (probe.get('stop') or {}).get('verified') is True
    )
    (args.output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'output': str(args.output), 'samples': len(probe.get('samples', [])),
        'failure': probe.get('failure') or report.get('driverError'),
        'completedUSBReadbackExperiment': report['completedUSBReadbackExperiment'],
        'cameraImagesStored': False, 'physicalMotionVerified': False}, ensure_ascii=False))
