# 測試媒體保存與清理

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

相機照片與含即時預覽的 UI 截圖只在當次驗證需要時保存，不再為每輪 gate 複製一份照片。JSON／JSONL、log、實機回讀、協定與效能證據繼續保存；原本的 pass/fail 與限制不因媒體移除而變更。清理沒有重跑硬體，也不產生新的硬體通過結論。

先在 repo 執行預覽：

```sh
python3 Scripts/clean-test-media.py
```

核對清單後才執行 `python3 Scripts/clean-test-media.py --apply`。工具只處理固定歷史批次中的 `.jpg`／`.png` regular files，逐層拒絕 symlink；修改時間距今不足一小時的檔案略過。沒有自訂 root、glob、時間門檻或外部目的地參數。

第一階段範圍：`artifacts/hardware-resumed/`、`artifacts/hardware-roll-2026-09-09/` 的媒體，`mcp-smoke/frame.jpg`，`model-zoom-check/*/post-zoom.jpg`，2026-09-09 舊 offline／telemetry parity 批次、既有語言／姿態翻譯與 Roll 排版修正前批次，以及 `artifacts/ui/`。精確路徑由腳本 `classify()` 定義。`artifacts/parity/` 當前截圖、`artifacts/evaluation/fixtures/`、報告、簽章資料、App 資源及未列入的目錄不刪。

每張圖片刪除前，工具先將相對路徑、bytes、SHA-256、分類、原因、時間寫入 `artifacts/media-cleanup/*.jsonl`，並 `fsync` 紀錄。`prepared` 表示紀錄已落盤、即將移除；只有隨後的 `removed` 事件確認完成 unlink。若中途中止，保留此差別，不把 `prepared` 當作已刪除。檔案在掃描後變動會拒絕刪除；檔案系統錯誤會停止本輪。

歷史報告的圖片連結可能在清理後失效。後續維護文件時應標示「historical image removed」，改連原始測量報告與相應 receipt，而非重新產圖冒充當次證據。雜湊只能識別當時移除的 bytes，無法替代圖片的視覺複核。部分舊 `captures.json` 仍記錄當時 `artifacts/parity/` 的輸出路徑，不能以「無直接引用」推定 archive 圖片沒有用途。

這些 receipt 與原始報告留在本機，清理流程不會把它們加入預設問題回報或對外上傳。離線防越界測試：`python3 -B Scripts/test-clean-test-media.py`，只操作暫存目錄。

## 2026-09-09 第一批已完成

已刪除 155 個舊媒體檔，共 31,326,669 bytes（約 29.88 MiB）。相機照片 30、含相機狀態的 UI 圖 14、模擬輸出 2、歷史 UI 圖 109。原始報告及必要 fixtures 保留。詳見[本次清理清單](../artifacts/media-cleanup/20260909T045203Z-286885ae-729b-4b0a-a4fe-3814324d2046.jsonl)；每一筆均有 SHA-256 與 `removed` 紀錄。
