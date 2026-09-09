# YunAudio 共用設計與應用功能對照

更新：2026-09-07。依使用者修正：**共用美感與通用 App 功能；相機狀態內容不同，不表示可以自行更換狀態條的美感。** 名稱統一 Pocket 3 MCP。詳見 [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md)。

| 項目 | 實作與驗證 |
|---|---|
| Zinc 配色、字體、圓角、間距、描邊控件 | 7 個 YunDesign 原始檔 SHA-256 與複製紀錄完全一致 |
| Flat／Glass、淺／深色、accent | 共用 YunTheme；獨立外觀設定，沿用元件預覽 |
| 主視窗與 traffic lights | WindowChrome／WindowFrame 原樣接入；外框最小 1180×720 pt |
| 三欄寬度、對齊與邊界 | 左 268 pt、右 360 pt、欄距 16 pt；由實際 SwiftUI layout preference 檢查 |
| 底部狀態列 | 保留 YunStatusPill／YunWrap 及原間距；換成影格、FPS、AI 權限、任務和 MCP 狀態 |
| 提示列 | 直接沿用 YunAudio.errorBanner：水平 12／垂直 8 pt、11 pt 圖示、caption、一行完整訊息提示；新增短／長訊息高度測試 |
| 獨立設定視窗 | 一般、外觀、相機、權限、快捷鍵、診斷、關於；側欄 168 pt，760×560 pt 預設，620×440 pt 最小 |
| 設定視窗關閉／重開 | 同一 controller 與 host；關閉時 detach，重開保留分頁；真實 AppKit 檢查 |
| Dock／登入啟動 | InterfaceOptions 與 SMAppService；登入項目只有使用者切換時才註冊，尚未為測試更改系統登入設定 |
| 語言 | 即時切換英文／繁中／簡中；字串與 InfoPlist 資源打包，靜態字串覆蓋檢查 |
| 權限入口 | 首次啟動導向相機／麥克風權限說明；連線要求相機權限，音訊測試才要求麥克風 |
| 關於與問題回報 | 正確名稱、版本、build、系統、來源與授權；回報先複製無圖片的版本範本 |
| Sparkle | 2.9.6 framework 與 helpers 已打包／簽章，更新偏好、自訂選擇視窗、安裝位置判斷已接入 |
| 實際更新下載／安裝 | **尚未發布本專案 feed 與公鑰，不能驗證遠端更新**；介面明示未配置，不誤報最新版、不使用 YunAudio 的 feed |
| 選單列 | 原生 NSStatusItem；左鍵 popover，右鍵／Control-click 功能選單；關閉後釋放 host |
| 面板高度 | 跟隨內容，超過 680 pt 可捲動；不再固定 320 pt 裁切底部操作 |
| 圖標 | 沿用 YunAppIcon／YunIconBadge，逐尺寸繪製 ICNS；runtime 樣式不改簽章中的 Finder 圖標 |
| 快捷鍵／單一主視窗 | ⌘, 設定、⇧⌘S 擷取、⌘. 停止、⇧⌘P 隱私暫停；關窗留在選單列，重開不另建主視窗 |
| 退出與更新生命週期 | 防重入退出，先釋放影音與 IPC，再回覆 AppKit 退出 |
| 包裝自足性 | 複製 App 並隱藏 `.build` 後，三語言、圖標、ICNS、Core AI、MLX metallib、Sparkle 均成功載入 |

介面驗證採用真實 AppKit 視窗 theme frame；相機 layer 由當次真實影格代入，非螢幕截圖。淺／深色、英文／中文、窄設定視窗、提示列與面板圖片記錄於 `artifacts/parity`。截圖成功不等於每一個使用狀態均已驗收；實機長時間取像、模型評測及控制驗證仍在主 TODO。

音訊路由、虛擬音效卡、MIDI、卡拉 OK 等屬 YunAudio 業務功能，不加入相機 App。通用功能的內容與圖示按相機用途調整。
