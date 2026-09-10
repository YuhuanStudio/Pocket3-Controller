# Pocket 3 Controller 文件

[English](../README.md) · 繁體中文 · [简体中文](../zh-Hans/README.md)

← [專案首頁](../../README.zh-Hant.md)

目前下載是 **0.0.1 beta 2，build 24**；後續 `main` 可能更新。已安裝版本的功能範圍，以 [beta 2 發行頁](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.2) 為準。

## 使用 App

先閱讀完整的 **[繁體中文使用指南](guide.md)**：涵蓋安裝、權限、USB 格式、手動控制、縮放與 Roll、BLE、本機 AI、MCP、常見問題及更新。

| 文件 | 內容 |
|---|---|
| [專案概觀與安裝](../../README.zh-Hant.md) | 下載、首次啟動、Webcam 設定、功能與 MCP 設定 |
| [完整使用指南](guide.md) | 從連接相機到本機 AI／MCP 的日常操作與問題排查 |

## AI

- [本機視覺 AI 深度研究](../AI_RESEARCH.md)：模型選擇、語意定位、追蹤、VLA 界線與可量測的產品優先次序。
- [可重現的定位評測](../../Evaluation/Grounding/README.md)：公開資料來源與評分契約。

## 技術文件與驗證紀錄

以下是**主要以繁體中文維護、保留原日期的工作文件**，不是每份都已翻譯成三語。舊產品名稱、舊測試條件及早期支援矩陣不覆蓋目前發布範圍；請一起看 [最新工作清單](../../TODO.md)。

| 文件 | 內容 |
|---|---|
| [連續雲台控制](../CONTINUOUS_GIMBAL.md) | USB 手勢、放開／Stop 及物理驗證界線 |
| [Bluetooth 遙測](../BLUETOOTH_TELEMETRY.md) | 電量、充電、姿態、新鮮度及裝置關聯限制 |
| [機身設定協定](../CAMERA_SETTINGS_PROTOCOL.md) | 只讀 AF、白平衡、曝光回報；協定資料不表示 setter 已可用 |
| [對焦讀回](../FOCUS_READBACK.md) | 可取得的對焦資訊及 App 點按 AF 尚未完成的原因 |
| [實驗性 USB Roll](../USB_ROLL.md) | 原始單位、能力檢查及有限實機驗收 |
| [硬體驗收](../HARDWARE_ACCEPTANCE.md) | 各次實機試驗的日期、條件與通過／失敗範圍 |
| [AI 驗證](../AI_VALIDATION.md) | 模型評估、失敗案例及模擬／實體相機動作的區分 |
| [驗收稽核](../ACCEPTANCE_AUDIT.md) | 歷史軟體 gate 與明列的未測項目 |
| [YunAudio 一致性](../YUNAUDIO_PARITY.md) | 共用視覺設計與 App 通用操作 |
| [裝置能力路線圖](../DEVICE_CAPABILITY_ROADMAP.md) | 待實作機身功能及啟用前所需證據 |
| [目前工作清單](../../TODO.md) | 持續進行的實作與驗證 |
| [參與開發](../../CONTRIBUTING.md) | 範圍、可重現修改、設計一致性與硬體測試回報 |

## 發布、簽署與資料

| 文件 | 內容 |
|---|---|
| [beta 2公開驗證](../releases/0.0.1-beta.2-verification.json) | 確切來源、公開資產hash、signed feed、更新安裝與剩餘限制 |
| [發布流程](../RELEASE.md) | 來源身分、安裝包驗證、GitHub assets 及 signed feed 發布 |
| [本機開發簽署](../LOCAL_SIGNING.md) | 固定本機簽署身分；不等於 Developer ID 或公證 |
| [測試產物政策](../TEST_ARTIFACTS.md) | 臨時擷取、保留報告，以及移除舊媒體後的 hash 紀錄 |
| [權利與第三方聲明](../../NOTICE.md) | 自有來源權利及各依賴的授權 |

私有 `artifacts/` 與 `research/` 不隨公開來源提供，因此工作文件指向它們的歷史連結可能無法開啟。移除的圖片不會被重製來冒充原證據，清理紀錄也不是新硬體測試。首頁圖庫只包含同語的 App 介面截圖，不含私有相機照片。
