# Pocket 3 Controller

macOS 27 原生 Pocket 3 控制 App，提供即時預覽、本機圖片問答、手動雲台控制，以及 MCP／CLI 接入。介面使用 YunAudio／YunUI 的共用設計與通用 App 功能。

**0.0.1 beta 1** 提供 ZIP／DMG 安裝包；公開版為 build 9，內建本專案獨立的簽署更新來源。版本下載見 [GitHub Releases](https://github.com/YuhuanStudio/Pocket3-Controller/releases)。交付清單見 [BETA_1_RELEASE.md](docs/BETA_1_RELEASE.md)。完整進度見 [TODO.md](TODO.md)，設計約定見 [PRODUCT_DESIGN.md](docs/PRODUCT_DESIGN.md)。

## 開啟

```sh
open '/Applications/Pocket 3 Controller.app'
```

以 USB 連接 Pocket 3，在機身選擇 Webcam 模式，於 App 選擇相機並連接。格式依裝置宣告列出解析度、幀率及 NV12／UYVY，包含直幅；改選後重新連接才會生效。裝置列出的格式與已實測可用的格式分開記錄，詳見 [硬體驗收](docs/HARDWARE_ACCEPTANCE.md)。

手動雲台使用 USB 連線，按住方向／拖曳搖桿持續移動，拖曳離中心越遠移動越快，放開或失焦便停止。此路徑已有實機介面測試，無須加入相機 Wi-Fi 或先建立 BLE 馬達控制，Mac 保留現有網路。完整控制範圍、物理速度與停止延遲仍待驗收；操作與限制見 [連續雲台控制](docs/CONTINUOUS_GIMBAL.md)。

USB 變焦已接入 App、CLI、MCP 與 App 內 AI，顯示裝置提供的原始刻度，已有 100→200→100 的實機往返。原生快速回中／前後切換仍待打通，沒有以慢速 USB 轉動替代；預覽點按對焦也未完成，雖然機身在 Webcam 模式可點選對焦，目前 USB／AVFoundation 連線並未提供所需控制能力。

藍牙配對後，面板可呈現相機既有回報的電量、充電狀態與姿態；低電量或多筆回報持續下降時，原有狀態膠囊會提醒。它不把「未充電」直接當故障，也不將藍牙peer自動綁成USB相機或已校準的控制座標。已實測 USB 預覽與 BLE 回報共存；AF、白平衡與曝光的只讀查詢亦已取得機身回覆。[提示規則與來源](docs/BLUETOOTH_TELEMETRY.md)

AI 存取預設關閉。在相機頁選擇「只允許觀察」後，外部 MCP／CLI 才能取像。手動控制會接管 AI；隱私暫停釋放影音輸入。關窗仍保留選單列服務，退出 App 才會結束。

主選單、齒輪或 ⌘, 可開啟設定。選單列圖標左鍵開啟面板，右鍵／Control-click 開啟功能選單。

## MCP 與 CLI

「AI 引擎與接入」頁可複製此 App 路徑對應的 MCP 設定。工具為 `camera_status`、`capture_frame`、`move_gimbal`、`stop_gimbal`、`camera_zoom_status`、`camera_set_zoom`。

MCP 縮放須先讀 `camera_status.capture.sessionID`，以同一 `expectedSessionID` 查 `camera_zoom_status`，再把符合其 minimum／maximum／step 的整數 `rawValue` 傳給 `camera_set_zoom`。原始刻度不是校準過的倍率；寫入需要 App 開放 AI 控制權。檢查結果的 completed／verified，再取新影格；未確認或取消的動作不要盲目重試。

```sh
'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3' status
'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3' snapshot --output frame.jpg
'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3' ask --engine apple --question '畫面中有什麼？'
'dist/Pocket 3 Controller.app/Contents/MacOS/pocket3' mcp
```

MCP stdio helper 透過同使用者私有 Unix socket 存取 App，不另行搶占相機。AI 移動還需要本機停止驗證通過；傳送 USB 命令不視為已完成物理動作。

## 建置與驗證

從原始碼建置需要 Xcode 27 beta 的完整工具鏈。腳本可選用 `/Applications/Xcode-beta.app/Contents/Developer`，不改全系統的 xcode-select。

```sh
./Scripts/build-app.sh
./Scripts/verify.sh
./Scripts/verify.sh --release --ui --models --package
```

驗證包含單元測試、共用設計原始檔、語言資源、隔離更新簽章測試，以及將 `.build` 暫時移開後的獨立 App 資源檢查。`--ui` 會重新開啟剛建置的 App、切換頁面、開關視窗並擷取版面；`--models` 會從搬移後的 App 實際推論；`--package` 製作本機安裝包。這些檢查不會開啟相機。`--models` 需要先在 App 下載預設 MLX 模型；測試卡會自動產生，公開評估圖片在首次需要時按固定 SHA-256 下載。執行前請先結束目前的 App 操作。

## 目前驗證界線

- 啟動崩潰的 UVC autorelease 快取已修正；60 秒、252 次查詢回歸通過。
- 已通過真實 MCP 新影格與 Apple 本機圖片問答。Qwen 3.5 4B 的實際 MLX 推論、取消與卸載已測；Core AI Float32 數值比對及 GPU 路徑已有紀錄，詳見驗證文件。
- 小幅位置往返已有量測；停止判準已加嚴，舊證據不再自動開放 AI 移動。
- Sparkle 使用本專案獨立公鑰驗證 Beta feed 與更新包；自動檢查依使用者偏好啟用。首次發行不等於已完成下一版的更新安裝回歸。
- App 使用固定開發憑證，尚未 Apple 公證；網路下載後可能需要在「系統設定 → 隱私權與安全性」明確允許開啟。詳見 [本機簽署](docs/LOCAL_SIGNING.md)。

發布採用 YunAudio 的本機驗收、GitHub Release 與簽署更新 feed 流程，詳見 [發布說明](docs/RELEASE.md)。儲存庫為 `YuhuanStudio/Pocket3-Controller`。測試照片的保留與清理見 [測試產物政策](docs/TEST_ARTIFACTS.md)。

第三方來源與授權位於 `ThirdParty`，並隨 App 打包。既有 bundle identifier 與 `Application Support/Pocket3Bridge` 快取路徑保留作名稱更換的相容用途。

授權範圍與第三方歸屬見 [NOTICE.md](NOTICE.md)。開發文件中的本機證據連結不隨原始碼發布。
