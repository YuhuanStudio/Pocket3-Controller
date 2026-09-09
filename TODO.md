# Pocket 3 Controller — 當前待辦

更新：2026-09-09。完整目標仍是 `BUILD_PROPOSAL.md` 的 1.0 App＋MCP＋CLI，尚未完成。**Pocket 3 Controller 0.0.1 beta 1（build 9）已發布**，本段記錄時已安裝 beta 2 開發 build 15，candidate build 16 正在編譯／測試；使用者已重新接回相機。build 7 的只讀 BLE 設定面板已通過 397 項 Release 測試及完整軟體 gate，原始報告保留於 [build 7 紀錄](artifacts/history/build7-c405cf48/artifacts/verification-gate.json)。新 candidate 的結果另行記錄，不把舊版通過套用到新版。

## beta 1 發布與整理

- [x] 使用者選定產品名稱 Pocket 3 Controller、GitHub 儲存庫名稱 `YuhuanStudio/Pocket3-Controller`；內部 bundle ID、簽署身分與設定沿用。
- [x] build 8 完整軟體 gate：397 項 Release 測試、59 張 UI、三語／Yun 共用設計、搬移後模型推論、更新簽章、ZIP／DMG 驗證通過。[本版 gate](artifacts/beta1-2026-09-09/software/artifacts/verification-gate.json)
- [x] build 8 真機基本流程：1920×1080 NV12 新影格、實際按鈕放開、pan 0→7920→−360（容差1080）、zoom 100→110目標（讀回109，容差1）→100、隱私暫停及新 session 重連通過，final Stop verified。[結果](artifacts/beta1-2026-09-09/hardware-smoke/result.json)。不涵蓋移動中 Zoom Stop、完整視角或原生預設。
- [x] 第一批已清理 155 個舊測試照片／截圖（31,326,669 bytes），保存原始 JSON、log、媒體 hash 及刪除清單；必要模型 fixtures 和當前 UI 複核截圖保留。[政策與 receipt](docs/TEST_ARTIFACTS.md)
- [x] 已對照 YunAudio 並落地純本機 Release 預備工具、資產白名單、checksums／notes／draft argv；9 項離線測試通過。[發布流程](docs/RELEASE.md)
- [x] 已取得發布授權，建立獨立 Sparkle Keychain account 與公開更新設定，保留私鑰於 Keychain。
- [x] 公開 build 9：乾淨來源 commit／tag、完整 gate、GitHub prerelease、四項資產公開下載、signed feed／ZIP 公鑰驗證已完成。[Release](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1)
- [x] 正式 Beta feed 已完成 Keychain 簽署與公開發布；重新取得的公開 feed／ZIP 經 CryptoKit 與本專案 Ed25519 公鑰驗證，`feedVerified=true`、`archiveVerified=true`。[公開簽章驗證](artifacts/public-beta1/public-signature-verification.json)。此項不包含跨版本安裝／重啟。
- [x] 三語 README／文件索引／使用指南與九張排除取景照片的 UI 圖已完成，圖片與公開下載版本分別標明。[公開呈現清單](docs/RELEASE_PRESENTATION_CHECKLIST.md)
- [x] beta 2 build 11 版面修正：AI卡等高與控制列齊、MCP長路徑、設定長標籤與更新列、權限圖示、診斷卡、音訊動態本地化；三語、兩種視窗尺寸已逐張視覺檢查，完整回歸測試另記。
- [ ] 新版真正下載、更新安裝、重新啟動驗收；未公證可明示發布 beta，不把它描述成 Apple 已驗證。

## 本輪 build13–15 真機 AI、設定與完整配對

- [x] **MLX真機觀察／縮放任務通過**：34.111秒，實際工具順序`capture_frame → camera_zoom_status → camera_set_zoom(raw200) → capture_frame`；只有一次縮放，回讀verified、動作後及最終影格來自真實裝置／同session。之後恢復raw100及manual，cleanup確認。[結果](artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/result.json)、[工具與影格](artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/observation.stdout.json)
- [x] 該次MLX卸載後cache為0、active為4036 bytes；只描述MLX配置器，不寫成記憶體完全歸零或App RSS歸零。[卸載後](artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/after-model-unload.json)
- [ ] **Apple真機動作流程仍未完成**：build13回答有內容但`actions=[]`、raw仍100；build14文字計畫錯誤拒絕合法raw200，build15明確raw150也被拒絕，均未移動縮放。三份失敗保留；build16的新混合流程／roles修正尚未實測，不先標通過。[build13](artifacts/live-ai-2026-09-09/apple-6a154bec-4fd6-410d-b486-25a41b7abb21/result.json)、[build14](artifacts/live-ai-2026-09-09/apple-plan-15eb7103-ea06-41b9-8672-a8ef120d59a3/result.json)、[build15](artifacts/live-ai-2026-09-09/apple-build15-explicit-7d730d99-86c1-40b4-a1df-3da430989fbc/result.json)
- [x] 三份獨立Apple計畫提取結果與來源／instructions hash已保存；此為模型提取診斷，不是額外硬體成功。[來源紀錄](artifacts/apple-plan-extraction-2026-09-09/source-provenance.json)、[自然語句](artifacts/apple-plan-extraction-2026-09-09/current-natural.json)、[明確raw150](artifacts/apple-plan-extraction-2026-09-09/current-raw150.json)、[另一schema對照](artifacts/apple-plan-extraction-2026-09-09/associated-raw150.json)
- [x] 完整配對已到`credentialsReady`，且`samePrimaryRoute=true`、沒有呼叫Mac Wi-Fi join；只記錄狀態，不輸出密碼。[配對](artifacts/full-pair-control-2026-09-09/paired.json)、[網路核對](artifacts/full-pair-control-2026-09-09/network-check.json)
- [ ] **WB writer仍未生效**：pairOnly/build14與完整配對/build15各只送一次5600K，分別7／6筆回報仍Auto、都無ACK及matching readback，`applied=false`。原Auto未變，沒有restore寫入，也沒有盲重試。[pairOnly](artifacts/camera-settings-live-2026-09-09/white-balance-129a5c24-0e92-4fd2-acce-9596ce96fb68/result.json)、[full pair](artifacts/full-pair-control-2026-09-09/white-balance-43db759b-752c-4983-be27-ebbd04da92ae/result.json)
- [x] 使用者開啟視窗後，UI檢查`animationVerified=true`，可見manual button放開流程通過，pan由0到11880；不把先前screenUnavailable下的offset timeout當控制功能成功。[解鎖UI](artifacts/full-pair-control-2026-09-09/ui-check-after-user-open.json)、[手動操作](artifacts/full-pair-control-2026-09-09/manual-button-release-unlocked.json)
- [ ] 完整配對下的原生回中仍待真正提交與觀察：前次USB offset timeout時未發FE08；解鎖後另次只有2筆基線、間隔1.417秒，`baselineStable=false/localSubmitted=false`，所以不是FE08再次發送後失敗。USB cleanup在12240保持確認；稍後status回0原因未知，不歸因FE08。native preset等待期間保留heartbeat／drain的新修正已寫入，尚未實測。[offset前置失敗](artifacts/full-pair-control-2026-09-09/native-recenter-faa6cbbb-c2d1-42a5-a7d5-284bc00329fe/result.json)、[未提交的回中](artifacts/full-pair-control-2026-09-09/native-recenter-unlocked-5427968d-0030-4be5-bfaf-544fe80c2071/native-recenter.stdout.json)

## 相機重新開啟後的新證據

- [x] 恢復1080×1920@30 NV12，Roll原始值0→1→0有精確穩定回讀、不同的新影格與恢復結果。[單步實測](artifacts/hardware-roll-2026-09-09/one-step/result.json)
- [ ] Roll移動中停止、物理方向／角度與獨立AI驗證仍未完成；`rollStopValidated`不由Pan/Tilt或靜止保持自動開啟。
- [x] 不改Mac網路，重新配對同一BLE peer，取得電池100%／未充電及新鮮姿態。[遙測](artifacts/hardware-roll-2026-09-09/live-telemetry.json)
- [x] BLE `00/99`只讀通道取得實際相機回覆：AF-C、WB Auto、曝光Auto／EV0。[三項查詢](artifacts/hardware-roll-2026-09-09/properties/result.json)
- [x] 一般面板的只讀設定／讀取按鈕及5秒過期處理已完成，build 7 軟體 gate 和三項實機讀值通過。
- [x] BLE lens 只讀連續觀察已取得基線31筆／12.009秒，以及兩輪機身操作期間的37／35筆候選座標；未發送相機設定寫入或保存照片。[基線](artifacts/focus-live-2026-09-09/baseline-summary.json)、[本輪紀錄](docs/HARDWARE_ACCEPTANCE.md#2026-09-09-ble-lens-連續讀回與機身操作)
- [ ] 完成機身實際點按順序與 lens 座標的關聯驗證。第一輪使用者回報只點左上／右下、但誤觸鏡頭轉向，屬 confounded，不能解讀中途返回中心的原因；第二輪35筆、USB pan／tilt span均0，但實際操作順序仍待使用者確認。這些讀回不表示完整座標校準、App tap AF或光學合焦已完成。[第一輪條件](artifacts/focus-live-2026-09-09/body-tap/context.json)、[第二輪摘要](artifacts/focus-live-2026-09-09/axis-taps-7a14c2a3-c7fa-4c8f-b70e-e7c21c8b7c60/summary.json)
- [x] build13開發用BLE點選序列、每步800ms ACK／傳送額度等待與取消已實作；429項Release回歸通過，7個共用設計檔及三語檢查通過。[測試](artifacts/tap-focus-build13/release-tests.log)、[設計契約](artifacts/tap-focus-build13/design-contract.json)
- [x] 傳送額度等待已在真機生效：Prepare後等待10.472ms，再各一次提交Point；未重送Prepare。build12原先只送第一步便中止的結果保留。[build13結果](artifacts/focus-live-2026-09-09/tap-write-c80067c8-c513-4025-9545-332ba1ea889e/summary.json)
- [ ] BLE Tap AF仍未確認生效：本次Point 800ms內無ACK，Hint／Commit未送；期間2筆及稍後獨立12秒的30筆座標仍約中心，AF-C／Auto EV0保持。一般GUI不據此開啟；不以相同條件盲重送，下一步需查明Camera命令路由或可用的其他傳輸。
- [x] 公開beta1的橫幅NV12補驗：720p30、1080p24、4K30均取得新影格；1080p30另有本版smoke。這是已完成的子矩陣，不覆蓋所有格式、方向／黑邊或後續candidate。[矩陣](artifacts/public-beta1/nv12-landscape-matrix/b765fe71-749f-4261-a966-126179c87fea/result.json)、[build9 smoke](artifacts/public-beta1/hardware-smoke/result.json)
- [ ] 當前直幅輸出含機內影像的上下黑邊，方向／完整直幅內容仍待核對，不能僅憑1920高metadata算完成。

目前可用主路徑是 **USB 取像＋USB 按住／拖曳位置控制**。Mac 必須保留原有網路與網際網路連線；App 不要求加入相機 Wi-Fi，開發 join RPC 亦拒絕該操作。BLE 配對、電池與姿態有實測證據，原生馬達控制及快速預設仍未完成。速度拉條已移除；拖曳距離控制輸入幅度，UVC raw 速率不宣稱為校準物理速度。

## 歷史 build 5：電量提醒與只讀姿態

- [x] 已配對藍牙相機的低電量／持續下降提醒接入面板與原有 Yun 狀態膠囊。低量門檻20%；下降須多筆同peer/session有效資料，過期、斷線或重新選擇會清除，100%未充電不當故障。[規則與來源界線](docs/BLUETOOTH_TELEMETRY.md)
- [x] 普通配對面板顯示既有04/05回報的偏航、俯仰、翻滾；5秒有效期、序列去重與連線清理，不發新查詢、不覆蓋frame callback，也不當作USB座標校準或原生馬達成功證據。
- [x] 新增18項Core與1項App整合測試，本批總計351項Release測試（Intelligence21／Evaluation1／Core286／App43）。[日誌](artifacts/offline-telemetry-2026-09-09/final/test-gate.log)
- [x] 331個三語字串、7個未修改共用設計檔；41張UI＝29張一般介面＋12張明示遙測fixture。視覺檢查修正繼承自音訊App的Pitch譯名為「俯仰」。[UI](artifacts/offline-telemetry-2026-09-09/final/ui-gate.log)、[視覺核對](artifacts/offline-telemetry-2026-09-09/final/visual-review.json)
- [x] 更新簽章／偏好隔離、MCP／取消、搬移後MLX／Core AI推論與卸載、ZIP／DMG內版本及簽章再次通過。[產物](artifacts/offline-telemetry-2026-09-09/final/release-artifacts.json)、[包內核對](artifacts/offline-telemetry-2026-09-09/final/release-artifacts-verification.json)
- [ ] 真實低電量／持續下降提醒與失聯過期的完整UI場景仍待核對；重新配對後的電池／姿態及三項設定讀值已由上節實測補足，100%正常回報與fixture不能代替低量／下降告警驗收。

build 5 App SHA-256：`314f6cc8c769ce6640e36cbab6f989f71a4e192ce85c6947061b3904247751ac`。本批仍未驗實機影音／動作、公開更新／公證及鎖屏下popover動畫。

## build 4 離線驗證與交付基線

- [x] 本批 Release 332 項程式測試通過：Intelligence 21、Evaluation 1、Core 268、App 42；7 個共享設計檔、317 個三語字串及3組 C／ASan 檢查亦通過。[測試](artifacts/offline-2026-09-09/final/test-gate.log)、[設計／三語](artifacts/offline-2026-09-09/final/design-contract.json)
- [x] 四個更新 feed 簽章案例通過；本機測試 feed 不等於正式更新發布與安裝驗收。
- [x] 真實 Apple 模型＋**模擬相機**：zoom 狀態→單次 raw 200→新影格→明說模擬的回答通過。[result](artifacts/model-zoom-check/apple-E9E5E104-C10D-4534-A9AE-157863E477DE/result.json)、[log](artifacts/offline-2026-09-09/apple-zoom-model.log)
- [x] 已快取的真實 MLX 模型＋**模擬相機**：同一 zoom 流程通過，沒有下載模型。[result](artifacts/model-zoom-check/mlx-E203FD0E-3F39-4CF0-A3E3-5919636B82DD/result.json)、[log](artifacts/offline-2026-09-09/mlx-zoom-model-bundle.log)
- [x] **本批 build 4 完整 Release gate**：統一測試、MCP、29 張介面、搬移後 MLX／Core AI 推論與卸載，以及 ZIP／DMG 均通過。新視覺檢查發現並修正截圖語言未通知 footer 重繪；短／長提示列均30 pt、footer區38 pt，截圖不改已保存語言。[UI](artifacts/offline-2026-09-09/final/ui-gate.log)、[推論](artifacts/offline-2026-09-09/final/portable-inference.json)
- [x] signed-feed／loopback fixture 偏好隔離與清理通過：四個 feed 案例加上非測試 bundle 拒絕／零請求／偏好 sentinel 保留；空偏好域的清理誤判已修。[更新測試](artifacts/offline-2026-09-09/final/update-feed-verification/result.json)
- [x] 新 ZIP 解壓與 DMG 只讀掛載後的 App／CLI 簽章、版本與雜湊核對，以及卸載清理均通過。[產物](artifacts/offline-2026-09-09/final/release-artifacts.json)、[包內驗證](artifacts/offline-2026-09-09/final/release-artifacts-verification.json)

build 4 App SHA-256：`f6e3207c34510ae58ce808d20f3e7e58659fd431633bc34ffc8ac6428ff527d7`。該批桌面處於鎖定／休眠狀態，popover 動畫未重驗；離線版面與生命週期通過不等於該輪動畫通過。實機影音／動作、正式更新下載安裝及公證亦不在該 gate 的通過範圍。

兩份模型 result 均為 `simulation=true`、`physicalCameraAccess=false`，各只有一次模擬 raw 200 寫入；流程計時約 Apple 13.386 秒、MLX 37.832 秒。這證明真實模型的工具流程，**不是實體相機變焦、倍率或相機端動作證據**。另一份 MLX `ED86A580…` 只有 started／未 passed，不併入成功結果。

## 已落地的軟體能力

本節的勾選表示實作或相應離線基線已有證據；新增變更仍以本批 Release gate 驗證，硬體與公開發布條件另列。

- [x] 原生 App、MCP／CLI、同使用者 Unix socket、單一服務實例與統一 Pocket 3 Controller 名稱。
- [x] YunAudio／YunUI 共用設計、設定、選單列、圖標、三語、關於與更新介面；保持膠囊狀態列、原版提示列尺寸及手動控制美感。
- [x] 相機模式、橫直幅／幀率與 Auto／NV12／UYVY 選擇；宣告格式與實測可用性分開，拒絕不支援的組合，不靜默降級。
- [x] USB 連續目標、單一控制者、最新輸入合併、Stop／取消／連線生命週期 fence；一度步進保留為診斷工具。
- [x] Zoom 的 UVC raw 能力／有界寫入／回讀、App 滑桿、CLI／MCP 與內建 AI 工具；UI 百分比是行程位置，不標成校準倍率。
- [x] Zoom 待停止狀態跨 Task 取消保留，獨立 fresh hold、合併 pan／zoom 停止結果；新增步進容差與 UI 合併／取消／重連的離線測試。
- [x] 預覽 tap AF 的能力查詢、session 綁定與點按 UI 邊界已實作；當次 USB 能力不可用，不能據此勾選硬體功能完成。
- [x] Apple／MLX 圖片問答、Dynamic Profile、OCR／條碼、有限工具呼叫及動作後同 session 新影格綁定。
- [x] 固定模型 revision、下載／完整性校驗、取消／重試、部分下載清理、卸載與記憶體管理。
- [x] 音訊有界時間、PCM 格式／大小、單次測試與生命週期保護；完整串流驗證執行器已實作。
- [x] Core AI Float32 CPU／GPU 數值比對、Release 效能與 Vision 基線；保留 Float16 失敗，MPSGraph／GPU trace 不冒稱 ANE 使用證據。
- [x] 開發／保留題集、人工核對與 Apple Evaluations replay；保留模型計數及不實完成宣稱案例。
- [x] 預設診斷移除影像、裝置識別、活動及自由文字錯誤；獨立 Python 接入範例。
- [x] 集中錯誤呈現與有明確事件鍵的活動本地化；技術原文只限量保留於記憶體供進階診斷取用，不加進既有 Copy issue report／預設匯出。

## 已取得的實機基線

以下描述 2026-09-08 相機開啟時的驗收，不表示現在仍在取像／遙測，也不自動涵蓋後續新版本。

- [x] 三項韌體與 USB attachment／boot 已記錄：系統 `01.06.10.04`、相機 `10.00.50.51`、雲台 `01.00.15.81`。[韌體紀錄](artifacts/hardware-resumed/firmware.json)
- [x] 使用者確認機身拍攝方向後，五種直幅格式通過：720×1280@25／30、1080×1920@24／25／30。[矩陣](artifacts/hardware-resumed/portrait-matrix/47249823-ced5-4be7-954e-cce4aa2113d6/result.json)
- [x] 1080×1920 NV12／30 fps、雙聲道 48 kHz 的完整 30 分鐘影音與清理通過，1800.207 秒。[完整報告](artifacts/hardware-resumed/stream-final/EC740B6A-ECD5-4C48-89B1-8A797CF2D936/report.json)
- [x] 可見 AppKit 手動介面的按鈕放開、拖曳放開／失焦、服務端 Stop、App Stop 五組通過，USB 位置有變化。[按鈕](artifacts/hardware-resumed/manual-button-release.json)、[拖曳](artifacts/hardware-resumed/manual-drag-release.json)、[失焦](artifacts/hardware-resumed/manual-drag-focus.json)、[服務 Stop](artifacts/hardware-resumed/manual-button-remote.json)、[App Stop](artifacts/hardware-resumed/manual-button-stop.json)
- [x] 拖曳 near／far 的位移分別為 2160／8280 raw，約 3.83 倍；只證明輸入幅度改變回讀位移。[near](artifacts/hardware-resumed/manual-v2-near.json)、[far](artifacts/hardware-resumed/manual-v2-far.json)
- [x] 小角度 tilt 影像方向、名義 +5° 跨零及復位有回讀證據。[方向](artifacts/hardware-resumed/uvc-direction-images/result.json)、[跨零](artifacts/hardware-resumed/uvc-tilt-five-degrees/result.json)
- [x] USB 視角路徑研究取得正面→pan 648000→pan 0 往返與穩定回讀。[往](artifacts/hardware-resumed/manual-v3-flip-back.json)、[返](artifacts/hardware-resumed/manual-v3-flip-front.json)；慢速 approach 不等於機身原生快速預設。
- [x] **Zoom 100→200→100 已實機匹配成功**，沿用單次 SET 與較長只讀等待。[zoom-final](artifacts/hardware-resumed/zoom-final/result.json) 的 `set200`／`reset100` 均 verified；raw 100–400、step 1 不據此換算倍率。
- [x] BLE 發現／GATT／配對與 USB 預覽共存；註冊回覆修正後配對成功，再以 pairOnly 成功且不切換 Mac 網路。[註冊修正](artifacts/hardware-resumed/ble-pair-registration-fix.json)、[pairOnly](artifacts/hardware-resumed/ble-pair-only.json)
- [x] BLE 電池與姿態已有即時回報證據；電池百分比／充電狀態取自相機，不以 USB 500 mA 推算。[硬體紀錄](docs/HARDWARE_ACCEPTANCE.md)
- [x] 固定本機開發憑證、不同 App 二進位相同 DR／交叉驗證，且實際跨建置重連保留相機授權。[簽署與 TCC](artifacts/hardware-resumed/app-signing-retention.json)
- [x] 解鎖後 popover 動畫、視窗重開與當時版面尺寸通過；新 zoom／focus／錯誤本地化 UI 仍由本批 gate 回歸。[UI 基線](artifacts/hardware-resumed/ui-check.json)

## 相機重新開啟後的必要驗收

- [x] **build11 Zoom moving-stop 新規則實機讀回通過。** 從100請求400，讀到194、再200且仍moving時Stop；hold target／observed均200，內部11筆／0.847秒、其後8筆獨立讀回／0.899秒均穩定，原請求以CancellationError結束。之後明確恢復100亦verified。[Stop結果](artifacts/zoom-moving-stop-2026-09-09/7ec1044c-d59b-46fd-a823-23aaa20b8aea/result.json)、[恢復](artifacts/zoom-moving-stop-2026-09-09/7ec1044c-d59b-46fd-a823-23aaa20b8aea/restoration.json)。只驗本次有界途中停止，不涵蓋倍率、物理煞停延遲、完整UI拖曳／所有視角。
- [ ] Zoom 最新整合版的持續拖曳、取消／Stop、重連、gimbal 接管與新影格／視覺效果；校準倍率另行驗證。
- [ ] 使用者要求的機身搖桿 double／triple **原生快速回中與前後切換**。單次 FE08 已提交但3秒無回覆、30筆姿態無變化；FE09未由此得到成功證據，慢速 USB approach 不作產品替代。[FE08](artifacts/hardware-resumed/native-recenter-result.json)
- [ ] App 預覽 **tap AF** 的可用傳輸。使用者已確認 Pocket 3 **機身在 Webcam 模式可點按 AF**；當次 USB／AVFoundation 卻回報 point／auto／continuous 均 false。缺的是 host 控制路徑，不是機身 AF，也不能以 MF 拉條替代。[AVF 能力](artifacts/hardware-resumed/focus-capabilities.json)
- [ ] 完整宣告視角範圍、各姿態、物理角度／速度、平滑度、停止延遲與尾移校準；不以一次大角度往返或穩定 USB 回讀宣稱全範圍／機械停止通過。
- [ ] 收緊後的完整控制報告：每軸至少20次往返、中途停止、競爭控制、快速拔插／喚醒及動作後新影格。v3錯誤通過標記已撤銷；v4曾24次保持通過但首個目標未到位，整份仍未接受。
- [ ] 完成最新candidate的直幅方向／完整內容、黑邊、視窗縮放與切換重連，以及尚未覆蓋的格式組合。公開beta1的NV12橫幅子矩陣已通過；早期五種直幅的通過受當次機身方向限制，不涵蓋全部模式。未充分暖機的FPS失敗保留，不當作已證明不相容。
- [ ] UYVY 選項對應的 H.264 路徑與4K高幀率：多種 AVF output policy、延長20秒及解鎖環境仍無 sample callback；繼續核對 OBS 的實際影像及其他路徑，不能把選單宣告當可用。[解鎖對照](artifacts/hardware-resumed/uyvy-unlocked-20s.json)、[協議／格式證據](docs/HARDWARE_ACCEPTANCE.md)
- [ ] BLE 原生持續馬達控制。有效時序的200 ms低速脈衝沒有位移；04/50 readiness 查詢無回覆。已配對／可讀姿態不等於可控制馬達。[脈衝](artifacts/hardware-resumed/ble-native-probe-2/result.json)、[readiness](artifacts/hardware-resumed/ble-readiness-result.json)
- [ ] 完成真實相機下Apple及外部MCP的「先看→移動／縮放→新影格→回答」，以及拒絕、取消與錯誤恢復的完整流程。MLX的單次raw200真機任務已由上節補足，不再把全部真模型zoom證據寫成simulation；它仍不代替Apple、外部MCP或全視角驗收。
- [ ] USB 供電／未知充電提示的最新 UI 與實機回歸；不把配置電力當實際充電功率或電池回報。

## 其他本輪功能與外部發布條件

- [x] DUML CRC／fragment／ACK／session 邊界、BLE 配對及原生 UDP codec 已實作；Wi-Fi join／datalink 保留研究，不是主流程或可用控制的前提。
- [ ] 曝光、白平衡、色彩、機內拍攝、音訊等機身設定逐項接入並驗證；首批協議整理不代表全部設定可寫。[路線圖](docs/DEVICE_CAPABILITY_ROADMAP.md)、[設定協議](docs/CAMERA_SETTINGS_PROTOCOL.md)
- [ ] 追蹤、素材、配件與其他機身選項依可靠協議證據擴充。
- [x] 本專案正式appcast／公鑰／archive位置及公開下載／簽章核對已完成，見上節Beta發布紀錄；不再列為待配置。
- [ ] 以已發布beta1實際更新至下一個可發布版本，驗證安裝／替換／重啟與偏好、相機／IPC清理；signed feed有效及公開下載成功不代替這一步。
- [ ] Developer ID／公證及公開分發驗收。本機版已有固定開發簽署，不再稱無有效本機身分；公開發布條件尚未完成，也不阻止可離線完成的工作。

## 歷史證據與已被取代的狀態

- 歷史 Release gate `dea96ce0-836f-482b-bdbc-c956ed0400f5`、`0603c8a1-9d0f-4ed9-ba6f-afff1b550c80`、`70f2eff4-39f3-4030-b8c9-e22802359302` 與 App／CLI、ZIP／DMG、搬移 App 隱藏 `.build` 後的 MLX／Core AI 推論保留為**各自批次**證據；不替代本批 build 4。[驗收歷史](docs/ACCEPTANCE_AUDIT.md)
- 較早的2026-09-09 Debug 批次記錄 Core 268／App 41 等測試通過；先前 Core 236／App 26 亦只描述當時批次，不再稱為最新。[Debug 日誌](artifacts/offline-2026-09-09/debug-tests.log)、[較早整合日誌](artifacts/hardware-resumed/zoom-focus-native-tests.log)
- 2026-09-08 的軌跡批次另有重建／打包摘要，也不代表後續 zoom、focus、原生預設或語言修正的新包通過。[摘要](artifacts/hardware-resumed/github-trajectory-summary.json)
- 早期「尚缺完整長測執行器／只有模擬 timeline」與首輪音訊配置停流的紀錄保留；後續已補執行器並取得上列指定模式1800秒通過，不再寫成現在仍完全沒有30分鐘影音證據。
- 早期「桌面鎖定／首次藍牙授權未決定／新簽署 App 尚未授權」均是當時限制；後續解鎖、藍牙配對與跨建置相機權限保留已有證據。
- 早期「DUML 電池只用 fixture／尚未接入即時遙測」及「相機關機待恢復」已由重新配對／即時回報補足；每次仍以當前session與有效期判定，不能把歷史電量當目前狀態。
- Zoom 舊短窗口停在164／返回停在128的未確認結果保留，後續100→200→100已匹配。舊`zoom-final`整體`passed=false`不改寫；本次新Stop規則通過見上節。另一輪100→200太快到位，未捕捉途中Stop，`not_confirmed/passed=false`亦保留，不能借靜止Stop算通過。[舊窗口](artifacts/hardware-resumed/zoom-live/result.json)、[舊Stop判定](artifacts/hardware-resumed/zoom-final/result.json)、[未捕捉中途停止](artifacts/zoom-moving-stop-2026-09-09/36fbbb32-110d-4f0d-88bc-2d6fd01a15f1/result.json)
- 直接單次180°未到位、BLE脈衝／FE08未觀察到作用、H.264無回呼及未完成的MLX嘗試均不刪除、不改成通過。

## 1.0 後、尚未提升為首發需求

- [ ] App Intents 擷取／暫停。
- [ ] 按鍵收音與 SpeechAnalyzer。
- [ ] 指定觀察區域、look_at、同視角比較。
- [ ] 遠端 HTTP／headless host 依具體部署需求決定。BLE／機身設定已屬本輪擴充，不能再一概延後；切換 Mac Wi-Fi 則不符合使用者限制。
