#!/usr/bin/env python3
"""Recreate evaluation inputs without retaining private camera images."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

root = Path(__file__).resolve().parents[1]
output = root / 'artifacts/evaluation/fixtures'
output.mkdir(parents=True, exist_ok=True)
generated = ['colours', 'text', 'empty', 'injection', 'heldout-text', 'heldout-colours']
environment = dict(os.environ)
if 'DEVELOPER_DIR' not in environment and Path('/Applications/Xcode-beta.app/Contents/Developer').is_dir():
    environment['DEVELOPER_DIR'] = '/Applications/Xcode-beta.app/Contents/Developer'
if not all((output / (name + '.png')).is_file() for name in generated):
    subprocess.run(['xcrun', 'swift', str(root / 'Scripts/make-evaluation-fixtures.swift'), str(output)],
                   env=environment, check=True, timeout=120)
source = json.loads((root / 'Scripts/coreai-fixture-source.json').read_text())
sample = output / source['image']
if not sample.is_file() or hashlib.sha256(sample.read_bytes()).hexdigest() != source['sha256']:
    with urllib.request.urlopen(source['download'], timeout=30) as response:
        content = response.read(8 * 1024 * 1024 + 1)
    if len(content) > 8 * 1024 * 1024 or hashlib.sha256(content).hexdigest() != source['sha256']:
        raise SystemExit('The public evaluation image did not match its recorded SHA-256')
    with tempfile.NamedTemporaryFile(dir=output, delete=False) as staging:
        staging.write(content)
        staged = Path(staging.name)
    try:
        staged.replace(sample)
    finally:
        staged.unlink(missing_ok=True)
print(json.dumps({'ready': True, 'generatedFixtures': len(generated),
                  'publicSampleSHA256': source['sha256'], 'cameraUsed': False}))
