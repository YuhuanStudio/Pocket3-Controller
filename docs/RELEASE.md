# Pocket 3 Controller 發布流程

採用 YunAudio 的「本機驗收及打包 → tag → GitHub Release 草稿 → 公開下載核對 → signed appcast 最後發布」流程。本文件是操作方法，**不表示已建立遠端 repo 或發布版本**。本機 origin 已指向使用者指定的 `YuhuanStudio/Pocket3-Controller`，遠端可用性在發布時核對。

| 身分 | 本版設定 |
|---|---|
| App／tag | Pocket 3 Controller `0.0.1 beta 1`／`v0.0.1-beta.1` |
| Bundle／build | `studio.yuhuan.Pocket3Bridge`／`9`；內部執行檔仍是 `Pocket3MCP` |
| Repo | `https://github.com/YuhuanStudio/Pocket3-Controller` |
| 版本頁 | `https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1` |
| Beta feed | `updates/beta-appcast.xml`，與 future stable feed 分開 |
| 預定 feed URL | `https://raw.githubusercontent.com/YuhuanStudio/Pocket3-Controller/main/updates/beta-appcast.xml`；建立 repo 時確認預設分支確為 `main` |

Beta 頁面連固定 tag 或 `/releases`，不依賴 `/releases/latest`。尚未配置的 URL 不當成可用服務。未公證的 Beta 可明確標示後分享，但本機簽署不是 Developer ID 或 Apple 公證。

## 1. 固定來源與候選包

檢閱來源、版本及 [beta 1 說明](releases/0.0.1-beta.1.md)，在已授權提交的情況下固定 commit。保持 [ProductIdentity](../Sources/Pocket3Core/ProductIdentity.swift)、[Info](../Resources/Info.plist)、tag、archive 名稱一致；`CFBundleVersion` 必須持續遞增。

```sh
./Scripts/verify.sh --release --ui --models --package
```

輸出 `dist/Pocket 3 Controller.app`、`Pocket3Controller-0.0.1-beta.1.zip`、同名 DMG 與 SHA-256 manifest。staging 完整組裝／驗證後才安裝；舊 bundle 保留，本機 `dist/Pocket 3 MCP.app` 相容連結不進安裝包。[建置](../Scripts/build-app.sh)、[打包](../Scripts/package-release.sh)、[payload 核對](../Scripts/verify-release-artifacts.py)、[本機簽署](LOCAL_SIGNING.md)。

gate 的 `passed=true/status=complete` 只代表其明列檢查，不把 `notChecked` 的相機／運動驗收變成完成。當次候選包真機 smoke 另看 [beta 交付清單](BETA_1_RELEASE.md)。

驗收後才在授權範圍內建立 tag；prepare 工具不執行這些版本寫入：

```sh
git tag -a v0.0.1-beta.1 -m 'Pocket 3 Controller 0.0.1 beta 1'
```

目前 App、gate 與 manifest 均記錄 `sourceCommit`／`sourceClean`。Release 預備要求三者與乾淨 exact tag 完全一致；任何來源改動後都需重新建置。不得移動已發布 tag。

## 2. 純本機 Release 預備

```sh
python3 Scripts/prepare-github-release.py --repo YuhuanStudio/Pocket3-Controller --check
python3 Scripts/prepare-github-release.py --repo YuhuanStudio/Pocket3-Controller
```

`--check` 不建立檔案。工具只讀 HEAD／tag／乾淨 worktree，git optional locks 停用；核對 App／helper／manifest／完整 gate／payload-verification 的版本、run ID 及 hash，不啟動 App、不使用 gh、不連網、不讀金鑰。缺 HEAD／exact tag、dirty source、部分 gate 或 hash 不符都拒絕。未公證會明示，不作硬阻擋。

成功後新目錄 `dist/github-release/0.0.1-beta.1/` 包含兩包副本、`release-notes.md`、`checksums-0.0.1-beta.1.txt` 及本機用的 `release-plan.json`。只允許前四個檔案作 Release assets；plan、測試 log、照片、裝置報告、模型快取及憑證都不上传。既有目錄不覆寫；重做指定新的絕對 `--output`。

純離線測試：`python3 Scripts/test-prepare-github-release.py`，僅臨時檔案及假的 git 回覆，不操作任何 repository。

## 3. 草稿、發布與公開下載

確認 repo 存在、授權範圍及可見性後才推送來源與 tag；工具不建立 repo、不推送 `main`。遠端 tag 解參照後的 commit 必須等於 plan 的 `source.commit`。在 plan 的 `command.cwd` 執行其 argv，等同：

```sh
gh release create v0.0.1-beta.1 \
  ./Pocket3Controller-0.0.1-beta.1.zip \
  ./Pocket3Controller-0.0.1-beta.1.dmg \
  ./release-notes.md ./checksums-0.0.1-beta.1.txt \
  --repo YuhuanStudio/Pocket3-Controller \
  --title 'Pocket 3 Controller 0.0.1 beta 1' \
  --draft --prerelease --verify-tag --latest=false --notes-file ./release-notes.md
```

`--verify-tag` 防止 CLI 自動產生 tag，不能代替遠端 commit 核對。先檢閱 draft 的四項資產、hash、功能範圍及未公證說明，再於授權發布時轉為公開 prerelease，保持 `latest=false`。

公開後，用不帶 GitHub 憑證的 HTTPS 下載，核對真正公開的 bytes，例如：

```sh
pocket3_download_dir="$(mktemp -d)"
curl --fail --location --output "$pocket3_download_dir/Pocket3Controller-0.0.1-beta.1.zip" \
  https://github.com/YuhuanStudio/Pocket3-Controller/releases/download/v0.0.1-beta.1/Pocket3Controller-0.0.1-beta.1.zip
shasum -a 256 "$pocket3_download_dir/Pocket3Controller-0.0.1-beta.1.zip"
```

DMG 及 notes 同樣核對，與本機保存的 checksums／plan 比較，不能只信一起下載的 checksum。再核對包內 App／helper hash、簽署及非建置機首次啟動、隔離與權限。若錯包，先停止 feed 發布，不覆寫同一已發布版本的不同 bytes。

## 4. Signed Beta feed 最後發布

本專案 Sparkle Keychain account 已配置為 `studio.yuhuan.pocket3controller.sparkle`；私鑰保存在 Keychain，公開設定位於 `Resources/ReleaseSettings.json`。重建使用此 account；不沿用 YunAudio 的 key/account/feed。prepare 不實作或執行金鑰處理。

正式公開設定只包含 `repositoryURL`、`feedURL`、`publicEDKey`（32-byte base64），[設定工具](../Scripts/release-settings.py) 檢查 HTTPS、feed／公鑰成對，拒絕私鑰欄位及 YunAudio URL。`Resources/ReleaseSettings.example.json` 是無效佔位範本。建置預設讀取已簽入的 `Resources/ReleaseSettings.json`，也可透過 `POCKET3_RELEASE_SETTINGS=/absolute/path/public-release-settings.json` 在發布用 App **建置前**注入，之後重做 gate／打包／tag 對照；不能修改已簽署 App 的 Info。無 feed 的 beta 1 可手動分享，但它不會自動取得後來配置的 feed，必須先手動換到含正式設定的版本。

最終公開 ZIP 已核對、account 已配置後，才使用下列真實 Sparkle 命令。參數已依 pinned 工具 `--help` 核對；本輪未執行簽署：

```sh
pocket3_feed_work="$(mktemp -d)"
pocket3_sparkle_account='studio.yuhuan.pocket3controller.sparkle'
cp dist/github-release/0.0.1-beta.1/Pocket3Controller-0.0.1-beta.1.zip "$pocket3_feed_work/"
cp dist/github-release/0.0.1-beta.1/release-notes.md \
  "$pocket3_feed_work/Pocket3Controller-0.0.1-beta.1.md"
# 後續版才將已驗證的既有 beta feed 複製為工作 appcast。
if test -f updates/beta-appcast.xml; then
  cp updates/beta-appcast.xml "$pocket3_feed_work/appcast.xml"
fi
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account "$pocket3_sparkle_account" \
  --download-url-prefix 'https://github.com/YuhuanStudio/Pocket3-Controller/releases/download/v0.0.1-beta.1/' \
  --link 'https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1' \
  --embed-release-notes --maximum-versions 3 --maximum-deltas 0 "$pocket3_feed_work"
.build/artifacts/sparkle/Sparkle/bin/sign_update --verify \
  --account "$pocket3_sparkle_account" "$pocket3_feed_work/appcast.xml"
```

核對 enclosure URL／length／Ed25519 signature、build `9`、最低 macOS `27.0`、`arm64` 及 ZIP hash。Beta 先用獨立 feed URL 隔離；目前 App 沒有 `allowedChannels` 實作，不只加 `--channel beta` 卻漏掉客戶端規則。

驗證後才把 signed `appcast.xml` 的原 bytes 複製至 `updates/beta-appcast.xml`，作為 release tag **之後**的獨立 feed commit 發布。複製改名不改 bytes，任何 XML 修改都需重簽。下載永久 HTTPS feed 再驗簽及 ZIP；現有 [signed-feed fixture](../Scripts/test-update-feed.py) 使用獨立 bundle／偏好／臨時金鑰，可證明有效、錯誤金鑰、竄改及未簽章的處理，但不能代替正式服務。最後驗證較舊版本下載、普通退出路徑釋放相機／IPC、安裝、重啟及偏好保留；本機 fixture 沒有安裝更新，不能宣稱此步已過。

## 5. Developer ID／公證選项

本機固定憑證與 `notarized=false` 可以如實標示為 Beta。若選 Developer ID 路線，另补同一身分的 nested signing、hardened runtime、timestamp、notarytool／stapler 及跨機驗收。所有會改 bytes 的操作完成後，才產生最終 ZIP／DMG checksum 與 appcast。

參考 [YunAudio RELEASING](https://github.com/YuhuanStudio/YunAudio/blob/main/RELEASING.md) 及 [package.sh](https://github.com/YuhuanStudio/YunAudio/blob/main/package.sh)，不照搬其音訊 driver 資產，也不沿用其「先算 DMG checksum、後 staple」順序。其舊「沒有 CI」敘述已過時：實際 workflow 是 self-hosted、`contents: read` 的無硬體驗證，不是自動發布。公開發布與本機準備維持分開的可檢閱步驟。

官方參考：[GitHub Release CLI](https://cli.github.com/manual/gh_release_create)、[Sparkle 發布與簽署更新](https://sparkle-project.org/documentation/publishing/)、[Apple 說明未識別開發者的 App](https://support.apple.com/en-us/102445)。
