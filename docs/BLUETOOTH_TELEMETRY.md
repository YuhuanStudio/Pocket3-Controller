# 藍牙電量提示與姿態

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

2026-09-09，build 5 新增。這兩項功能使用已配對 Pocket 3 的既有回報，不會自行開始掃描、配對、切換 Mac 網路或送出新的相機指令。使用者目前已關機，本次只驗證軟體與資料 fixture；新整合仍須在相機開啟後核對。

完整Release gate `d26e463e-24b5-4ce0-9b9f-85feb904a6b4` 已通過：351項程式測試、331個三語字串、7個未更動共用設計檔、29張一般介面與12張遙測fixture、模型搬移推論／卸載、更新驗證及ZIP／DMG。[本批報告](../artifacts/offline-telemetry-2026-09-09/final/verification-gate.json)、[實際UI擷取範圍](../artifacts/offline-telemetry-2026-09-09/final/visual-review.json)。這不證明本批已收到實機電池／姿態或已完成USB身分／座標校準。

## 電量提示

藍牙面板顯示電池百分比與充電三態。低電量或持續下降時，原有 Yun 狀態膠囊也會出現提醒。它標示的是**已配對藍牙相機**，沒有把這個 peer 自動認定為目前 USB 預覽的那台相機。

- 低電量門檻為20%，是 App 的提醒規則，不是 DJI 故障判定；低電量且正在充電仍可提醒保持電源連接。
- 持續下降需要同一 peer／session 的連續新鮮資料，至少兩次實際下降、合計至少2個百分點、起點到最後下降至少30秒。回看窗口最多10分鐘，最後一次下降必須在60秒內。
- 重複讀取同一樣本不算新資料；同百分比的新回報維持新鮮度，不能把瞬間跳值經過等待後變成30秒下降。
- 樣本或相鄰回報間隔超過5秒、斷線、換機／session、時鐘倒退或電量上升，都會清除先前趨勢。資料過期時百分比與警告不繼續顯示。
- 電量穩定超過60秒會解除下降提醒；這不證明充電或外部供電已恢復。
- 100%且未充電不觸發警告。`notCharging` 不等於沒有外部電源；USB配置500mA也不等於電池正在充電，這兩種來源保持分開。

判定只保留最多101個百分比層級，沒有無界背景紀錄。實作見 [BluetoothBatteryMonitor](../Sources/Pocket3Core/BluetoothBatteryMonitor.swift)；App 的接收、配對與過期邊界另有 [整合測試](../Tests/Pocket3AppTests/BluetoothBatteryPresentationTests.swift)。

## 只讀姿態

藍牙面板承接既有 `04/05` 的偏航、俯仰、翻滾。它重用先前 BLE 探測／原生回中證據的解析：前6 bytes為pitch／roll／yaw三個signed little-endian值，每刻度是相機回報的0.1度。

只有已配對、同peer／session、CRC通過且DUML序列前進的資料能更新畫面；重複封包不能延長新鮮度。以單調時鐘判定5秒有效期，掃描、斷線或新選擇均清空舊資料。

狀態保存原始刻度、單位與`not_calibrated_to_usb`。畫面明示尚未與USB座標校準；這不是已知的世界座標、機械角度校準、原生馬達可控或停止成功證明。新增snapshot不覆蓋既有frame callback，亦不發出任何姿態查詢。

實作與測試見 [BluetoothPoseObservation](../Sources/Pocket3Core/BluetoothPoseObservation.swift)、[姿態測試](../Tests/Pocket3CoreTests/BluetoothPoseObservationTests.swift)。三語`telemetry-fixture`截圖只渲染共用UI元件，不將模擬數值注入實際發現模型、相機服務或AI證據。
