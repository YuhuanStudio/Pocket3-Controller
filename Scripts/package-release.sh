#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
app="$project_root/dist/Pocket 3 Controller.app"
[[ ! -L "$app" ]] || { echo 'Package the real Controller bundle, not a compatibility symlink.' >&2; exit 1; }
archive_stem="$(python3 Scripts/product_metadata.py "$app/Contents/Info.plist" --field archiveStem)"
display_version="$(python3 Scripts/product_metadata.py "$app/Contents/Info.plist" --field displayVersion)"
configuration="$(/usr/libexec/PlistBuddy -c 'Print :Pocket3BuildConfiguration' "$app/Contents/Info.plist")"
[[ "$configuration" == "release" ]] || { echo 'Build the Release app first.' >&2; exit 1; }
python3 -B - "$app/Contents/Info.plist" <<'PYSETTINGS'
import pathlib,plistlib,sys
sys.path.insert(0,str(pathlib.Path('Scripts').resolve()))
from product_metadata import configured_update_settings,staged_source_metadata
info=plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
configured_update_settings(info)
staged_source_metadata(info)
PYSETTINGS
codesign --verify --deep --strict "$app"
staging="$(mktemp -d "$project_root/dist/.pocket3-installer.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
payload="$staging/payload"
mkdir -p "$payload"
ditto "$app" "$payload/Pocket 3 Controller.app"
ln -s /Applications "$payload/Applications"
cp "$app/Contents/Resources/BETA-NOTES.txt" "$payload/BETA-NOTES.txt"
cat > "$payload/INSTALL.txt" <<TEXT
Pocket 3 Controller — 公開 Beta
版本：$display_version

將 Pocket 3 Controller.app 拖到 Applications 後開啟。
需要 macOS 27 與 Apple Silicon。連接 Pocket 3 後，請在機身選擇 Webcam 模式。

相機權限在連線時請求；麥克風只在你啟用音訊功能時請求。
關閉視窗仍留在選單列；「隱私暫停」釋放影音，退出 App 結束服務。
設定與 MCP 接入資訊均在 App 內。

此公開 Beta 已簽署，尚未完成 Apple 公證。
App 已配置此專案的更新來源，更新摘要與下載使用 Ed25519 簽章驗證。
功能驗收範圍與已知限制，請先閱讀 BETA-NOTES.txt。
未公證的網路下載檔可能需要在「系統設定 → 隱私權與安全性」允許開啟。
TEXT
archive="$project_root/dist/$archive_stem.zip"
dmg="$project_root/dist/$archive_stem.dmg"
# Create under unique paths outside the source folder. Reusing a mounted DMG
# pathname can leave DiskImages holding the prior file while verifying it.
pending_archive="$staging/archive.zip"
pending_dmg="$staging/archive.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$pending_archive"
diskutil image create from --format UDZO --volumeName 'Pocket 3 Controller' "$payload" "$pending_dmg"
hdiutil verify "$pending_dmg"
mv -f "$pending_archive" "$archive"
mv -f "$pending_dmg" "$dmg"
python3 - "$archive" "$dmg" "$app/Contents/Info.plist" <<'PY'
import hashlib,json,pathlib,plistlib,sys
sys.path.insert(0,str(pathlib.Path('Scripts').resolve()))
from product_metadata import metadata,staged_source_metadata,configured_update_settings
files=[]
for name in sys.argv[1:3]:
 path=pathlib.Path(name);digest=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(8*1024*1024),b''):digest.update(block)
 files.append({'file':path.name,'bytes':path.stat().st_size,'sha256':digest.hexdigest()})
manifest=pathlib.Path(sys.argv[1]).parent/'release-artifacts.json'
info=plistlib.loads(pathlib.Path(sys.argv[3]).read_bytes())
executable=pathlib.Path(sys.argv[3]).parent/'MacOS/Pocket3MCP'
manifest.write_text(json.dumps({'status':'complete','verified':True,**metadata(info),**staged_source_metadata(info),
 'appExecutableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest(),
 'helperExecutableSHA256':hashlib.sha256((executable.parent/'pocket3').read_bytes()).hexdigest(),
 'signing':info.get('Pocket3SigningKind','legacy_adhoc'),'notarized':False,
 'updateSettings':configured_update_settings(info),'artifacts':files},indent=2)+'\n')
print(manifest)
PY
