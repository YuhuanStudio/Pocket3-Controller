# 等待條件

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

## 目前狀態（build25，2026-09-11）

公開版本為 beta 2 build24；main 的 build25 已完成 USB 1080p30 NV12 與 BLE pairing 的唯讀基線。真機已收到 `02/80` camera status、`02/DC` storage、九類 named camera properties、battery、pose，以及未知值 raw preservation；BLE peer 身份仍未與 USB serial 關聯。ActiveTrack 候選 observer 已就緒但基線為空，需機身啟動追蹤後比較。原生 preset、tap AF、設定寫入、完整格式／直幅、全範圍物理控制、遠端桌面與公證仍待驗證。Mac 網路沒有切換至相機 Wi-Fi。

build25 目前來源的 Release tests 為 648 次執行、零失敗，包含H.264 host-output、background bridge、MCP capture、App Intents與收緊 lens/status/raw telemetry後的完整重跑。三語完整九欄設定 fixture 已逐張檢查，長英文值會換行，無線 popover 高度限制為 680 px 並可捲動。完整封裝／搬移模型／更新／DMG gate 仍待下一個候選批次。詳細 current source of truth 見 [Pocket 3 支援矩陣](POCKET3_SUPPORT_MATRIX.md) 與 [實機驗收](HARDWARE_ACCEPTANCE.md)。

## build5 狀態（2026-09-09，歷史保留）

**build5完整Release gate已通過**：`d26e463e-24b5-4ce0-9b9f-85feb904a6b4`，App SHA-256 `314f6cc8c769ce6640e36cbab6f989f71a4e192ce85c6947061b3904247751ac`。[固定報告](../artifacts/offline-telemetry-2026-09-09/final/verification-gate.json)。新增BLE低電量／持續下降提示與只讀姿態；351項Release測試、331條三語／7個共用設計檔、41張UI（29一般＋12遙測純fixture）、搬移推論／卸載、MCP、更新與ZIP／DMG payload均通過。[UI](../artifacts/offline-telemetry-2026-09-09/final/ui-gate.log)、[產物驗證](../artifacts/offline-telemetry-2026-09-09/final/release-artifacts-verification.json)。相機仍由使用者關閉，12個新UI案例不能當真實下降告警或姿態顯示的硬體驗收；新遙測實機／斷線回歸，以及原生快速preset、tap AF、H.264、全範圍、物理校準與公開發布條件仍待完成。本批鎖屏動畫未重驗；BLE資料不冒充USB供電或校準座標，Mac原網路不變。

## build4等待／驗收快照（2026-09-09，歷史保留）

使用者已關閉Pocket3，本批未執行新實機取像／控制。**0.1.0 / build4完整Release gate已通過**，重新完整執行、非resume；run `beede929-3b74-49a0-895f-33cbe67f49ee`，App executable SHA-256 `f6e3207c34510ae58ce808d20f3e7e58659fd431637bc34ffc8ac6428ff527d7`。[報告](../artifacts/offline-2026-09-09/final/verification-gate.json)。這是本批離線整合完成，不是整體1.0或所有硬體功能完成。詳細scope見 [ACCEPTANCE_AUDIT](ACCEPTANCE_AUDIT.md)；[OFFLINE_REMAINING_AUDIT](OFFLINE_REMAINING_AUDIT.md)保留修正前查讀脈絡。

本批已通過332項Release測試、317條三語字串／7個共用設計檔、3套C/ObjC ASan、29張UI、離線MCP／取消、模型搬移推論／卸載，以及ZIP與唯讀DMG payload簽章／hash。banner兩例均30pt、footer38pt；暫時語言修正後saved preferences未變。[設計](../artifacts/offline-2026-09-09/final/design-contract.json)、[UI](../artifacts/offline-2026-09-09/final/ui-gate.log)、[安裝包](../artifacts/offline-2026-09-09/final/release-artifacts.json)、[payload](../artifacts/offline-2026-09-09/final/release-artifacts-verification.json)。**本次popover animation因鎖屏／休眠未驗，歷史解鎖通過紀錄保留**，不混為同一次測試。

4個signed-feed fixture與非fixture偏好保護均通過，run `2687c1ef-932d-4178-86f4-d6cda27eb017`，同build/hash；有效簽章接受、三個反例拒絕，偽fixture env零下載請求且sentinel保留，測試域已清空。[簽章／偏好guard報告](../artifacts/offline-2026-09-09/final/update-feed-verification/result.json)。

已具備的證據保留，不因相機關閉而清零：

- 指定1080×1920 NV12／30fps、stereo48kHz的1800.207秒影音長測與清理已通過。[實際報告](../artifacts/hardware-resumed/stream-final/EC740B6A-ECD5-4C48-89B1-8A797CF2D936/report.json)。
- 手動USB按住／拖曳、放開／失焦／Stop與可見AppKit輸入surface已實測；本機固定開發簽署、授權保留與解鎖後動畫亦已有紀錄。[硬體／UI證據](HARDWARE_ACCEPTANCE.md)、[本機簽署](LOCAL_SIGNING.md)。以下舊段落的ad-hoc／無有效身分／未測動畫是當時狀態，不是現在結論。
- 真實Apple模型測試13.388秒、快取MLX模型測試37.843秒通過；兩者相機皆為simulation，physicalCameraAccess=false，只證明離線zoom工具順序、單次寫入模擬器與新影格回答。[Apple結果](../artifacts/model-zoom-check/apple-E9E5E104-C10D-4534-A9AE-163763E477DE/result.json)、[MLX結果](../artifacts/model-zoom-check/mlx-E203FD0E-3F39-4CF0-A3E3-5919636B82DD/result.json)。框架／流程不同計時範圍詳見驗收對照，不當實體相機測試。

仍待實機／協議證據的項目：機身double／triple對應的原生快速回中／朝向、tap AF、H.264取像、完整範圍／各姿態、物理角度／速度／停止尾移，以及新整合後的拔插／睡眠與真實AI相機流程。**慢速USB軌跡不替代原生preset，MF不替代tap AF**；Mac保留原網路，不要求加入相機SSID。[詳細限制](HARDWARE_ACCEPTANCE.md)。

公開更新發布位置、永久feed／公鑰與對應archive、Developer ID與公證仍是外部發布驗收條件。本批loopback signed-feed已通過，但沒有下載／安裝更新，不代表正式發布來源或完整更新安裝已配置。這些外部條件與原生快速preset、tap AF、H.264、全範圍等硬體／協議待驗項均保留。

## 歷史等待快照（2026-09-08早期，保留）

以下保留當時的等待判斷與gate識別碼。舊「最新」「無建置在跑」及鎖屏等敘述僅適用該批次；目前狀態以前段為準。

2026-09-08。本次再次確認等待條件，另發現並補齊串流驗收執行器；整體目標仍未完成。

- 使用者明確關閉 Pocket 3，要求先處理其他部分。不得自行恢復實機取像或移動測試。
- 最近檢查顯示螢幕鎖定且顯示器休眠；無動畫測試已通過，正常動畫需可見桌面。
- 沒有 git remote／真實更新發布 URL；已透過問題工具詢問發布位置，尚未收到回答。
- 正式 Developer ID／公證仍屬外部發布條件，目前僅交付 ad-hoc 本機版。

可核對當前完成範圍：ACCEPTANCE_AUDIT.md、TODO.md、artifacts/verification-gate.json。

本輪新增的離線準備是串流驗證執行器及其模擬測試，沒有把重複列出等待條件當作進度。相機保持停用、畫面鎖定、更新來源未提供及無簽署身分的条件未改变。

最新 Release gate `0603c8a1-9d0f-4ed9-ba6f-afff1b550c80` 已完成，串流驗收執行器也已通過模擬測試並打包。本機無未結束的建置或驗證程序需要等待。

相機由使用者關閉、桌面鎖定、沒有發布 URL／git remote 及沒有有效簽署身分的條件，在相機關閉後的三輪 goal 工作中持續存在。其間可做的軟體工作已完成；現在需要使用者重新提供硬體／桌面與發布條件才能完成剩餘驗收，整體目標不標記完成。
