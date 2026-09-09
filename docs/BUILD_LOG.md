# 歷史構建紀錄

以下保留前期原始進度記錄；當前狀態以 TODO.md 與 ACCEPTANCE_AUDIT.md 為準。

# Pocket 3 MCP — 構建進度

更新：2026-09-07。使用者已授權依構建提案逐步實作。只有實際完成並驗證的項目才打勾。

## A. 原生 App 與最小完整路徑（進行中）

- [x] 確認產品範圍：macOS 27 原生 AI 觀察 App＋MCP＋CLI。
- [x] 建立 Swift 套件、App bundle、可重現 build／package 腳本。
- [x] 建立 UVC 模組與共享資料契約，動態匹配 Pocket 3 裝置。
- [x] App 權限、預覽、單張圖片與本機 bridge。
- [x] CLI／MCP 能向 App 取得真正的新影格。
- [ ] 查核 Apple 本機模型、MLX Swift 和 Core AI 的實際可用性。

## B. 控制核心

- [ ] 有界動作、單一控制者、停止優先、取消與未知結果處理。
- [ ] 新鮮影格、session 失效、斷線／重連、休眠／喚醒。
- [ ] 小幅往返、中途停止與控制後畫面驗證。
- [ ] 核心、IPC、MCP 的有效測試。

## C. 日常 App（沿用 YunAudio／YunUI）

完整對照：[YUNAUDIO_PARITY.md](docs/YUNAUDIO_PARITY.md)。包含 App 應用層，不能只驗收元件外觀。

- [x] 原生相機／觀察、引擎與接入、診斷頁面。
- [x] 選單列、關窗／退出、手動接管、隱私暫停。
- [ ] 首次引導、錯誤與恢复、設定和診斷匯出。
- [ ] 有界 USB 音訊診斷。
- [x] 獨立設定視窗：一般／外觀／相機／權限／快捷鍵／診斷／關於。
- [x] Sparkle 更新引擎、自訂更新選擇、更新來源可用性與安裝位置判斷。
- [ ] 發布本專案 signed appcast／公鑰並驗證實際更新下載與安裝。
- [x] 原生選單列 popover、右鍵選單、Dock／登入啟動選項。
- [x] 完整狀態條、共用圖標、語言切換與資源打包。
- [ ] 逐頁對照母版：主頁、設定、關於、更新、選單列、最小尺寸與淺深色。

## D. 本機 AI 與外部整合

- [ ] Foundation Models 27 圖片問答、結構化結果、工具與 profile。
- [ ] MLX VLM 模型選擇、下載、取消、卸載及記憶體管理。
- [ ] Vision OCR／圖像分析與證據影格。
- [ ] Core AI 感知實驗與執行裝置／效能紀錄。
- [x] 四個 MCP tools 與至少一個真實協議客戶端驗證。
- [ ] 最小獨立模型 API／程式整合示範。

## E. 驗證與交付

- [ ] 30 分鐘影音與每軸 20 次往返測試。
- [ ] AI 固定題集／保留題目，記錄事實和操作品質。
- [ ] App 啟停、取消、錯誤、重連與打包後驗證。
- [ ] README、支持矩陣、第三方授權、變更紀錄。
- [ ] 交付可執行 `.app`、CLI 與本地安裝包。
- [ ] 公開分享版 Developer ID／公證（取決於發布憑證，與本地交付分開）。

## 1.0 後增量

- [ ] App Intents：擷取／暫停。
- [ ] 按鍵收音與 SpeechAnalyzer。
- [ ] 指定觀察區域、返回視角、look_at、同視角比較。
- [ ] 需求成立後才加入 Wi-Fi／遠端 HTTP／headless host。

## 執行紀錄

- 已有 USB 1080p／4K30、小幅 pan／tilt 與 PCM 短測；這些是開發基線，尚非產品驗收。
- 正式構建開始；每階段的測試和實際限制會持續補記。

- 2026-09-07：原生 App／CLI 編譯成功，5 個核心測試通過；已收到實機影格。
- 直接重用 YunAudio 的 YunDesign、WindowChrome 與 WindowFrame；模型卡片／活動參考 YunUI。來源專案保持未修改。
- MLX Swift 的 27 SDK bridge 已固定 revision；已加入可重現 metadata 相容修補。
- YOLOS-tiny 已經由 Apple Core AI 匯出流程轉為 float16 模型，待 App 實際推論量測。
- 本機沒有有效 Developer ID／Apple Development 簽章身分；現階段為 ad-hoc 本機開發版，未宣稱已公證。

- 啟動崩潰已定位為上游控制名稱快取未持有 autoreleased NSArray；已修正並加入 100 次釋放池回歸測試。另補上 JSON 例外邊界與 pan=0 的資料解析回歸。
- 本機 UVC 原始讀回已恢复，正在做持續狀態／影格回歸和真實 MCP 協議測試。

- 2026-09-07：名稱統一 Pocket 3 MCP，保留私有 bundle identifier／快取路徑以維持既有資料。
- 使用者澄清：沿用視覺設計，只改相機相關資訊；已撤回另行設計的底部工具列，恢復 YunAudio 膠囊狀態列。
- 使用者回報提示列上下空白過大：已直接移植 errorBanner，移除撐高列的額外關閉按鈕，補上長／短訊息高度回歸。
- 60 秒啟動回歸已通過 252 次狀態查詢；真實 MCP JPEG 和 Apple 圖片問答已通過。
- 每軸 20 次小幅往返的 80 個目標讀回通過；停止證據的舊判準可能將反向抖動計入，因此已改為同軸、朝目標至少 720 UVC 單位的進度，舊報告不再解鎖 AI 移動，等待新一輪驗證。

- UI 修正驗證：實際三欄尺寸／間距／對齊、按鈕邊界、footer 不重疊、settings 重開與 popover 釋放通過；160 個靜態 App 字串有三語資源，7 個共用設計檔保持原樣。
- 相機實機輸出曾在 1920×1080 與含黑邊的 1080×1920 之間變更；需另行釐清 macOS video effects／AVFoundation 格式協商，不能用裁切 UI 掩蓋來源影格问题。

## 2026-09-08：離線完善（相機由使用者關閉）

- [x] 實際 MLX 圖片推論、模型卸載與配置記憶體量測。
- [x] 加入 Dynamic Profile、取像／OCR／條碼／有界移動工具及來源綁定。
- [x] 模擬相機下的 Apple／MLX「移動後取像與讀字」端到端流程。
- [x] 取消、排隊工具、移動上限、人工接管及連線失效的程式測試。
- [x] IPC 取消與斷線傳遞，繁忙時仍接受停止；避免描述符回收後錯寫。
- [x] 圖片問答開發題集與初步人工檢視；已記錄計數與完成宣稱問題。
- [x] Core AI Float32 CPU／GPU 偏好路徑通過原始模型數值比對；Float16 未通過，已記錄。
- [x] 原子組裝／替換 App，避免覆寫正在執行的 bundle。
- [ ] Apple Evaluations 正式紀錄輸出與保留題集。
- [ ] 模型／MCP 新增路徑的完整打包驗證、Release 與安裝包。
- [ ] Core AI 實際執行裝置 trace、Release 效能與比較。
- [ ] 實機影格格式、30 分鐘穩定性與版本 3 停止驗證，等待使用者重新接上相機。

詳見 `docs/AI_VALIDATION.md`；上述模擬測試不得替代實機驗收。

- 已完成 Release 實際搬移推論：將 App 複製到 /tmp、隱藏 .build 後，MLX 讀出 TEST-4826、Core AI 偵測兩隻貓，卸載後配置快取歸零。
- Apple Evaluations 已輸出正式 .xcevalresult；保留題集四個 Apple／MLX 回答經人工核對正確，開發題的計數失敗仍保留。
- Core AI Instruments 以啟動模式取得 136 筆框架事件、43 次 MPSGraph 呼叫及目標 App 的 M3 Max GPU Compute 活動；沒有觀察到 ANE 區間。
- 已製作本機 ZIP／DMG，磁碟映像核對碼通過；正式簽章、公證與更新發布仍待外部設定。
- 螢幕已鎖定且顯示器休眠，無動畫的五次 popover 開關／host 釋放及其餘版面检查通過；正常動畫互動待解鎖後補驗。
- 尚待整理最終交付文件／驗證摘要、Release 效能複測及最後原生 App 狀態；相機實機驗收依使用者要求暫停。
