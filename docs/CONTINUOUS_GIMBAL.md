# 連續雲台控制

2026-09-08。依使用者要求，日常手動控制改為按住方向、拖曳搖桿與可調速度；USB 一度步進僅作診斷用途。共用 YunDesign 檔案與底部膠囊狀態列保持原樣。

## 目前產品決策

使用者已明確要求 Mac 保留現有網路。主路徑改為 USB 取像＋藍牙原生控制；BLE 馬達控制需經實機 probe 確認後才能開放，不能因有遙測就當作可控。相機 Wi-Fi 不再是 App 使用前提，加入相機 Wi-Fi／UDP 連接操作已從主流程撤下，Mac 網路未變更。

Phase31 的 native vertical slice 沿用單一 command-ready UDP 9004 owner：`04/01`
stick 使用 center `1024`、每軸最多 `±550`、notify/no-ACK flags，scheduler 以
50 ms 上限泵送。按住結束、失焦、取消或斷線仍送 `04/01` center neutral；
`04/14` relative-zero timed-stop 只保留給未來的 timed-target coordinator，不能
拿來替代 joystick release。`04/4C FE08` recenter 與 `FE09` front/selfie toggle
共用同一條 exact session/generation/route owner，沒有 BLE-only fallback，也不會
自動切換 Mac Wi-Fi。

## 先前研究的控制路徑（不作為目前 Mac 使用前提）

- USB Webcam：本機對 pan/tilt relative 的 GET_INFO 得到 STALL；absolute position 仍可讀寫，但實測有正向 tilt 指令被忽略，不能視為完整搖桿控制。證據見 `artifacts/uvc-relative-support-readonly.json` 與 `docs/HARDWARE_ACCEPTANCE.md`。
- 原生控制：明確選擇 BLE 相機 → 在機身確認配對 → 取得相機 Wi-Fi 連接資訊 → 使用者主動加入相機 Wi-Fi → TCP 7001 bootstrap／UDP 9004 datalink → 收到對應心跳與新姿態後開放手動控制。
- 原生 joystick 使用 DUML `04/01`，最多每 50 ms 傳送一次方向／速度；中立 pitch／yaw 都是 1024。此值不是已校準的角速度。回中及前後切換使用 `04/4C` 的 `FE08`／`FE09`，不混用 USB 絕對座標。

協議參考固定於 [Kaze for DJI 341a35d](https://github.com/brianmerchant/Kaze-for-DJI/tree/341a35de18493ff61f97c93b8b10161a7512aa36)。實作與 wire constants 的來源／限制記錄在 `research/2026-09-08/native-datalink-provenance.md`。

## 操作與停止

App 手動區提供按住方向、拖曳及聚焦後按住方向鍵；放開、Escape、視窗失焦／關閉、切換頁面及 Stop 均結束原手勢。UI 每 50 ms 續租，Core 超過 250 ms 沒收到續租便撤回移動並送中立。傳輸一次只送一個控制指令，慢傳輸不補送積壓指令。舊手勢／舊連線的回呼不能接管新手勢。

原生控制連線持有雲台時，CameraService 拒絕 USB 移動與 USB 控制驗收，Stop 交給原生傳輸。這避免兩種座標系同時寫入。送出中立、命令 ACK、姿態穩定、實際機械停止是不同證據；目前 API 不把前兩者冒充後兩者。

連接資訊不會寫進 RPC、診斷報告、活動日誌或剪貼簿；BLE 診斷最多保留 16 筆純訊息 header。App 初始化、掃描和配對均不會自行切換 Mac Wi-Fi。加入相機 Wi-Fi 是獨立按鈕，明示可能影響網際網路連線；使用 [Apple CoreWLAN associate](https://developer.apple.com/documentation/corewlan/cwinterface/associate(to:password:))，已進入的系統 association 沒有取消 API。

## 本輪驗證狀態

- 本輪 Core 120 項、App 18 項測試通過，包含原生 joystick 編碼、20 Hz 排程、250 ms 租約、取消／neutral 競爭、BLE 分片／配對狀態、UDP fake-I/O 及 App 手勢測試。
- 新版已實際啟動；首次 BLE 掃描停在等待 macOS 藍牙初始化／授權，尚未收到廣播。已發現並修正「把使用者授權等待也算進 15 秒掃描」的問題，授權等待與真正掃描改為分開計時。
- 實機 BLE 配對、Wi-Fi 共存、連續移動、放開／失焦實際停止、完整視角與原生前後切換仍待驗證，不能勾選完成。
- 現有 MCP 的 USB 位置工具不會自動改走尚未驗證的無線路徑；原生連線使用中會明確拒絕 USB 位置指令。原生 AI／MCP 移動須在手動實機驗收後接入。

## 下一步實機驗收

1. 首次系統藍牙權限允許後，掃描並選定 Pocket 3，在機身確認配對；核對回覆與憑證取得，檢查 USB 畫面是否持續。
2. 使用者同意切换 Mac Wi-Fi 後，建立 datalink，檢查心跳、姿態來源與新鮮度。
3. 短時間低速按住、放開及反方向返回；逐步擴展到長按、拖曳改向、速度變更、失焦、Stop 和斷線。全程以新姿態及實際畫面核對，不用單純 ACK 判定完成。
4. 確認原生回中／前後切換與可用物理範圍，再加入有界時間的 MCP／AI 連續操作。

歷史實際 UI 擷取原位於 `artifacts/hardware-resumed/native-ui-camera-connected.png`；原圖依[媒體清理政策](TEST_ARTIFACTS.md)移除，以下為當時觀察。本次回到 NV12 後的影格包含上下黑邊，機身方向需重新核對；當時未自行裁切掩蓋。早先五種直幅格式的人工影像核對僅代表當次機身方向。
