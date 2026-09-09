# 本機開發簽章

Pocket 3 MCP 的本機建置預設使用專案專用的固定憑證，取代每次內容改變就失去原身分的 ad-hoc 簽章。App 的 bundle identifier 維持 `studio.yuhuan.Pocket3Bridge`。

Apple 說明 macOS 會透過指定需求（designated requirement，DR）辨識 App 後續版本；ad-hoc 的 DR 綁定某一次建置，容易使相機、麥克風等隱私授權需要重做。[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## 準備與建置

```sh
python3 Scripts/local-signing.py --prepare
./Scripts/build-app.sh release
```

`--prepare` 只輸出公開 JSON：憑證 fingerprint、專用 keychain 路徑、簽署種類與是否首次建立。重複執行會重用同一身分，不會輪替憑證。建置脚本以 JSON 解析取得參數，不把資料當作 shell 程式執行。

第一次執行在 `.local-signing/` 建立 10 年效期、RSA 2048、SHA-256 自簽憑證，僅包含 code-signing EKU 與 digitalSignature key usage，`CA:FALSE`。私鑰匯入專用 keychain 後，暫存私鑰 PEM 與 PKCS#12 立即清除。保留的 `certificate.pem` **只有公開憑證**。

目錄權限為 `0700`，keychain、解鎖密碼與 metadata 為 `0600`。它已加入 `.gitignore`，也不會被複製進 App、ZIP 或 DMG。請保留整個 `.local-signing/`：刪除、遺失或重新產生憑證會改變簽署身分，可能再次需要授權。備份時將它視為私人簽署憑證；不要上傳到 repository 或分享給其他使用者。

腳本只解鎖該專用 keychain，不加入 trust override，不改變預設 keychain。執行前後核對 keychain 搜尋清單；只有清單唯一變化是新增本專案 keychain 時，才立即恢復原清單。若同時出現其他變化，保留使用者設定並中止。現有身分不完整、過期或資料不符時會中止，保留現有資料供修復，避免默默建立新身分。

`codesign` 使用明確憑證 SHA-1 fingerprint 與 `--keychain` 路徑，自動產生同時核對 identifier 與 leaf certificate 的 DR；沒有使用只有 identifier 的寬鬆 DR。SHA-1 在這裡是系統選取憑證的識別值；憑證本身使用 SHA-256 簽署。

## 使用既有 Apple 簽署身分

若已有 Apple Development 或 Developer ID 憑證與對應私鑰，可指定：

```sh
POCKET3_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./Scripts/build-app.sh release
```

也接受憑證的 40 位 SHA-1 fingerprint，以避免名稱重複。指定身分時使用既有 keychain 設定，不建立本機憑證；若簽署失敗便中止，不回退到 ad-hoc。App 的 `Pocket3SigningKind` 記錄為 `provided`，預設專案憑證則記錄為 `local_development`。這個欄位只描述建置路徑，並不表示 Apple 已信任或公證該 App。Apple DTS 建議日常開發使用 Apple Development，公開獨立發行使用 Developer ID。[Apple DTS](https://developer.apple.com/forums/thread/730043)

## 驗證界線

已在這台 macOS 27 執行隔離實驗：兩個內容不同的程式使用同一自簽憑證，產生相同的 certificate-backed DR，並通過雙向 `codesign --verify --strict -R` 檢查。沒有新增任何 trust override，預設 keychain 與搜尋清單保持不變。`security find-identity -v` 可能不列出這種自簽身分；因此準備脚本查找 matching identities，實際有效性由 `codesign` 簽署與驗證確認。

首次從 ad-hoc 換成固定憑證，仍可能需要重新允許一次相機／麥克風。兩次實際 App 建置間的 TCC 授權保留需要另外驗證；固定 DR 本身不是已完成此驗收的證明。

自簽本機開發包不是 Apple Developer ID 簽署，也未公證；不宣稱能通過其他使用者 Mac 的預設 Gatekeeper 發行檢查。現有 `-local` 安裝包命名保持不變。[Apple TN3161](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)
