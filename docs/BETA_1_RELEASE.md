# Pocket 3 Controller 0.0.1 beta 1

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

目標是先交付可日常試用的本機內測包，同時持續完成整體專案。beta 1不以所有機身功能完成為門檻，也不把尚未支援的能力列為可用。

## 產品名稱與版本

- App：**Pocket 3 Controller**，發行者 **Yuhuan Studio**。MCP是內建接入功能。
- 顯示版本：**0.0.1 beta 1**；機器版本：`0.0.1-beta.1`；公開 bundle build：`9`。
- 維持既有bundle identifier、簽署身分、偏好設定、模型快取與IPC位置；內部執行檔仍為Pocket3MCP，相容既有權限與程序管理。
- 本機dist保留舊App路徑的相容連結；新的安裝包只包含新名稱的App。

初步名稱搜尋未找到完全同名的公開macOS App；但[Kaze](https://github.com/brianmerchant/Kaze-for-DJI)已有`Pocket3Controller`工程名，且[MOVMAX Pocket Controller](https://movmax.com/product/movmax-pocket-controller/)是既有硬體名稱。以Yuhuan Studio識別來源；這不是名稱全球唯一性的保證。

## beta 1範圍

| 範圍 | 本版對使用者的說法 |
|---|---|
| USB預覽、單張擷取 | 基本功能；格式以裝置宣告與實测矩陣為準 |
| 手動pan／tilt、按住／拖曳與停止 | 核心控制流程，須在這個candidate再做真機檢查 |
| USB縮放 | 顯示裝置原始控制行程，不宣稱已校準倍率 |
| USB Roll | 實驗功能；已有0→1→0回讀，物理方向／角度與移動中Stop仍未完成 |
| 本機AI、OCR、MCP／CLI | 現有接入與取像流程；AI動作仍遵守個別權限與驗證条件 |
| BLE電池／姿態、AF／WB／EV狀態 | 只讀回報；不自動視為USB相機身分／座標，也不表示設定可寫 |
| 原生快速回中／前後翻轉、App點按AF | 開發中，不列為beta 1可用功能 |
| 更多機身設定、H.264／所有高幀率、完整物理範圍 | 尚未完成，保留明確限制 |

## 交付前檢查

- [x] App、CLI、MCP、關於、權限文字、報告與安裝包名称／版本一致；已實看關於／主畫面／提示列。
- [x] 完整軟體 gate、397 項 Release 測試、59 張 UI、Yun 共用設計／三語、搬移後模型推論、簽章與 ZIP／DMG 包內核對。[build 8 報告](../artifacts/beta1-2026-09-09/software/artifacts/verification-gate.json)
- [x] 新 candidate 真機基本流程：1920×1080 NV12 新影格、實際按鈕放開、位置有界還原、縮放往返、隱私暫停及新 session 重連；綁定當次 capture／USB attachment，最終 Stop verified。[本版實機結果](../artifacts/beta1-2026-09-09/hardware-smoke/result.json)。位置允許1080 raw容差，Zoom允許1 raw容差，不代表機械停止／完整範圍校準。
- [x] 安裝說明與已知限制隨 App／DMG 提供，公開更新來源保持未配置。
- [x] 使用者確定 GitHub 儲存庫名稱：`YuhuanStudio/Pocket3-Controller`。
- [x] 公開儲存庫、原始碼 commit／tag、Release 資產與無登入下載驗證、正式更新 feed 簽署與公開驗簽已完成。未公證 beta 可沿用 YunAudio 的明示分發方式，公證不是 beta 的必要門檻。

本機開發簽署的內測包與公開分發是不同驗收。本頁是待完成的beta交付清單，尚未宣稱已發布或完成整體1.0。

本機 build 8 候選 App SHA-256：`1081ef5c1321ba059ad78f11f808d62fe4809ba22673d0e85604850339e16c71`。[公開 Release 已建立](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1)，signed beta feed 已發布並通過公開下載驗簽。

公開版為 build 9，來源 `21778c0e6ddec9ec9da017683f74c62177443985`，App SHA-256 `5aa5587910e63c7e47d50d75fc9d14e9f07e3bcd8085573a37c8175ebf031cee`。版面修正與新鏡頭記錄在 main 的 beta 2 開發線，沒有改寫 beta 1 的已發布資產。
