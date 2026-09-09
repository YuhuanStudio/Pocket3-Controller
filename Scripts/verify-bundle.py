#!/usr/bin/env python3
"""Verify packaged resources with SwiftPM's fallback directory unavailable."""
import json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
build = root / '.build'
hidden = root / '.build.pocket3-resource-check'
if hidden.exists():
    raise SystemExit('A previous verification directory exists; restore it before continuing.')
(root / 'artifacts').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='pocket3-portable-', dir=root/'artifacts') as temporary:
    app = pathlib.Path(temporary) / 'Pocket 3 Controller.app'
    subprocess.run(['ditto', str(root/'dist/Pocket 3 Controller.app'), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    build.rename(hidden)
    try:
        result = subprocess.run([str(app/'Contents/MacOS/Pocket3MCP')], env={**os.environ, 'POCKET3_RESOURCE_CHECK':'1'}, text=True, capture_output=True, timeout=30)
        report = {'exitCode': result.returncode, 'checks': json.loads(result.stdout) if result.returncode == 0 else {}, 'stderr': result.stderr, 'buildTreeHidden': True}
        (root/'artifacts/bundle-verification.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        if result.returncode != 0: raise SystemExit(result.stderr or result.stdout)
    finally:
        hidden.rename(build)
