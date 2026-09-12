#!/bin/bash
# Hardware-free normal VS-open ordering regression against the vendored MRC bridge.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
report_directory="$project_root/artifacts/uvc-stream-session"
mkdir -p "$report_directory"
python3 - "$report_directory/result.json" <<'PY'
import datetime, json, pathlib, sys, uuid
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "passed": False, "status": "running", "runID": str(uuid.uuid4()),
    "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "hardwareAccess": False, "sanitizer": "AddressSanitizer",
}, indent=2) + "\n")
PY
uvc_test_directory="$(mktemp -d "${TMPDIR:-/tmp}/pocket3-uvc-stream-session.XXXXXX")"
cleanup() {
  uvc_test_exit=$?
  rm -rf "$uvc_test_directory"
  if [[ "$uvc_test_exit" != 0 ]]; then
    python3 - "$report_directory/result.json" "$uvc_test_exit" <<'PY'
import datetime, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text())
report.update(passed=False, status="failed", exitCode=int(sys.argv[2]),
              finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
path.write_text(json.dumps(report, indent=2) + "\n")
PY
  fi
}
trap cleanup EXIT
xcrun clang -fno-objc-arc -fblocks -g -UNDEBUG -fsanitize=address \
  -Wno-deprecated-declarations -I Sources/Pocket3UVC \
  Tests/Pocket3UVCTests/StreamSession.m \
  Sources/Pocket3UVC/UVCType.m Sources/Pocket3UVC/UVCValue.m \
  -framework Foundation -framework IOKit \
  -o "$uvc_test_directory/stream-session" > "$report_directory/compile.log" 2>&1
"$uvc_test_directory/stream-session" > "$uvc_test_directory/result.json" \
  2> "$report_directory/stderr.log"
python3 - "$report_directory/result.json" "$uvc_test_directory/result.json" <<'PY'
import datetime, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text())
result = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert result.get("passed") is True and result.get("hardwareAccess") is False
report.update(result, status="complete",
              finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
path.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
PY
