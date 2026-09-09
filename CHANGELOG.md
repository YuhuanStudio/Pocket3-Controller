# 變更紀錄

## 0.0.1 beta 1（準備中，未發布）

- 產品名稱統一為 Pocket 3 Controller；提供原生 App、內建本機 AI、MCP 及 CLI。
- 直接沿用 YunAudio／YunUI 的共用設計、設定、圖標、選單列、視窗生命週期與更新介面。底部維持原膠囊樣式，只更換相機相關資訊。
- 修正啟動時 UVC 控制名稱快取的 autorelease 生命週期崩潰，加入 JSON 邊界及零位置解析測試。
- 加入有界移動、停止優先、控制權／連線 stamp、排隊工具取消、USB 寫入許可與新影格證據。
- 停止會撤回 AI 移動權；USB 驗證綁定本次系統開機與 USB attachment，不能只依連接埠套用舊結果。
- 使用 Foundation Models 27 Dynamic Profiles，接入取像、OCR、條碼與有限移動工具。
- 實作 MLX 模型下載、固定 revision、雜湊驗證、載入取消、卸載與記憶體量測。
- 加入 Core AI 模型轉換與數值比較。Float32 通過門檻，Float16 不作預設；記錄 MPSGraph／GPU 路徑。
- 增加 Apple Evaluations 報告、模型題集及明確標示的離線模擬工作流程。
- MCP／CLI 取消和斷線會傳遞到服務端；停止請求可繞過已占用的普通工作槽。
- App 採用 staging、簽章驗證及原子替換，避免覆寫正在執行的 bundle。
- 診斷匯出預設移除影像、裝置識別、活動與可能包含路徑的錯誤文字。

仍待本版真機驗收與公開更新來源。此 beta 使用固定開發簽署且未公證；Developer ID／公證是後續發行選項。詳見 TODO 與支援矩陣。
