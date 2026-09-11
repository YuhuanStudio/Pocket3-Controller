#!/usr/bin/env python3
"""Bounded Pocket 3 camera-side H.264/HEVC validation; defaults to no-op."""
import argparse
import json
import pathlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default='dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('artifacts/video-compression'))
parser.add_argument('--target', choices=('h264', 'hevc'), default='hevc')
parser.add_argument('--allow-change', action='store_true', help='Permit one changing 02/AB command; no automatic restore')
args = parser.parse_args()

target_raw = {'h264': 0, 'hevc': 1}[args.target]
run = args.output / str(uuid.uuid4())
run.mkdir(parents=True)

def call(*values, timeout=125):
    completed = subprocess.run([args.binary, *values], capture_output=True, text=True, timeout=timeout)
    if completed.returncode:
        try:
            error = json.loads(completed.stderr)
        except ValueError:
            error = {'message': completed.stderr[-1024:]}
        raise RuntimeError(json.dumps(error, ensure_ascii=False))
    return json.loads(completed.stdout)

report = {
    'scope': 'Pocket 3 camera-side compression only; no USB codec claim, no media export, no Wi-Fi or gimbal command',
    'target': args.target, 'allowChange': args.allow_change, 'cameraImagesStored': False,
    'startedAt': time.time(), 'status': 'running'
}

def save():
    (run / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

try:
    status = call('status', '--json')
    capture = status.get('capture', {})
    capture_session = capture.get('sessionID')
    frame = capture.get('frame') or {}
    if status.get('phase') != 'ready' or not capture_session or frame.get('sessionID') != capture_session:
        raise RuntimeError('Capture must be ready with a current frame before any camera-side validation')
    wireless = call('validation-wireless-status').get('bluetooth', {})
    ble_session, peripheral = wireless.get('sessionID'), wireless.get('selectedPeripheralID')
    if wireless.get('phase') != 'gattPaired' or not ble_session or not peripheral:
        raise RuntimeError('Exact paired BLE session/peripheral is required')
    readback = call('validation-wireless-property', '--property', 'cam_video_param_v2')
    observed = readback.get('observed')
    video = (((observed or {}).get('readOnlyValue') or {}).get('videoParameters') or {}).get('_0')
    if not observed or not video or video.get('compressionRaw') not in (0, 1):
        raise RuntimeError('Complete known cam_video_param_v2 readback is required')
    current = video['compressionRaw']
    report.update(captureSessionID=capture_session, bleSessionID=ble_session,
                  peripheralID=peripheral, baseline=observed, currentCompressionRaw=current,
                  propertyQuery={'localSubmitted': readback.get('localSubmitted'),
                                 'ackReceived': readback.get('ackReceived'),
                                 'propertyReceived': readback.get('propertyReceived')})
    if not args.allow_change and current != target_raw:
        raise RuntimeError('No-op mode refuses a different target; use --allow-change only after reviewing a restore plan')
    command = {'value': {'videoCompression': {'_0': target_raw}}}
    result = call('validation-wireless-setting', '--session', ble_session,
        '--peripheral', peripheral, '--capture-session', capture_session,
        '--property', 'cam_video_param_v2', '--value-json', json.dumps(command),
        '--baseline-json', json.dumps(observed))
    report['writer'] = result
    if not args.allow_change:
        if result.get('noOp') is not True or result.get('localSubmitted') is not False or result.get('end') != 'noOp':
            raise RuntimeError('No-op validation must prove noOp=true, localSubmitted=false and end=noOp')
    report['status'] = 'complete'
except BaseException as error:
    report['status'] = 'failed'
    report['error'] = str(error)
    raise
finally:
    report['finishedAt'] = time.time()
    save()

print(json.dumps({'status': report['status'], 'report': str(run / 'result.json')}, ensure_ascii=False, indent=2))
