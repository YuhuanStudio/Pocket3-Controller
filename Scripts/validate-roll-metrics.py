#!/usr/bin/env python3
"""One reversible UVC Roll step with readback; never stores camera images."""
import argparse, json, pathlib, subprocess, uuid

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=False)
cli = root / 'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3'

def call(*values):
    p = subprocess.run([str(cli), *map(str, values)], capture_output=True, text=True, timeout=20)
    if p.returncode: raise RuntimeError(p.stderr.strip())
    return json.loads(p.stdout)

report = {'runID': str(uuid.uuid4()), 'cameraImagesStored': False, 'physicalMotionVerified': False,
          'scope': 'one raw Roll step/readback/restore; not physical calibration or moving-stop validation'}
attempted = False
try:
    status = call('status', '--json')
    assert status.get('phase') == 'ready' and status.get('capture', {}).get('age', 10) < 1
    session = status['capture']['sessionID']; report['sessionID'] = session
    before = call('roll-status', '--session', session); report['before'] = before
    low, high, step, initial = (before.get(key) for key in ('minimum', 'maximum', 'step', 'current'))
    assert before.get('writable') and all(type(v) is int for v in (low, high, step, initial)) and step > 0
    target = initial + step if initial + step <= high else initial - step
    assert low <= target <= high and target != initial
    report['target'] = target; attempted = True
    call('validation-setup', '--access', 'observe')
    report['movement'] = call('validation-roll', '--raw', target, '--session', session)
    assert report['movement'].get('verified') and report['movement'].get('observed') == target
except Exception as error:
    report['failure'] = str(error)
finally:
    if attempted:
        try:
            report['stop'] = call('stop')
            assert report['stop'].get('verified')
            if not report.get('failure'):
                report['restoration'] = call('validation-roll', '--raw', report['before']['current'], '--session', report['sessionID'])
                report['restored'] = report['restoration'].get('verified') and report['restoration'].get('observed') == report['before']['current']
            report['finalStop'] = call('stop')
        except Exception as error: report['cleanupFailure'] = str(error)
    try: call('validation-setup', '--access', 'manual')
    except Exception as error: report['manualCleanupFailure'] = str(error)
    report['passed'] = bool(not report.get('failure') and not report.get('cleanupFailure') and report.get('restored') and report.get('finalStop', {}).get('verified'))
    (args.output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'failure': report.get('failure'), 'cleanupFailure': report.get('cleanupFailure'), 'cameraImagesStored': False, 'physicalMotionVerified': False}))
