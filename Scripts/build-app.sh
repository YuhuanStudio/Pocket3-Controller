#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
configuration="${1:-debug}"
source_before="$(python3 -B Scripts/product_metadata.py --source-project "$project_root")"
release_settings="${POCKET3_RELEASE_SETTINGS:-}"
if [[ -z "$release_settings" && -f "$project_root/Resources/ReleaseSettings.json" ]]; then
  release_settings="$project_root/Resources/ReleaseSettings.json"
fi
# Validate public configuration before spending time building or signing.
if [[ -n "$release_settings" ]]; then
  python3 -B Scripts/release-settings.py "$release_settings"
fi
if [[ -n "${POCKET3_SIGN_IDENTITY:-}" ]]; then
  if [[ "$POCKET3_SIGN_IDENTITY" == "-" ]]; then
    echo 'POCKET3_SIGN_IDENTITY must name a certificate-backed identity, not ad-hoc signing.' >&2
    exit 1
  fi
  signing_args=(--sign "$POCKET3_SIGN_IDENTITY")
  signing_kind="provided"
else
  signing_json="$(python3 Scripts/local-signing.py --prepare)"
  signing_identity="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])' <<< "$signing_json")"
  signing_keychain="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["keychain"])' <<< "$signing_json")"
  signing_args=(--sign "$signing_identity" --keychain "$signing_keychain" --timestamp=none)
  signing_kind="local_development"
fi
swift package resolve
python3 Scripts/patch-dependencies.py
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
destination="$project_root/dist/Pocket 3 Controller.app"
mkdir -p "$project_root/dist"
staging="$(mktemp -d "$project_root/dist/.pocket3-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Pocket 3 Controller.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses" "$app/Contents/Frameworks"
cp Resources/Info.plist "$app/Contents/Info.plist"
python3 - "$app/Contents/Info.plist" "$configuration" "$signing_kind" <<'PYINFO'
import pathlib,plistlib,sys
path=pathlib.Path(sys.argv[1]);value=plistlib.loads(path.read_bytes())
value['Pocket3BuildConfiguration']=sys.argv[2]
value['Pocket3SigningKind']=sys.argv[3]
path.write_bytes(plistlib.dumps(value,sort_keys=False))
PYINFO
if [[ -n "$release_settings" ]]; then
  python3 -B Scripts/release-settings.py "$release_settings" --info-plist "$app/Contents/Info.plist"
fi
cp "$binary_dir/Pocket3MCP" "$app/Contents/MacOS/"
cp "$binary_dir/pocket3" "$app/Contents/MacOS/"
cp ThirdParty/uvc-util/LICENSE "$app/Contents/Resources/Licenses/uvc-util.txt"
cp ThirdParty/CoreAIModels/LICENSE "$app/Contents/Resources/Licenses/coreai-models.txt"
cp ThirdParty/ModelWeights/LICENSE "$app/Contents/Resources/Licenses/model-weights-apache-2.0.txt"
cp ThirdParty/ModelWeights/NOTICE.md "$app/Contents/Resources/Licenses/model-weights-notice.md"
mkdir -p "$app/Contents/Resources/Models"
cp -R Resources/Models/yolos-tiny_float32_static.aimodel "$app/Contents/Resources/Models/"
if [[ "$configuration" == "debug" ]]; then
  cp -R Resources/Models/yolos-tiny_float16_static.aimodel "$app/Contents/Resources/Models/"
fi
for dependency in .build/checkouts/*; do
  for license in LICENSE LICENSE.txt LICENSE.md; do
    if [[ -f "$dependency/$license" ]]; then
      cp "$dependency/$license" "$app/Contents/Resources/Licenses/$(basename "$dependency").txt"
      break
    fi
  done
done
for resource in "$binary_dir"/*.bundle; do
  [[ -d "$resource" ]] && cp -R "$resource" "$app/Contents/Resources/"
done
ditto "$binary_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$project_root/.build/Pocket3MCP.iconset"
POCKET3_ICON="$project_root/.build/Pocket3MCP.iconset" "$binary_dir/Pocket3MCP"
iconutil --convert icns "$project_root/.build/Pocket3MCP.iconset" --output "$app/Contents/Resources/Pocket3MCP.icns"
cp ThirdParty/YunDesign/LICENSE "$app/Contents/Resources/Licenses/YunDesign.txt"
cp ThirdParty/Kaze/LICENSE "$app/Contents/Resources/Licenses/Kaze-protocol-reference.txt"
cp Resources/BETA-NOTES.txt "$app/Contents/Resources/BETA-NOTES.txt"
for localization in Sources/Pocket3BridgeApp/Resources/*.lproj; do
  mkdir -p "$app/Contents/Resources/$(basename "$localization")"
  cp "$localization/InfoPlist.strings" "$app/Contents/Resources/$(basename "$localization")/"
done
python3 -B - "$app/Contents/Info.plist" "$source_before" <<'PYSOURCE'
import json,pathlib,plistlib,sys
sys.path.insert(0,str(pathlib.Path('Scripts').resolve()))
from product_metadata import source_metadata,build_source_metadata
path=pathlib.Path(sys.argv[1]);info=plistlib.loads(path.read_bytes())
source=build_source_metadata(json.loads(sys.argv[2]),source_metadata(pathlib.Path.cwd()))
info.update(Pocket3SourceCommit=source['sourceCommit'] or '',
            Pocket3SourceDirty=source['sourceDirty'],Pocket3SourceClean=source['sourceClean'])
path.write_bytes(plistlib.dumps(info,sort_keys=False))
PYSOURCE
codesign --force --deep "${signing_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
codesign --force "${signing_args[@]}" "$app/Contents/MacOS/pocket3"
codesign --force "${signing_args[@]}" --entitlements Resources/Pocket3Bridge.entitlements "$app"
codesign --verify --deep --strict "$app"
python3 Scripts/install-built-app.py "$app" "$destination" --legacy-alias "$project_root/dist/Pocket 3 MCP.app"
