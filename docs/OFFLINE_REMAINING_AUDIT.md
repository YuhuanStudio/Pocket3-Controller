# 離線剩餘工作稽核

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

2026-09-09續行稽核另找到並完成兩項原需求：低電量／持續下降提示，以及普通藍牙配對面板的只讀姿態。build 5的實作與完整離線驗收見[功能說明](BLUETOOTH_TELEMETRY.md)及[固定gate](../artifacts/offline-telemetry-2026-09-09/final/verification-gate.json)。真實電量變化與新面板的實機回歸仍待相機開啟；以下build4收尾与更早查讀快照保留。

## 2026-09-09 收尾結果

本次稽核找出的三項可離線缺口已完成：MCP 在 IPC 前嚴格驗參數、動態錯誤／活動三語呈現，以及同批 Release 整合與打包。**build 4 完整 gate `beede929-3b74-49a0-895f-33cbe67f49ee` 通過**，見 [固定報告](../artifacts/offline-2026-09-09/final/verification-gate.json) 與 [目前 TODO](../TODO.md)。下方是修正前的查讀快照，保留用來追溯發現，不能再把其「尚待編譯」「正在修」當成目前狀態。

本批共有332項Release測試、7個未更動共用設計檔、317個三語字串、29張UI擷取、3組C／ASan，以及搬移App後的MLX／Core AI實際推論／卸載。更新測試驗證4種簽章情境及測試身分／偏好隔離；ZIP解壓與DMG只讀掛載中的App／CLI也完成簽章、版本、雜湊與清理核對。實際看圖另找出截圖工具切換語言時footer未重繪，已修並重新跑完整gate；兩種提示列實測30pt，底部狀態區38pt，保存的語言未改動。

實機快速預設、tap AF傳輸、所有格式與全範圍、物理停止／尾移、AI實機操作，以及公開更新／公證仍未完成。當前鎖屏使本批popover動畫無法驗收；歷史解鎖動畫證據另存。兩份真Apple／MLX zoom工具測試使用模擬相機，不能代替實機。整體1.0不標記完成。

## 修正前稽核快照

2026-09-08，相機由使用者關機後查讀。對照 [BUILD_PROPOSAL](../BUILD_PROPOSAL.md) 第3–11、15節、[PROJECT_PLAN](../PROJECT_PLAN.md) 第44–122行與 [TODO](../TODO.md)，以使用者後續要求（USB主路徑、不換Mac網路、原生快速預設、tap AF）覆蓋舊提案。此稽核未執行SPM、App、相機或硬體測試；「有原始碼」「離線通過」「實機通過」分開記錄。

## 要求對照

| 計劃要求 | 原始碼／測試證據 | 當前剩餘與分類 |
|---|---|---|
| macOS App＋同核心CLI/MCP；不依賴Yunmo | [Package.swift](../Package.swift)、[AppEntry](../Sources/Pocket3BridgeApp/AppEntry.swift)、[CLI](../Sources/pocket3/Pocket3CLI.swift) | 架構已具備；不是缺一個server。新改動需同批離線gate與bundle驗證。 |
| YunAudio美感、設定、語言、關於、Dock／登入啟動 | [SettingsWindow](../Sources/Pocket3BridgeApp/SettingsWindow.swift)、[InterfaceOptions](../Sources/Pocket3BridgeApp/InterfaceOptions.swift)、[Theme](../Sources/YunDesign/Theme.swift)、[Localization](../Sources/YunDesign/Localization.swift)、[design gate](../Scripts/check-design.py) | 共用元件／持久設定已實作。**動態錯誤文字在不同語言下的呈現仍有離線可補缺口**；見下方優先項。登入項目需實際系統註冊才能完成OS端驗收，不應為測試擅改使用者設定。 |
| 底部狀態膠囊與選單列／關窗常駐 | [StatusPills](../Sources/Pocket3BridgeApp/StatusPills.swift)、[StatusItem](../Sources/Pocket3BridgeApp/StatusItem.swift)、[BannerLayoutTests](../Tests/Pocket3AppTests/BannerLayoutTests.swift)、[UI parity](../Scripts/ui-parity.py) | 已有原美感元件與生命週期驗證；新zoom/focus/離線錯誤狀態仍應納入本批UI回歸，不能拿舊截圖概括。USB charging unknown不能直接換成未建立USB關聯的BLE電池值。 |
| 初次權限／拒絕後恢復、麥克風按需啟用 | [FirstLaunchPermissions](../Sources/Pocket3BridgeApp/FirstLaunchPermissions.swift)、[Settings權限頁](../Sources/Pocket3BridgeApp/SettingsWindow.swift#L166)、[CaptureEngine](../Sources/Pocket3Core/CaptureEngine.swift)、[AudioTestPolicyTests](../Tests/Pocket3CoreTests/AudioTestPolicyTests.swift) | 程式存在；真實TCC拒絕／重新授權及裝置輸入需OS／硬體，不等於缺source。可離線測UI文案／state presentation，不應把reset TCC列普通回歸步驟。 |
| 裝置偏好、正確相機、重連後舊操作失效 | [CameraSelection](../Sources/Pocket3BridgeApp/CameraSelection.swift)、[選擇測試](../Tests/Pocket3AppTests/CameraSelectionTests.swift)、[AttachmentBindingTests](../Tests/Pocket3CoreTests/AttachmentBindingTests.swift)、[USBContinuousGimbalTransportTests](../Tests/Pocket3CoreTests/USBContinuousGimbalTransportTests.swift) | 核心與fake-I/O邊界已寫；真實拔插／睡眠、跨模式與全範圍仍屬硬體驗收。 |
| 四個原MCP工具、圖片metadata、明確錯誤／取消 | [MCPCameraToolContract](../Sources/Pocket3Core/MCPCameraToolContract.swift)、[CLI handler](../Sources/pocket3/Pocket3CLI.swift#L205)、[contract tests](../Tests/Pocket3CoreTests/MCPCameraToolContractTests.swift)、[MCP smoke](../Scripts/mcp-smoke.py)、[cancellation test](../Scripts/mcp-cancellation-test.py) | **本輪稽核發現並獲root授權修正**：非zoom工具原先只宣告schema而未在IPC前驗參數。source／6項Core tests／隔離smoke已補，尚待root編譯執行；不能把camera_not_ready當驗參數通過。 |
| MCP連線可見、連線測試、不假冒客戶端身分 | [IntegrationStatus](../Sources/Pocket3BridgeApp/IntegrationStatus.swift)、[IntegrationStatusTests](../Tests/Pocket3AppTests/IntegrationStatusTests.swift)、[IPC](../Sources/Pocket3Core/IPC.swift) | nonce ping與有限請求紀錄存在；UI明確是request而非持久session數。無需另造「已連線AI客戶端」假資料。 |
| 單一動作owner、Stop、取消、人工接管／隱私暫停 | [CameraService](../Sources/Pocket3Core/CameraService.swift)、[OperationPermit](../Sources/Pocket3Core/OperationPermit.swift)、[ContinuousGimbalTests](../Tests/Pocket3CoreTests/ContinuousGimbalTests.swift)、[IPCCancellationTests](../Tests/Pocket3CoreTests/IPCCancellationTests.swift)、[GestureTests](../Tests/Pocket3AppTests/ContinuousGimbalGestureTests.swift) | 已有lease／ticket／lifecycle／取消測試。模型與zoom近期另有修改，需同批跑回歸；物理尾移／機械停止不是可用fake補完的項目。 |
| 1080p／4K／直幅、正確方向／新影格、不靜默降級 | [CaptureMode](../Sources/Pocket3Core/CaptureMode.swift)、[CaptureEngine](../Sources/Pocket3Core/CaptureEngine.swift)、[格式／callback tests](../Tests/Pocket3CoreTests/CaptureModeTests.swift)、[硬體驗收](HARDWARE_ACCEPTANCE.md) | 格式枚舉／選擇／停流表示已實作；H.264零回呼、所有格式與內容方向／其他裝置屬硬體待驗，不是「缺格式UI」。 |
| 30分鐘影音、有界音訊測試 | [StreamValidation](../Sources/Pocket3Core/StreamValidation.swift)、[StreamValidationTests](../Tests/Pocket3CoreTests/StreamValidationTests.swift)、[完整1800秒報告](../artifacts/hardware-resumed/stream-final/EC740B6A-ECD5-4C48-89B1-8A797CF2D936/report.json) | 指定1080×1920 NV12/30/stereo48kHz已有實機長測；不是仍缺執行器。不能擴張成所有格式／新工作負載通過。 |
| Apple／MLX觀察、Dynamic Profile、有界工具／證據圖片 | [IntelligenceEngine](../Sources/Pocket3Intelligence/IntelligenceEngine.swift)、[ObservationTools](../Sources/Pocket3Intelligence/ObservationTools.swift)、[ObservationBoundaryTests](../Tests/Pocket3IntelligenceTests/ObservationBoundaryTests.swift)、[AI驗收](AI_VALIDATION.md) | 已實作並有模型／模擬基線；本輪observer修改需重跑離線evidence/permission回歸。真實「看→移→再看→答」另需硬體。 |
| 模型下載／取消／完整性／卸載；CoreAI/Vision／ANE評估 | [LocalModel](../Sources/Pocket3Intelligence/LocalModel.swift)、[ModelIntegrity](../Sources/Pocket3Intelligence/ModelIntegrity.swift)、[模型測試](../Tests/Pocket3IntelligenceTests/ModelDownloadTests.swift)、[PerceptionEngine](../Sources/Pocket3Intelligence/PerceptionEngine.swift)、[AI_VALIDATION](AI_VALIDATION.md) | 管線與測試存在；本機fixture推論可在相機關閉時驗證。ANE實際使用不能從偏好或MLX GPU推定；不是先發必須再添一個AI框架。 |
| 單圖匯出、診斷去識別化、獨立模型API範例 | [App snapshot](../Sources/Pocket3BridgeApp/Pocket3BridgeApp.swift)、[Diagnostics](../Sources/Pocket3Core/Diagnostics.swift)、[DiagnosticsTests](../Tests/Pocket3CoreTests/DiagnosticsTests.swift)、[Examples/observe.py](../Examples/observe.py) | 已提供，尚無本輪證據顯示缺功能。新status欄位須維持redaction測試，不把完整無線raw狀態塞進分享報告。 |
| 更新檢查、授權偏好與安裝 | [AppUpdateController](../Sources/Pocket3BridgeApp/AppUpdateController.swift)、[AppUpdateTests](../Tests/Pocket3AppTests/AppUpdateTests.swift)、[release-settings](../Scripts/release-settings.py)、[RELEASE](RELEASE.md) | Sparkle引擎／設定UI存在，不是只有假按鈕。root本輪正在收緊appcast signing status；要以新測試驗證，`SUNoUpdateError`本身不足證明簽章有效。**真實feed/公鑰/更新archive與下載安裝仍需要發布設定**；不能捏造URL。 |
| Release／ZIP／DMG／搬移資源自足／簽署 | [build-app](../Scripts/build-app.sh)、[package-release](../Scripts/package-release.sh)、[verify-bundle](../Scripts/verify-bundle.py)、[portable inference](../Scripts/verify-portable-inference.py)、[LOCAL_SIGNING](LOCAL_SIGNING.md) | 腳本及本機固定憑證路徑存在；新source必須再做同批驗證與打包manifest。Developer ID／公證是公開發布外部條件，不能拿它阻止本機軟體補完。 |
| 新增zoom／tap AF／機身原生快速預設／完整設定 | [USBZoom](../Sources/Pocket3Core/USBZoom.swift)、[CameraZoomModel](../Sources/Pocket3BridgeApp/CameraZoomModel.swift)、[CameraFocusModel](../Sources/Pocket3BridgeApp/CameraFocusModel.swift)、[CameraSettingsState](../Sources/Pocket3Core/CameraSettingsState.swift)、[BLE固定query](../Sources/Pocket3Core/Pocket3BluetoothDiscovery.swift)、[裝置路線](DEVICE_CAPABILITY_ROADMAP.md) | zoom已具UI/service；tap AF現有AVF實作受連線capability限制。原生preset／WB/EV等尚無可用生產transport整合；codec/state foundation存在但不算功能完成。需要可核對的裝置通道證據，不能以慢USB/MF或猜opcode替代。 |
| App Intents／語音／ROI／look_at／HTTP／headless／全天耐久 | [BUILD_PROPOSAL第8/15節](../BUILD_PROPOSAL.md)、[TODO後續項](../TODO.md) | 依最新明確scope分類；未提升的增量仍後續。不是離線completion必須偷偷增加的首發功能。 |

## 現在優先做的3件事

1. **完成本輪MCP邊界修正驗證。** 原本`capture_frame {maxDimension:"1280"}`會被Service的`.number ?? 1920`默默當預設取像；另外unknown fields／move mixed-mode未統一在IPC前拒絕。本輪已加共用contract與snapshot精確修正。`mcp-smoke --offline`現在使用私有Unix socket假服務，逐個比對錯誤碼與實際forward計數；合法snapshot/move刻意由假服務回camera_not_ready，與schema錯誤分開。先執行root的統一建置／Core tests，再跑該smoke與既有取消測試；不需要App或相機參與隔離smoke。
2. **補齊動態錯誤在App的語言呈現。** [AppModel catch](../Sources/Pocket3BridgeApp/Pocket3BridgeApp.swift#L317)直接把`error.localizedDescription`交給 [AppMessageBanner](../Sources/Pocket3BridgeApp/AppMessageBanner.swift#L8)，該View只做`displayText`去重、沒有localization。Core內例如`connection_busy`、`device_missing`訊息固定繁中，英文表亦無對應完整句；[check-design.py第17–22行](../Scripts/check-design.py#L17)只掃App中的`loc("literal")`等呼叫，因此目前綠色翻譯檢查抓不到此問題。最小方案是App層依穩定error code映射可翻譯文案，保留unknown error的有界fallback；加英文／繁中／簡中錯誤呈現fixture，不改YunAudio膠囊、提示列尺寸或共用美感檔。
3. **收斂最新離線gate與文件狀態。** [ACCEPTANCE_AUDIT表](ACCEPTANCE_AUDIT.md#L9)仍把動畫、韌體／TCC、30分鐘列舊缺項，並稱本機ad-hoc；[PENDING_VALIDATION](PENDING_VALIDATION.md#L6)更宣稱沒有有效簽署身分及「可做軟體全完成」，與固定簽署／新功能修改／本輪scope衝突。這些是能立即修的證據整理問題。保留歷史段，改頂部目前狀態引用最新同批test/build/package manifest；舊綠色gate不能涵蓋本輪MCP／zoom／observer／update修改。相機關閉不妨礙無autoconnect的設定UI與打包資源驗證。

## 必須保留的外部／硬體界線

- 發布位置／repository、永久HTTPS feed、公鑰與公開archive尚需使用者提供／確認；公開Developer ID、公證與真實更新安裝不能由離線mock宣告完成。
- 相機已關機，原生FE08/FE09、tap AF通道、所有格式／全範圍、物理速度／尾移、拔插／睡眠與真實AI觀察流程保持硬體待驗。已存在的source與既有硬體證據不因此清零。
- 本輪新寫的MCP source／tests尚未由本agent執行；Python smoke只作AST語法檢查。整體1.0不標記完成，也不把額外研究或待使用者條件當成停止所有離線工作的理由。
