#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
configuration=debug
check_ui=0
check_models=0
make_package=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) configuration=release ;;
    --ui) check_ui=1 ;;
    --models) check_models=1 ;;
    --package) make_package=1 ;;
    *) echo "Unknown verification option: $1" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p artifacts
python3 - <<'PYSTART'
import datetime,json,pathlib,sys,uuid
sys.path.insert(0,str(pathlib.Path('Scripts').resolve()))
from product_metadata import source_metadata
pathlib.Path('artifacts/verification-gate.json').write_text(json.dumps({'passed':False,'status':'running','runID':str(uuid.uuid4()),'startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),**source_metadata(pathlib.Path.cwd())},indent=2)+'\n')
PYSTART
trap 'verify_exit=$?; if [[ "$verify_exit" != 0 ]]; then python3 - "$verify_exit" <<'"'"'PYFAILED'"'"'
import json,pathlib,sys
path=pathlib.Path("artifacts/verification-gate.json");report=json.loads(path.read_text());report.update(passed=False,status="failed",exitCode=int(sys.argv[1]));path.write_text(json.dumps(report,indent=2)+"\n")
PYFAILED
fi' EXIT
./Scripts/build-app.sh "$configuration" > artifacts/package-gate.log 2>&1
swift test -c "$configuration" > artifacts/test-gate.log 2>&1
./Scripts/test-uvc-lifecycle.sh > artifacts/uvc-lifecycle-gate.log 2>&1
./Scripts/test-uvc-session.sh > artifacts/uvc-session-gate.log 2>&1
./Scripts/test-uvc-interface.sh > artifacts/uvc-interface-gate.log 2>&1
python3 Scripts/check-design.py > artifacts/design-contract.json
python3 Scripts/test-release-settings.py > artifacts/test-release-settings.log 2>&1
python3 -B Scripts/test-product-metadata.py > artifacts/test-product-metadata.log 2>&1
python3 -B Scripts/test-prepare-github-release.py > artifacts/test-prepare-github-release.log 2>&1
python3 -B Scripts/test-validate-zoom-stop.py > artifacts/test-validate-zoom-stop.log 2>&1
python3 -B Scripts/test-mcp-zoom-hardware.py > artifacts/test-mcp-zoom-hardware.log 2>&1
python3 -B Scripts/test-mcp-zoom-cancel-hardware.py > artifacts/test-mcp-zoom-cancel-hardware.log 2>&1
python3 -B Scripts/test-install-built-app.py > artifacts/test-install-built-app.log 2>&1
python3 -B Scripts/test-clean-test-media.py > artifacts/test-clean-test-media.log 2>&1
python3 -B Scripts/evaluate-ai-grounding.py --self-test > artifacts/test-ai-grounding-scorers.log 2>&1
python3 Scripts/test-update-feed.py > artifacts/update-feed-gate.log 2>&1
python3 Scripts/verify-bundle.py > artifacts/bundle-verification-run.log
if [[ "$check_ui" == 1 || "$check_models" == 1 ]]; then
  osascript -e 'if application id "studio.yuhuan.Pocket3Bridge" is running then tell application id "studio.yuhuan.Pocket3Bridge" to quit'
  python3 - <<'PYQUIT'
import subprocess,time
for _ in range(100):
 if subprocess.run(['pgrep','-x','Pocket3MCP'],capture_output=True).returncode:break
 time.sleep(.1)
else:raise SystemExit('The previous app did not finish quitting.')
PYQUIT
  open -n 'dist/Pocket 3 Controller.app' --args --hardware-validation
  python3 - <<'PYWAIT'
import pathlib,subprocess,time
cli=pathlib.Path('dist/Pocket 3 Controller.app/Contents/MacOS/pocket3')
for _ in range(60):
 result=subprocess.run([str(cli),'ai-status'],capture_output=True,timeout=25)
 if result.returncode==0:break
 time.sleep(.2)
else:raise SystemExit('The newly launched app did not become ready')
PYWAIT
  python3 Scripts/mcp-smoke.py --offline --output artifacts/mcp-offline > artifacts/mcp-offline.log
  python3 Scripts/mcp-cancellation-test.py > artifacts/mcp-cancellation.log
  python3 -B Scripts/test-observation-intent.py > artifacts/observation-intent-cli.log
fi
if [[ "$check_ui" == 1 ]]; then
  python3 Scripts/ui-parity.py > artifacts/ui-gate.log
fi
if [[ "$check_models" == 1 ]]; then
  python3 Scripts/prepare-evaluation-fixtures.py > artifacts/evaluation-fixtures.log
  python3 Scripts/verify-portable-inference.py > artifacts/portable-inference-run.log
fi
if [[ "$make_package" == 1 ]]; then
  [[ "$configuration" == release ]] || { echo '--package requires --release' >&2; exit 2; }
  ./Scripts/package-release.sh > artifacts/installer.log 2>&1
  python3 Scripts/verify-release-artifacts.py > artifacts/release-artifacts-verification.log 2>&1
fi
python3 - "$configuration" "$check_ui" "$check_models" "$make_package" <<'PYREPORT'
import datetime,hashlib,json,os,pathlib,plistlib,sys
sys.path.insert(0,str(pathlib.Path('Scripts').resolve()))
from product_metadata import metadata,staged_source_metadata,source_metadata
configuration,ui,models,package=sys.argv[1:]
checks=['build','unit tests','UVC ownership with AddressSanitizer','retained UVC session with AddressSanitizer','USB interface ownership with AddressSanitizer','shared design','translations','public release-settings validation','source provenance and release preflight','isolated Sparkle signed-feed verification','portable resources']
checks+=['offline zoom-stop diagnostic success and failure cases']
checks+=['offline MCP zoom and cancellation evidence/cleanup regressions','atomic local installation and media-cleanup regressions']
checks+=['offline image-grounding scorer contracts']
if ui=='1':checks+=['live layout','window and popover lifetime']
if models=='1':checks+=['copied-app MLX and Core AI inference','model memory release']
if ui=='1' or models=='1':checks+=['offline MCP','MCP cancellation','CLI observation-intent forwarding and rejection']
if package=='1':checks+=['ZIP/DMG assembly','DMG checksum','extracted ZIP and read-only DMG payload signatures and hashes']
not_checked=['physical camera and audio','physical movement and stopping','published updates','Developer ID and notarisation']
if ui=='1':
 detail=json.loads(pathlib.Path('artifacts/parity/ui-check.json').read_text()).get('popoverDetails',{})
 if detail.get('animationVerified') is False:not_checked+=['popover animation: screen locked or asleep']
else:not_checked+=['live UI']
if models!='1':not_checked+=['actual model inference']
report=json.loads(pathlib.Path('artifacts/verification-gate.json').read_text())
app=pathlib.Path('dist/Pocket 3 Controller.app/Contents')
legacy_alias=pathlib.Path('dist/Pocket 3 MCP.app')
assert legacy_alias.is_symlink() and os.readlink(legacy_alias)==app.parent.name
assert legacy_alias.resolve()==app.parent.resolve() and not app.parent.is_symlink()
report['legacyAppAlias']={'scope':'repository_dist_only','target':os.readlink(legacy_alias),'verified':True}
info=plistlib.loads((app/'Info.plist').read_bytes())
source=staged_source_metadata(info)
source_unchanged=source==source_metadata(pathlib.Path.cwd())
executable_hash=hashlib.sha256((app/'MacOS/Pocket3MCP').read_bytes()).hexdigest()
update_report=json.loads(pathlib.Path('artifacts/update-feed-verification/result.json').read_text())
assert update_report['passed'] and update_report['sourceExecutableSHA256']==executable_hash
if package=='1':
 artifact_report=json.loads(pathlib.Path('artifacts/release-artifacts-verification.json').read_text())
 assert artifact_report['passed'] and artifact_report['manifestAppExecutableSHA256']==executable_hash
 report['releaseArtifactRunID']=artifact_report['runID']
report.update(passed=True,status='complete',configuration=configuration,checks=checks,notChecked=not_checked,
    finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),**metadata(info),**source,
    sourceUnchangedDuringGate=source_unchanged,
    appExecutableSHA256=executable_hash,updateFeedRunID=update_report['runID'])
pathlib.Path('artifacts/verification-gate.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PYREPORT
