#!/usr/bin/env python3
"""Offline fault-injection regression for the live MCP zoom harness.

All RPCs and time are fake. Process creation, sockets, and real sleeps are
forbidden. The in-memory JPEG-shaped marker is synthetic; no camera image is
read, decoded, displayed, or saved. Temporary JSON evidence is deleted on exit.

Run: python3 Scripts/test-mcp-zoom-hardware.py
"""
import base64
import importlib.util
import json
import tempfile
from pathlib import Path
from contextlib import ExitStack
from types import SimpleNamespace
from unittest.mock import patch

project = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_mcp_zoom', project / 'Scripts/mcp-zoom-hardware.py')
m = importlib.util.module_from_spec(spec)
# Loading either script must also remain free of process/network side effects.
with patch('subprocess.Popen', side_effect=AssertionError('Offline test forbids subprocesses')), \
     patch('socket.socket', side_effect=AssertionError('Offline test forbids sockets')):
    spec.loader.exec_module(m)

class Clock:
    def __init__(self): self.t = 1000
    def sleep(self, seconds): self.t += seconds

class Fake:
    def __init__(self, clock, mode):
        self.clock = clock; self.mode = mode; self.current = 100
        self.names = []; self.sets = []; self.captures = 0; self.closed = False; self.close_count = 0
    def send(self, _): pass
    def close(self): self.closed = True; self.close_count += 1
    def cap(self): return dict(current=self.current, minimum=100, maximum=400, step=1, writable=True)
    def request(self, method, params, timeout=25):
        self.clock.t += .01; sent = self.clock.t
        if method == 'initialize': value = {'protocolVersion': '2025-11-25'}
        elif method == 'tools/list':
            value = {'tools': [{'name': name, 'inputSchema': {'required': ['rawValue', 'expectedSessionID'], 'additionalProperties': False, 'properties': {'rawValue': {'type': 'integer'}}}} for name in m.TOOLS]}
        else:
            name = params['name']; self.names.append(name); data = None
            if name == 'camera_status':
                session = 'changed' if self.mode == 'reconnect' and self.sets else 'session'
                data = {'phase': 'ready', 'motionActive': False, 'access': 'manual' if self.mode == 'denied' else 'control', 'selected': {'id': 'device'}, 'capture': {'sessionID': session, 'age': .01, 'frame': {'sessionID': session, 'deviceID': 'device'}}, 'gimbal': {'registryID': 'registry', 'bootSessionID': 'boot'}, 'stopValidated': False}
            elif name == 'camera_zoom_status': data = self.cap()
            elif name == 'camera_set_zoom':
                target = params['arguments']['rawValue']; self.sets.append(target)
                if self.mode == 'denied': value = {'isError': True, 'content': [{'type': 'text', 'text': json.dumps({'code': 'access_denied'})}]}
                else:
                    self.current = target
                    confirmed = self.mode != 'uncertain'
                    data = dict(target=target, observed=self.current, accepted=True, completed=confirmed, verified=confirmed, verification='stable_uvc_zoom_readback_with_advertised_tolerance', capabilities=self.cap(), toleranceRaw=1, sampleCount=4, stableDurationSeconds=.25)
            elif name == 'capture_frame':
                self.captures += 1; self.clock.t += .01
                data = {'id': 'frame-' + str(self.captures), 'sessionID': 'session', 'deviceID': 'device', 'receivedUptime': self.clock.t, 'presentationTime': self.clock.t, 'timestampSource': 'host_callback_and_avfoundation_pts', 'width': 1280, 'height': 720}
            elif name == 'stop_gimbal': data = {'accepted': True, 'completed': True, 'verified': True}
            else: raise AssertionError(name)
            if data is not None:
                value = {'structuredContent': data, 'content': [{'type': 'text', 'text': json.dumps(data)}]}
                if name == 'capture_frame': value['content'].append({'type': 'image', 'mimeType': 'image/jpeg', 'data': SYNTHETIC_IMAGE})
        self.clock.t += .01
        return value, sent, self.clock.t

original = Path.write_text
SYNTHETIC_IMAGE = base64.b64encode(b"\xff\xd8" + b"x" * 1100 + b"\xff\xd9").decode()
def main():
    cases = [('success', None), ('denied', None), ('success', 'before-set'), ('success', 'after-set'), ('success', 'final'), ('uncertain', 'cleanup-read'), ('uncertain', 'cleanup-stop'), ('reconnect', 'after-set')]
    with ExitStack() as offline:
        forbidden = [offline.enter_context(patch(name, side_effect=AssertionError('Offline test forbids ' + name)))
                     for name in ('subprocess.Popen', 'subprocess.run', 'socket.socket', 'os.system', 'time.sleep')]
        directory = offline.enter_context(tempfile.TemporaryDirectory(prefix='p3-mcp-fault-only-'))
        for mode, fault in cases:
            clock = Clock(); fake = Fake(clock, mode); triggered = [False]
            args = SimpleNamespace(output=directory, binary='/nonexistent-never-executed', zoom=True, target_raw=200, device='device', session='session', registry='registry', expected_raw=100, expect_denied=mode == 'denied')
            def failing_write(path, text, *a, **kw):
                if path.name == 'result.json.tmp':
                    value = json.loads(text)
                    calls = value.get('calls', [])
                    latest = calls[-1] if calls else {}
                    hit = ((fault == 'before-set' and latest.get('label') == 'target-zoom' and 'result' not in latest)
                        or (fault == 'after-set' and latest.get('label') == 'target-zoom' and 'result' in latest)
                        or (fault == 'cleanup-read' and latest.get('label') == 'failure-stop-binding')
                        or (fault == 'cleanup-stop' and latest.get('label') == 'failure-stop' and 'result' in latest)
                        or (fault == 'final' and value.get('status') == 'completed'))
                    triggered[0] |= hit
                    if triggered[0]: raise OSError(28, 'synthetic disk full')
                return original(path, text, *a, **kw)
            with patch.object(Path, 'write_text', failing_write):
                report, path = m.run(args, client_factory=lambda *_: fake, clock=clock)
            assert fake.closed and fake.close_count == 1, (mode, fault, 'client not closed exactly once')
            assert report['passed'] == (fault is None), (mode, fault, report)
            if fault:
                assert triggered[0] and report.get('persistenceErrors'), (mode, fault)
                assert report['status'] == 'failed'
                assert 1 <= len(report['persistenceErrors']) <= 8
            if fault == 'before-set': assert fake.sets == [] and 'stop_gimbal' not in fake.names
            elif fault == 'final': assert fake.sets == [200, 100] and report['restored'] and 'stop_gimbal' not in fake.names
            elif mode == 'reconnect': assert fake.sets == [200] and 'stop_gimbal' not in fake.names and report['cleanupUncertain']
            elif fault: assert fake.sets == [200] and fake.names.count('stop_gimbal') == 1 and report['cleanupStopConfirmed']
            if mode == 'denied':
                assert fake.captures == 0 and report['deniedInManual'] and fake.current == 100
                assert fake.sets == [200] and 'stop_gimbal' not in fake.names
            elif fault is None:
                assert fake.sets == [200, 100] and fake.captures == 3 and report['restored']
                assert fake.current == 100 and 'stop_gimbal' not in fake.names
            assert set(fake.names) <= m.TOOLS
            # Neither marker payloads nor image files may escape the fake RPC boundary.
            assert SYNTHETIC_IMAGE not in json.dumps(report)
            for saved in path.parent.iterdir():
                assert saved.name in {'result.json', 'result.json.tmp', 'stderr.log'}, saved
                assert SYNTHETIC_IMAGE not in saved.read_text()
            for call in report['calls']:
                for item in call.get('result', {}).get('content', []):
                    if item['type'] == 'image':
                        assert item['saved'] is False and 'data' not in item and 'file' not in item
            for blocked in forbidden:
                blocked.assert_not_called()
            print('PASS', mode, fault or 'no-fault', 'sets=', fake.sets, 'stop-count=', fake.names.count('stop_gimbal'))
    print('All 8 offline MCP flows passed, including 6 persistent disk-failure scenarios; no subprocess, socket, real sleep, or camera image used.')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
