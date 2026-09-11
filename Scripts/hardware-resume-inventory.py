#!/usr/bin/env python3
"""Wait for one Pocket 3 USB device and record its read-only App inventory.

This never starts preview capture, Bluetooth, Wi-Fi, gimbal/zoom/roll movement,
body settings, audio, or snapshots. It stores only status/format scalar JSON.
"""
import argparse, datetime, json, pathlib, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=pathlib.Path, default=ROOT / 'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
p.add_argument('--wait-seconds', type=int, default=0)
p.add_argument('--output', type=pathlib.Path, default=ROOT / 'artifacts/hardware-resume-inventory')
a = p.parse_args()
if not 0 <= a.wait_seconds <= 600: p.error('--wait-seconds must be 0...600')
if not a.binary.is_file(): p.error('Pocket 3 CLI binary does not exist')

def call(*args):
    r = subprocess.run([str(a.binary), *args], capture_output=True, text=True, timeout=25)
    if r.returncode: raise RuntimeError(r.stderr.strip() or 'CLI request failed')
    return json.loads(r.stdout)

until = time.monotonic() + a.wait_seconds
while True:
    status = call('status')
    devices = status.get('devices', [])
    if len(devices) == 1:
        break
    if time.monotonic() >= until:
        raise SystemExit('Expected exactly one Pocket 3 device; no capture was started.')
    time.sleep(.5)
device = devices[0]
formats = call('formats', device['id'])
report = {
    'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'readOnly': True, 'captureStarted': False, 'bluetoothStarted': False,
    'networkChanged': False, 'mediaPersisted': False, 'writesSent': False,
    'device': device, 'power': status.get('power'), 'phase': status.get('phase'),
    'captureFrames': status.get('capture', {}).get('frames'),
    'formats': formats,
    'formatCounts': {'total': len(formats), 'portrait': sum(x.get('portrait') is True for x in formats),
                     'fourK': sum(x.get('width') == 3840 for x in formats)},
    'interpretation': 'Formats are advertised_only. This inventory does not establish stream delivery or physical control.'
}
a.output.mkdir(parents=True, exist_ok=True)
out = a.output / f"inventory-{int(time.time())}.json"
out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'report': str(out), 'deviceID': device['id'], 'formatCounts': report['formatCounts']}, ensure_ascii=False))
