#!/usr/bin/env python3
"""Twenty bounded, metrics-only USB trajectory trials; stop after first failure."""
import argparse, json, pathlib, subprocess, sys, uuid

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=False)
runner = root / 'Scripts/validate-usb-trajectory-metrics.py'
directions = ['right', 'left', 'up', 'down'] * 5
report = {'runID': str(uuid.uuid4()), 'trialCount': len(directions), 'cameraImagesStored': False,
          'physicalMotionVerified': False, 'trials': [], 'status': 'running'}

for index, direction in enumerate(directions, start=1):
    trial = args.output / f'{index:02d}-{direction}'
    result = subprocess.run([sys.executable, str(runner), '--direction', direction, '--output', str(trial)],
                            capture_output=True, text=True, timeout=30)
    entry = {'index': index, 'direction': direction, 'exitCode': result.returncode, 'directory': str(trial)}
    path = trial / 'result.json'
    if path.exists():
        data = json.loads(path.read_text())
        entry.update(completed=data.get('completedUSBReadbackExperiment'), failure=data.get('probe', {}).get('failure') or data.get('driverError'),
                     samples=len(data.get('probe', {}).get('samples', [])), stopVerified=data.get('probe', {}).get('stop', {}).get('verified'))
    report['trials'].append(entry)
    if result.returncode or not entry.get('completed') or entry.get('samples') != 24 or entry.get('stopVerified') is not True:
        report['status'] = 'failed'; report['failedTrial'] = index; break
else:
    report['status'] = 'complete'

report['passed'] = report['status'] == 'complete' and len(report['trials']) == 20
(args.output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'passed': report['passed'], 'completedTrials': len(report['trials']),
                  'failedTrial': report.get('failedTrial'), 'cameraImagesStored': False, 'physicalMotionVerified': False}))
raise SystemExit(0 if report['passed'] else 1)
