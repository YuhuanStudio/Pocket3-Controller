#!/usr/bin/env python3
"""Trace one offline Core AI perception request in the already-running App.

The recorder never connects a camera, starts Bluetooth, joins a network, saves
camera media, or infers an execution device from a requested compute mode. It
records only the target App's Instruments table counts and the structured
perception reply. A zero-row trace is explicitly inconclusive.
"""
import argparse, json, pathlib, selectors, subprocess, sys, time, xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=pathlib.Path, default=ROOT / 'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
parser.add_argument('--image', type=pathlib.Path, default=ROOT / 'artifacts/evaluation/fixtures/coco-sample.png')
parser.add_argument('--compute', choices=('cpu', 'gpu', 'neuralEngine', 'automatic'), default='automatic')
parser.add_argument('--seconds', type=int, default=12)
parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'artifacts/evaluation/coreai-trace')
args = parser.parse_args()
if not 6 <= args.seconds <= 60: parser.error('--seconds must be 6...60')
if not args.binary.is_file() or not args.image.is_file(): parser.error('binary and image must exist')


def command(*values, timeout=45):
    return subprocess.run(values, capture_output=True, text=True, timeout=timeout, check=True)


def target_pid():
    values = command('pgrep', '-x', 'Pocket3MCP').stdout.split()
    if len(values) != 1:
        raise RuntimeError('Expected exactly one running Pocket3MCP App process')
    return values[0]


def export_rows(trace, index, destination):
    result = command('xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath', f'/trace-toc/run/data/table[{index}]/row', timeout=45)
    destination.write_text(result.stdout)
    return len(ET.fromstring(result.stdout).findall('.//row'))


args.output.mkdir(parents=True, exist_ok=False)
trace = args.output / 'coreai.trace'
report = {'cameraUsed': False, 'mediaPersisted': False, 'networkChanged': False, 'bluetoothStarted': False,
          'computeRequested': args.compute, 'traceSeconds': args.seconds, 'passed': False}
try:
    pid = target_pid()
    recorder = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Core AI', '--attach', pid,
        '--output', str(trace), '--time-limit', f'{args.seconds}s'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(3)
    call = command(str(args.binary), 'evaluate-perception', '--image', str(args.image), '--compute', args.compute, timeout=140)
    report['perception'] = json.loads(call.stdout)
    stdout, stderr = recorder.communicate(timeout=args.seconds + 60)
    report['xctrace'] = {'exitCode': recorder.returncode, 'stdout': stdout[-2000:], 'stderr': stderr[-2000:]}
    if recorder.returncode != 0: raise RuntimeError('xctrace recording failed')
    toc = command('xcrun', 'xctrace', 'export', '--input', str(trace), '--toc', timeout=45).stdout
    (args.output / 'toc.xml').write_text(toc)
    tables = {}
    for index, table in enumerate(ET.fromstring(toc).findall('.//data/table'), 1):
        name = table.get('schema') or table.get('swift-table')
        if name in {'ane-hw-intervals', 'mps-hw-intervals', 'metal-gpu-intervals', 'ODIEProfile'}:
            tables[name] = export_rows(trace, index, args.output / f'{name}.xml')
    report['intervalRows'] = tables
    ane, mps, metal = tables.get('ane-hw-intervals', 0), tables.get('mps-hw-intervals', 0), tables.get('metal-gpu-intervals', 0)
    if ane > 0:
        report['interpretation'] = 'ANE intervals were observed in this attached target trace; inspect row attribution before generalizing.'
    elif mps > 0 or metal > 0:
        report['interpretation'] = 'GPU/MPS intervals were observed, but no ANE intervals were observed in this trace.'
    else:
        report['interpretation'] = 'No ANE, MPS, or Metal interval rows were exported; execution-device evidence is inconclusive.'
    report['passed'] = True
except Exception as error:
    report['error'] = str(error)
finally:
    (args.output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'report': str(args.output / 'result.json')}, ensure_ascii=False))
if not report['passed']: sys.exit(1)
