# Pocket 3 Controller 發布流程

沿用 YunAudio 的核心原則：發布包必須可追溯至確切來源、安裝包使用同一份已驗證 App、版本說明如實列出限制，並另外檢查公開下載與首次啟動。本專案的順序是「固定來源與本機 gate → exact tag → GitHub Release 草稿 → 公開下載核對 → signed Beta feed 最後發布」。不包含 YunAudio 的音訊 driver 安裝流程。

**beta 1 已公開發布。** `v0.0.1-beta.1` 對應 build `9`、來源 `21778c0e6ddec9ec9da017683f74c62177443985`；公開 ZIP／DMG 已核對，正式 Beta feed 與 ZIP 的公開 Ed25519 驗簽已通過。beta 2 及後續候選使用下列通用流程，不移動 beta 1 tag、不覆寫其已發布資產。

| 項目 | 來源或正式位置 |
|---|---|
| App／bundle／執行檔 | Pocket 3 Controller／`studio.yuhuan.Pocket3Bridge`／`Pocket3MCP`；MCP helper 為 `pocket3` |
| 版本、Beta 序號與 build | [Resources/Info.plist](../Resources/Info.plist)；[ProductIdentity](../Sources/Pocket3Core/ProductIdentity.swift) 須一致 |
| archive／tag 名稱 | [product_metadata.py](../Scripts/product_metadata.py) 產生 `archiveStem`／`semanticVersion`，tag 為 `v${semanticVersion}` |
| 公開 repo／版本列表 | [YuhuanStudio/Pocket3-Controller](https://github.com/YuhuanStudio/Pocket3-Controller)／[Releases](https://github.com/YuhuanStudio/Pocket3-Controller/releases) |
| 已發布 beta 1 | [v0.0.1-beta.1](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1) |
| 已上線 Beta feed | [updates/beta-appcast.xml](https://raw.githubusercontent.com/YuhuanStudio/Pocket3-Controller/main/updates/beta-appcast.xml)；與未來 stable feed 分開 |
| 公開更新設定 | [Resources/ReleaseSettings.json](../Resources/ReleaseSettings.json)，只含 repo、feed URL 與公鑰 |

Beta 連結使用固定 tag 或 `/releases`，不依賴 `/releases/latest`。本機固定簽署與 Sparkle 簽章都不等於 Developer ID 或 Apple 公證；是否公證以當次 manifest 為準。

## 1. 從來源取得版本，固定候選 commit

在 repository 根目錄執行下列只讀命令。先更新版本、Beta 序號、遞增的 `CFBundleVersion`、ProductIdentity 及 `docs/releases/${semanticVersion}.md`；不要由先前的 dist 包推定這次版本。

```sh
pocket3_project="$(pwd -P)"
pocket3_repo='YuhuanStudio/Pocket3-Controller'
pocket3_version="$(python3 -B Scripts/product_metadata.py Resources/Info.plist --field semanticVersion)"
pocket3_display_version="$(python3 -B Scripts/product_metadata.py Resources/Info.plist --field displayVersion)"
pocket3_build="$(python3 -B Scripts/product_metadata.py Resources/Info.plist --field buildVersion)"
pocket3_archive="$(python3 -B Scripts/product_metadata.py Resources/Info.plist --field archiveStem)"
pocket3_tag="v$pocket3_version"
pocket3_release_dir="$pocket3_project/dist/github-release/$pocket3_version"
pocket3_release_url="https://github.com/$pocket3_repo/releases/tag/$pocket3_tag"
pocket3_download_url="https://github.com/$pocket3_repo/releases/download/$pocket3_tag"
```

檢閱並提交候選來源後，從乾淨的同一 commit 執行完整 gate：

```sh
./Scripts/verify.sh --release --ui --models --package
```

輸出 `dist/Pocket 3 Controller.app`、`dist/${pocket3_archive}.zip`、同名 DMG 與 `dist/release-artifacts.json`。staging 完整組裝／驗證後才安裝；舊 bundle 保留，本機 `dist/Pocket 3 MCP.app` 相容連結不進安裝包。[建置](../Scripts/build-app.sh)、[打包](../Scripts/package-release.sh)、[payload 核對](../Scripts/verify-release-artifacts.py)、[本機簽署](LOCAL_SIGNING.md)。

gate 的 `passed=true/status=complete` 只代表其明列檢查，不把 `notChecked` 的相機／運動驗收變成完成。當次候選真機驗收及已知限制另記入對應版本說明；[beta 1 交付記錄](BETA_1_RELEASE.md) 是歷史證據，不能代替 beta 2 的檢查。

驗收後，對這個未再變動的 commit 建立新的 annotated tag：

```sh
git tag -a "$pocket3_tag" -m "Pocket 3 Controller $pocket3_display_version"
```

App、gate、manifest 的 `sourceCommit` 必須等於 `HEAD` 及 `refs/tags/${pocket3_tag}^{commit}`，且 `sourceClean=true/sourceDirty=false`。dirty 候選即使本機 gate 通過也不能發布。任何來源修改或新 commit 後都需重做 gate／打包；不能用新 tag 替舊 binary 補來源身分。已發布 tag 永不移動。

## 2. 純本機 Release 預備

```sh
python3 Scripts/prepare-github-release.py --repo "$pocket3_repo" --check
python3 Scripts/prepare-github-release.py --repo "$pocket3_repo"
```

`--check` 不建立檔案。工具只讀 HEAD／exact tag／乾淨 worktree，停用 git optional locks；核對來源 Info、App／helper、manifest、完整 gate、payload-verification 的版本、run ID 及 hash。它不啟動 App、不使用 gh、不連網、不讀金鑰。缺 exact tag、dirty source、部分 gate 或 hash 不符都拒絕；未公證會明示。

成功後 `$pocket3_release_dir` 包含 ZIP、DMG、`release-notes.md`、`checksums-${pocket3_version}.txt` 及本機 `release-plan.json`。只允許前四個檔案作 Release assets；plan、測試 log、照片、裝置報告、模型快取及憑證不上傳。既有目錄不覆寫；重做時指定新的絕對 `--output`，並以新 plan 的 `command.cwd` 為準。

純離線測試：`python3 Scripts/test-prepare-github-release.py`，僅臨時檔案及假的 git 回覆，不操作 repository。

## 3. 草稿、發布與公開下載

推送這次已固定的來源與新 tag 後，核對遠端 tag 解參照後的 commit 等於 plan 的 `source.commit`。prepare 不推送來源；`--verify-tag` 只能防止 gh 自動建立 tag，不能代替遠端 commit 比對。

優先使用 `release-plan.json` 的 `command.cwd` 與完整 argv。預設輸出位置的等價命令為：

```sh
(
  cd "$pocket3_release_dir"
  gh release create "$pocket3_tag" \
    "./$pocket3_archive.zip" "./$pocket3_archive.dmg" \
    ./release-notes.md "./checksums-$pocket3_version.txt" \
    --repo "$pocket3_repo" \
    --title "Pocket 3 Controller $pocket3_display_version" \
    --draft --prerelease --verify-tag --latest=false --notes-file ./release-notes.md
)
```

檢閱 draft 的四項資產、hash、功能範圍、語言與未公證說明，再轉為公開 prerelease，保持 `latest=false`。不要用覆寫資產處理已公開版本的包內容修正；應增加 build／版本後另發。

公開後，以不帶 GitHub 憑證的 HTTPS 下載真正公開的 bytes：

```sh
pocket3_download_dir="$(mktemp -d)"
curl --fail --location --output "$pocket3_download_dir/$pocket3_archive.zip" \
  "$pocket3_download_url/$pocket3_archive.zip"
shasum -a 256 "$pocket3_download_dir/$pocket3_archive.zip"
```

DMG、notes 與 checksums 同樣下載核對，與發布前保留的本機 plan／hash 比較，不能只信一起下載的 checksum。再核對包內 App／helper、簽署及非建置機首次啟動、隔離與權限；未做的檢查保留為未驗證。若發現錯包，先停止 feed 發布，不覆寫同版本不同 bytes。

## 4. Signed Beta feed 最後發布

本專案 Keychain account 為 `studio.yuhuan.pocket3controller.sparkle`；**私鑰只保存在 Keychain**，不匯出至檔案、環境變數、命令參數或 Release assets。公開設定位於 `Resources/ReleaseSettings.json`，不能沿用 YunAudio 的 key/account/feed。beta 1 已使用此 account 完成簽署；不是尚待配置的服務。

[設定工具](../Scripts/release-settings.py) 檢查 HTTPS、feed／公鑰成對，拒絕私鑰欄位及 YunAudio URL。建置預設讀取簽入的正式設定；若使用 `POCKET3_RELEASE_SETTINGS=/absolute/path/public-release-settings.json`，須在 App 建置前注入並與欲發布的來源設定一致，再重做 gate／tag 核對，不能修改已簽署 App 的 Info。`ReleaseSettings.example.json` 僅為無效佔位範本。公開 beta 1 build 9 已含正式設定，不能再描述為「無 feed」。

最終公開 ZIP 與本機 hash 一致後，在獨立暫存目錄準備 feed。`generate_appcast` 依 App 的 `SUFeedURL` 最後路徑組件選擇檔名，本專案實際為 **`beta-appcast.xml`**；這不是 `--channel beta` 的效果。下例另以 `-o` 固定同一路徑，複製、產生、驗證與發布全程使用該檔名：

```sh
pocket3_feed_work="$(mktemp -d)"
pocket3_feed_file="$pocket3_feed_work/beta-appcast.xml"
pocket3_sparkle_account='studio.yuhuan.pocket3controller.sparkle'
pocket3_sparkle_bin="$pocket3_project/.build/artifacts/sparkle/Sparkle/bin"
cp "$pocket3_release_dir/$pocket3_archive.zip" "$pocket3_feed_work/"
cp "$pocket3_release_dir/release-notes.md" "$pocket3_feed_work/$pocket3_archive.md"
# 先確認此既有 feed 與正式公開版本一致且驗簽通過，再保留其歷史項目。
cp "$pocket3_project/updates/beta-appcast.xml" "$pocket3_feed_file"
"$pocket3_sparkle_bin/generate_appcast" \
  --account "$pocket3_sparkle_account" \
  --versions "$pocket3_build" \
  --download-url-prefix "$pocket3_download_url/" \
  --link "$pocket3_release_url" \
  --embed-release-notes --maximum-versions 3 --maximum-deltas 0 \
  -o "$pocket3_feed_file" "$pocket3_feed_work"
"$pocket3_sparkle_bin/sign_update" --verify \
  --account "$pocket3_sparkle_account" "$pocket3_feed_file"
```

`--versions` 接收 **CFBundleVersion/build**，不是 semantic version。檢查新項目的 enclosure URL／length／Ed25519 signature、`sparkle:version` 等於 `$pocket3_build`、最低 macOS 與 architecture 符合實際 App，以及 ZIP hash；保留項目的原 download URL 與簽章不能指向本次 tag。當前 App 要求 macOS 27、Apple Silicon。Beta 以獨立 feed URL 隔離，App 未實作 `allowedChannels`，因此不要額外加入 `--channel beta` 使既有客戶端略過新版本。

驗證後才把 `$pocket3_feed_file` 的**原 bytes**複製至 `updates/beta-appcast.xml`，作為 release tag **之後**的獨立 feed commit 發布。任何 XML 修改都需重簽。再無登入下載永久 HTTPS feed，核對本機 bytes，使用已公開的 `publicEDKey` 驗證 feed 與其 enclosure ZIP；公開驗證不需要私鑰。

beta 1 的正式公開核對已完成；本機記錄 `artifacts/public-beta1/public-feed-download.json` 與 `public-signature-verification.json` 分別保存公開下載及 `feedVerified=true/archiveVerified=true/privateKeyAccess=false`。這些證據不隨 Release assets 上傳，也不自動證明下一版正確。

另驗證較舊已發布版本取得正式更新、普通退出路徑釋放相機／IPC、安裝、重啟及偏好保留。公開 feed／ZIP 驗簽及 [signed-feed fixture](../Scripts/test-update-feed.py) 都不能代替實際升級。

**已完成隔離副本的build9→17實際安裝與重啟。** [安裝驗證器](../Scripts/test-update-install.py) 由公開beta1 ZIP與候選App建立獨立bundle ID的副本，使用暫存測試key與loopback feed；外部Sparkle driver實際下載39,297,922 bytes、替換App、退出舊PID並重啟新PID。安裝後完整副本bytes、簽署、偏好及新IPC均通過，副本／偏好／暫存key清理完成。[結果](../artifacts/update-install/build9-to17-complete-20260909/result.json)

預設執行`python3 -B Scripts/test-update-install.py`只顯示計畫；`--execute`才操作隔離副本，且要求所有Pocket3MCP已退出，因現有服務共用固定IPC路徑。fixture不取像、不下載模型，結束後需由操作者恢復原App。測試key不同於正式Keychain account，既有公開檔案保持原bytes。首輪安裝本身成功，但driver將清理旗標序列化為數字0而被嚴格Boolean檢查拒絕，整體保留failed；修正型別後才取得上述新的完整通過，不覆寫舊紀錄。

此結果**尚不等於正式App更新介面／正式feed的跨版本升級驗收**，也不涵蓋取像中的更新、相機釋放、跨Mac Gatekeeper或Apple公證；這些仍須在下一個正式候選發布流程完成。

## 5. Developer ID／公證選項

本機固定憑證與 `notarized=false` 可如實標示為 Beta。若改採 Developer ID，另補同一身分的 nested signing、hardened runtime、timestamp、notarytool／stapler 及跨機驗收。所有會改 bytes 的操作完成後，才產生最終 ZIP／DMG checksum 與 appcast。

對照 [YunAudio RELEASING](https://github.com/YuhuanStudio/YunAudio/blob/main/RELEASING.md) 與 [package.sh](https://github.com/YuhuanStudio/YunAudio/blob/main/package.sh)：保留確切來源、單一 App 組裝來源及真實首次啟動檢查；版本取值採本專案的 metadata/exact tag 檢查，不直接套用 YunAudio 的 `git describe` 或 driver 包內容。公開發布與本機準備維持可分開檢閱的步驟。

官方參考：[GitHub Release CLI](https://cli.github.com/manual/gh_release_create)、[Sparkle 發布與簽署更新](https://sparkle-project.org/documentation/publishing/)、[Apple 說明未識別開發者的 App](https://support.apple.com/en-us/102445)。
