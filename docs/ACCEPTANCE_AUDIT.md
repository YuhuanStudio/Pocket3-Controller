# 1.0 驗收對照

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

## 目前範圍與判定（build5，2026-09-09）

**0.1.0／build5完整Release gate已通過**：run `d26e463e-24b5-4ce0-9b9f-85feb904a6b4`，App SHA-256 `314f6cc8c769ce6640e36cbab6f989f71a4e192ce85c6947061b3904247751ac`。[固定報告](../artifacts/offline-telemetry-2026-09-09/final/verification-gate.json)。本批新增BLE低電量／持續下降提示與只讀姿態顯示，通過351項Release測試（21＋1＋286＋43）、331條三語／7個共用設計檔、41張UI（29一般＋12遙測純fixture），以及搬移MLX／CoreAI推論與卸載、MCP、更新簽章／偏好guard、ZIP／唯讀DMG payload驗證；「Pitch→俯仰」修正後重新完整執行。[UI與語言](../artifacts/offline-telemetry-2026-09-09/final/ui-gate.log)、[目視紀錄](../artifacts/offline-telemetry-2026-09-09/final/visual-review.json)、[產物](../artifacts/offline-telemetry-2026-09-09/final/release-artifacts-verification.json)。**新遙測UI的12例不是真機回報驗收**；實際電量下降／姿態面板、配對與斷線回歸仍待相機開啟。BLE提示不當USB供電故障、姿態未與USB校準；原生快速preset、tap AF、H.264、全範圍與公開發布條件仍未完成。本批popover動畫因鎖屏未重驗，整體1.0不標完成。

## build4驗收快照（2026-09-09，歷史保留）

本輪 **0.1.0 / build4完整Release gate已通過**，是重新完整執行、不是resume：run `beede929-3b74-49a0-895f-33cbe67f49ee`。[完整報告](../artifacts/offline-2026-09-09/final/verification-gate.json)。App executable SHA-256為 `f6e3207c34510ae58ce808d20f3e7e58659fd431633bc34ffc8ac6428ff527d7`，與本批更新fixture及安裝包manifest一致。使用者已關閉相機；本批未做新實機取像／控制。範圍仍依最新要求與 [TODO](../TODO.md)，整體1.0未完成。下方舊表與gate段落為歷史快照，不能覆蓋目前判定。

| 項目 | 目前可確認的證據 | 不能延伸的宣稱 |
|---|---|---|
| 指定格式30分鐘影音 | 1080×1920 NV12／30fps、stereo48kHz，1800.207秒與清理通過。[報告](../artifacts/hardware-resumed/stream-final/EC740B6A-ECD5-4C48-89B1-8A797CF2D936/report.json) | 不等於4K／H.264、所有格式或所有新版本工作負載均通過。 |
| 手動USB控制與介面 | 已接入按住／拖曳，放開、失焦、服務端Stop／App Stop有可見AppKit輸入surface實測；拖曳距離會改變USB回讀位移。[精確數據](HARDWARE_ACCEPTANCE.md) | USB讀回與軟體清理時間不是物理速度、機械停止／尾移或全範圍校準。 |
| 本機簽署與UI | 固定本機開發憑證；本批29張UI、視窗／popover生命週期、暫時語言修正與saved preferences未變通過。兩張banner實測30pt、footer38pt。[UI結果](../artifacts/offline-2026-09-09/final/ui-gate.log)、[截圖保存與清理政策](TEST_ARTIFACTS.md) | **本次popover動畫因鎖屏／休眠未驗證**；歷史解鎖動畫與TCC保留證據另存，不冒充本批重測。[本次界線](../artifacts/offline-2026-09-09/final/parity/ui-check.json)、[歷史紀錄](HARDWARE_ACCEPTANCE.md)。 |
| 真實模型＋模擬相機zoom流程 | Apple與已快取MLX各完成一次：讀zoom狀態→單次raw200→新影格→明說模擬的回答，兩份result均passed。[Apple](../artifacts/model-zoom-check/apple-E9E5E104-C10D-4534-A9AE-157863E477DE/result.json)、[MLX](../artifacts/model-zoom-check/mlx-E203FD0E-3F39-4CF0-A3E3-5919636B82DD/result.json) | 模型推論是真的；camera是simulation、physicalCameraAccess=false。不是實體變焦、相機動作或zoom倍率證明。 |
| 原生快速preset、tap AF、H.264、完整範圍 | **仍未完成。** FE08單BLE試驗無回覆／無姿態變化；當次USB/AVF不提供tap AF能力；H.264多種輸出policy仍無回呼；完整宣告範圍與所有姿態未驗收。[硬體證據](HARDWARE_ACCEPTANCE.md) | 慢速USBTargetApproach或MF拉條不符合原生快速double／triple與tap AF要求，不當產品替代。 |
| build4完整Release gate | **通過**：332項Release測試、317條三語字串、7個未變更共用設計檔、3套C/ObjC ASan、UI、離線MCP／取消、搬移App後MLX／CoreAI推論與卸載。[測試](../artifacts/offline-2026-09-09/final/test-gate.log)、[設計](../artifacts/offline-2026-09-09/final/design-contract.json)、[搬移推論](../artifacts/offline-2026-09-09/final/portable-inference.json) | 不包含新實機取像／影音／運動停止、公開更新、Developer ID／公證與本次popover動畫。 |
| signed-feed與非fixture偏好保護 | **通過**：4個簽章fixture各一次request，valid通過、wrong-key／tampered／unsigned拒絕；非fixture bundle偽造env被拒絕、零request、sentinel保留且測試域清空。run `2687c1ef-932d-4178-86f4-d6cda27eb017`。[報告](../artifacts/offline-2026-09-09/final/update-feed-verification/result.json) | 僅loopback；未下載／安裝更新，不等於公開feed或正式更新鏈已驗收。 |
| ZIP／DMG與payload | **通過**：ZIP解出及唯讀DMG內App／CLI的簽章與hash；release artifact run `79019385-e2bd-4681-a6cd-3d642b6dc999`。[manifest](../artifacts/offline-2026-09-09/final/release-artifacts.json)、[payload驗證](../artifacts/offline-2026-09-09/final/release-artifacts-verification.json) | 本機開發簽署、notarized=false；不是公證公開版。 |

兩個模型測試框架耗時分別為 **Apple13.388秒、MLX37.843秒**（[Apple log](../artifacts/offline-2026-09-09/apple-zoom-model.log)、[MLX log](../artifacts/offline-2026-09-09/mlx-zoom-model-bundle.log)）；result內流程計時分別13.385917／37.832005秒，量測範圍不同。兩者均使用現有本地模型與測試圖片，`simulation=true`、`physicalCameraAccess=false`、沒有下載模型。另一個MLX `ED86A580…`只留started/未passed，不能併入成功結果。

公開發布位置、永久feed／公鑰／archive與Developer ID、公證的驗收仍列外部發布條件。[離線稽核](OFFLINE_REMAINING_AUDIT.md) 是修正前的查讀快照；其中MCP契約、動態字串與本批gate缺口的最新驗證以上述完整結果為準，不刪除歷史失敗。

## 歷史驗收快照（保留）

更新：2026-09-08。範圍依 `BUILD_PROPOSAL.md` 第 8、10、15 節及使用者後續要求。實作、離線驗證、實機驗證是不同證據；整體 1.0 尚未完成。

| 要求 | 當前判定 | 可核對證據／剩餘工作 |
|---|---|---|
| macOS 27 原生 App＋MCP＋CLI | 已實作並離線驗證 | `Package.swift`、`artifacts/verification-gate.json`、`dist/release-artifacts.json` |
| 統一 Pocket 3 MCP 名稱 | 已完成 | `Resources/Info.plist`、`Scripts/check-design.py` |
| YunAudio／YunUI 原美感與通用 App 功能 | 實作完成，動畫尚缺 | 7 個共用檔雜湊、`docs/YUNAUDIO_PARITY.md`、`artifacts/parity`；未在鎖屏時宣稱動畫通過 |
| 提示列內距／高度、底部膠囊與版面 | 已量測；新增狀態已隨最後 gate 重測 | `BannerLayoutTests`、`LayoutMeasurement.swift`、`ui-parity.py` |
| 設定、選單列、Dock、登入啟動、關於 | 已實作 | 視窗／host 生命週期檢查；登入項目未為測試修改使用者系統設定 |
| 首次權限與拒絕後恢復 | 實作完成，系統端驗收受限 | `FirstLaunchPermissions.swift`、設定權限頁、Native TCC；相機已關閉 |
| 裝置匹配與 USB 控制端對應 | 程式具備，最新實機未驗收 | VID/PID、location、registry attachment、boot ID；等待相機和韌體資訊 |
| 1080p30／4K30，新鮮影格、方向及不靜默降級 | 最新版本待實機 | 先前基線成功不能代替最新設定；需重測格式、黑邊及視窗縮放 |
| 有界 pan／tilt、單一控制者、停止優先 | 程式與模擬通過，實機未完成 | `OperationPermitTests`、`ObservationBoundaryTests`；版本 3 停止報告待取得 |
| 停止、取消、人工接管與未知結果 | 軟體邊界通過，實機待測 | stamp、寫入許可、撤回移動權、IPC/MCP 取消；不把 sent 當作物理完成 |
| 斷線、重連、休眠／喚醒 | 程式與模擬覆蓋；實機待測 | `CameraService`、session 測試；沒有以 OS 真正睡眠和 USB 重插驗收最新版本 |
| 單張圖片、来源／時間、儲存位置 | 基線已測；新版整合待相機 | JPEG 實際尺寸 metadata；使用 NSSavePanel，不默默保存一般影像 |
| 有界相機音訊測試 | 程式保護與格式測試通過，實機待測 | Duration、PCM layout、獨立計數、TCC 等待期間的 session 檢查；最新 PCM 需實機；已備妥串流驗證的每秒數值與清理流程 |
| Apple 圖片問答與結構化輸出 | 已實测 | `artifacts/evaluation/development`、`heldout`，保留已知模型錯誤 |
| MLX 固定模型、下載、取消、卸載／記憶體 | 已實作並分層測試 | 真實下載／載入／推論／卸載；隔離 transfer 的取消、重試與刪除狀態測試；未把模擬 transfer 稱為 CDN 實測 |
| Foundation Models 27 Dynamic Profiles／工具 | 離線端到端通過 | 兩模型模擬「移動→新圖→OCR→回答」、權限拒絕及圖中文字注入；實機流程仍待相機 |
| Vision OCR／條碼 | 離線通過 | 模擬工作流程、`BarcodeTests`；結果綁定各自的影格 |
| Core AI 模型／轉換／裝置／效能 | 已有實驗結果 | Float32 通過數值門檻；Float16 未通過；MPSGraph／Metal trace；Release 與 Vision 子任務比較 |
| Apple Evaluations、開發與保留題集 | 已執行 | `.xcevalresult`、人工核對四個保留回答；不以 lexical 通過率當作一般正確率 |
| 四個 MCP tools、圖片與明確錯誤 | 協議與基線通過；動作端到端待實機 | 真實 JSON-RPC 客戶端、offline、cancel 測試；SDK 0.12.1／2025-11-25 |
| 獨立模型 API／程式範例 | 已提供 | `Examples/observe.py`、README；最後 gate 包含模型 API 路徑，範例不另開 USB |
| 診斷與資料保護 | 程式測試通過 | `DiagnosticsTests`；移除影像、識別碼、活動與自由文字錯誤 |
| 30 分鐘影音、每軸 20 次往返 | 尚未完成當前驗收 | 早期往返基線存在；`validate-stream.py`／`StreamValidationTests` 已備妥並只用模擬資料驗證，30 分鐘真實影音及版本 3 整合待硬體 |
| 搬移、資源自足、Release、ZIP／DMG | 已測，變更後以最後 gate 更新 | 複製 App＋隱藏 `.build` 的實際推論、只讀掛載、codesign 和 checksum |
| 更新檢查及安裝 | 引擎／介面完成；發布鏈未驗收 | Sparkle；尚缺本專案發布 URL／公鑰與真實 feed。已詢問發布位置 |
| Developer ID／公證 | 外部條件未具備 | 本機目前 ad-hoc；不能宣稱公開分發版完成 |
| App Intents／語音／ROI／look_at／Wi-Fi／HTTP | 依原計畫延後 | 不把未列入首發的部署與語音需求默默加進 1.0，也不宣稱已完成 |

## 最後 gate 的含義

`Scripts/verify.sh --release --ui --models --package` 會建置並重開同一份 App，驗證程式測試、共用設計、字串、資源、MCP、UI、搬移推論及安裝包。報告先標為 running／未通過，失敗時改為 failed，避免留下舊的綠色結果。

它明確列出未檢查的實機、公開更新、公證與鎖屏時的動畫。實機缺項仍阻止宣稱本機產品完成。公開更新、Developer ID 與公證屬公開發行的外部條件；依原提案不阻擋本機交付，但必須另行標示未完成。

## 本輪結論

截至目前，可在相機關閉、螢幕鎖定環境中完成的首發軟體實作與驗收已通過最後 Release gate。新發現的下載狀態、音訊生命週期、PCM 格式及 SIGPIPE 問題已修復，核心取消測試連續五次通過。公開更新設定工具及四項驗證測試已就緒，沒有套用虛構 feed 或私鑰。

整體仍未完成：最新 USB／影音／30 分鐘／版本 3 控制驗收、解鎖後動畫，以及尚未提供的發布來源與正式簽署條件。這些不能以離線測試或「程式已存在」代替。

最新完整離線 gate：`dea96ce0-836f-482b-bdbc-c956ed0400f5`，Release；`artifacts/verification-gate.json` 已完成。當前沒有未結束的建置或驗證程序需要等待。

補齊串流執行器後的 Release gate：`0603c8a1-9d0f-4ed9-ba6f-afff1b550c80`；同樣明列實機、動畫與外部發布未驗收。

## 2026-09-08 範圍更新

相機已恢復，使用者又要求完整可用視角、前後轉向、回中、更多橫直幅格式、充電提示與盡力支援機身設定。新判定以 [DEVICE_CAPABILITY_ROADMAP.md](DEVICE_CAPABILITY_ROADMAP.md) 的 P0–P3 为準，不再將所有無線／相機設定一概延到 1.0 後。

本輪先前的 v3 通過標記已撤銷，因單筆保持超差被「每軸至少一筆通過」掩蓋。v4 收緊後 24 次保持均通過，最大偏差 360；第一個位置目標未到位，所以整份仍不接受。正在納入 UVC 生命週期修復與穩定起點重測。第一輪長測在音訊配置期間停影約82秒，已保留失敗並取消；配置完成時序已修，仍須重跑完整 30 分鐘。

最新整合版軟體 gate：`70f2eff4-39f3-4030-b8c9-e22802359302`，Release，全項軟體檢查通過。初次 gate `28cb5db3-79d5-4754-b4ce-3bffd8521f83` 的失敗在 DMG 仍被 DiskImages 持有，已保留；改用 macOS 27 `diskutil image create from` 與唯一暫存檔、驗證後再替換，完整流程重跑通過。模型搬移兩次均通過，不是模型失敗。

固定開發憑證已使兩個不同 App 的 designated requirement 相同並通過雙向驗證；並未改動系統憑證信任。實際相機授權跨建置保留仍待使用者解鎖並先授權新身分。公開發行身分與公證仍未配置。
