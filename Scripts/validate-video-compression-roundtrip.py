#!/usr/bin/env python3
"""Validate one Pocket 3 H.264 -> original-codec round trip.

The default is a dry-run.  --execute is deliberately required before the
single H.264 change may be submitted.  This script never joins Wi-Fi, moves
the gimbal, records media, or retries a camera-side write.
"""
import argparse
import json
import pathlib
import subprocess
import sys
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default='dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('artifacts/video-compression-roundtrip'))
parser.add_argument('--execute', action='store_true', help='Permit exactly one H.264 change and one restore.')
args = parser.parse_args()

run = args.output / str(uuid.uuid4())
run.mkdir(parents=True)
report = {
    'scope': 'Camera-side compression only; no USB codec claim, Wi-Fi, gimbal command, focus command, or media export',
    'cameraImagesStored': False,
    'execute': args.execute,
    'writesPermitted': 2 if args.execute else 0,
    'status': 'running',
    'startedAt': time.time(),
}
switch_started = False
restore_started = False

def save():
    (run / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

def call(*values, timeout=125):
    completed = subprocess.run([args.binary, *values], capture_output=True, text=True, timeout=timeout)
    if completed.returncode:
        try:
            detail = json.loads(completed.stderr)
        except ValueError:
            detail = {'message': completed.stderr[-1024:]}
        raise RuntimeError(json.dumps(detail, ensure_ascii=False))
    return json.loads(completed.stdout)

def read_video():
    result = call('validation-wireless-property', '--property', 'cam_video_param_v2')
    observed = result.get('observed')
    video = (((observed or {}).get('readOnlyValue') or {}).get('videoParameters') or {}).get('_0')
    raw = video.get('compressionRaw') if video else None
    if not observed or raw not in (0, 1):
        raise RuntimeError('Complete known cam_video_param_v2 readback is required')
    return observed, raw, result

def write(compression_raw, baseline, label):
    command = {'value': {'videoCompression': {'_0': compression_raw}}}
    result = call('validation-wireless-setting', '--session', report['bleSessionID'],
        '--peripheral', report['peripheralID'], '--capture-session', report['captureSessionID'],
        '--property', 'cam_video_param_v2', '--value-json', json.dumps(command),
        '--baseline-json', json.dumps(baseline))
    report['writes'].append({'label': label, 'targetRaw': compression_raw, 'result': result})
    # A write is accepted only when the app's bounded writer saw both ACK and
    # matching post-submission readback.  Do not issue a duplicate write.
    if result.get('end') != 'applied' or result.get('localSubmitted') is not True:
        raise RuntimeError(label + ' did not reach applied; no retry is permitted')

try:
    status = call('status', '--json')
    capture = status.get('capture', {})
    frame = capture.get('frame') or {}
    capture_session = capture.get('sessionID')
    if status.get('phase') != 'ready' or not capture_session or frame.get('sessionID') != capture_session:
        raise RuntimeError('Capture must be ready with a current frame before validation')
    wireless = call('validation-wireless-status').get('bluetooth', {})
    if wireless.get('phase') != 'gattPaired' or not wireless.get('sessionID') or not wireless.get('selectedPeripheralID'):
        raise RuntimeError('Exact paired BLE session/peripheral is required')
    report.update(captureSessionID=capture_session, bleSessionID=wireless['sessionID'],
                  peripheralID=wireless['selectedPeripheralID'], writes=[])
    baseline, original_raw, query = read_video()
    report.update(baseline=baseline, originalCompressionRaw=original_raw,
                  baselineQuery={'localSubmitted': query.get('localSubmitted'), 'ackReceived': query.get('ackReceived'),
                                 'propertyReceived': query.get('propertyReceived')})
    if original_raw != 1:
        raise RuntimeError('This controlled round trip currently starts only from the known HEVC baseline')
    if not args.execute:
        report['status'] = 'dry_run_complete'
    else:
        switch_started = True
        write(0, baseline, 'switch_to_h264')
        changed, observed_raw, changed_query = read_video()
        report['afterH264'] = changed
        report['afterH264Query'] = {'localSubmitted': changed_query.get('localSubmitted'),
                                    'ackReceived': changed_query.get('ackReceived'),
                                    'propertyReceived': changed_query.get('propertyReceived')}
        if observed_raw != 0:
            raise RuntimeError('H.264 was not independently observed; do not issue restore blindly')
        restore_started = True
        write(original_raw, changed, 'restore_original')
        restored, restored_raw, restored_query = read_video()
        report['restored'] = restored
        report['restoredQuery'] = {'localSubmitted': restored_query.get('localSubmitted'),
                                   'ackReceived': restored_query.get('ackReceived'),
                                   'propertyReceived': restored_query.get('propertyReceived')}
        if restored_raw != original_raw or restored != baseline:
            raise RuntimeError('Exact original compression baseline was not restored')
        report['status'] = 'complete'
except BaseException as error:
    # A transport timeout after a submission does not prove that the camera
    # ignored it.  Make one read-only observation; restore only if that
    # observation proves H.264 is active and no restore was already sent.
    if args.execute and switch_started and not restore_started and 'originalCompressionRaw' in report:
        try:
            emergency, emergency_raw, emergency_query = read_video()
            report['failureReadback'] = emergency
            report['failureReadbackQuery'] = {
                'localSubmitted': emergency_query.get('localSubmitted'),
                'ackReceived': emergency_query.get('ackReceived'),
                'propertyReceived': emergency_query.get('propertyReceived'),
            }
            if emergency_raw == 0:
                restore_started = True
                write(report['originalCompressionRaw'], emergency, 'restore_after_unconfirmed_switch')
                restored, restored_raw, _ = read_video()
                report['failureRestoreReadback'] = restored
                report['failureRestoreVerified'] = restored_raw == report['originalCompressionRaw'] and restored == report['baseline']
        except BaseException as recovery_error:
            report['recoveryError'] = str(recovery_error)
    report['status'] = 'failed'
    report['error'] = str(error)
    raise
finally:
    report['finishedAt'] = time.time()
    save()

print(json.dumps({'status': report['status'], 'report': str(run / 'result.json')}, ensure_ascii=False, indent=2))
