# 本機 AI 驗證紀錄

更新：2026-09-08。Pocket 3 已由使用者關閉；本輪使用固定圖片與明確標示的模擬相機。以下不能當作實機停止或鏡頭角度的證據。

## Apple 與 MLX

- Apple 系統模型已完成原生圖片問答。
- Qwen 3.5 4B 4-bit 已完成 MLX／GPU 圖片問答。固定 revision：`0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`。
- 第一個 MLX 問答包含載入耗時 11.69 秒；後續開發題目約 4–12 秒。這些是 Debug App 的樣本，不是跨機器效能承諾。
- 一次包含工具的模擬工作流程：Apple 8.16 秒、MLX 24.88 秒；兩者都先執行一個向左步進，再對新影格 OCR，最後回答 `TEST-4826`。回覆使用的 frame ID 與最後工具影格一致。
- MLX 卸載後，實測活躍配置剩 4,036 bytes，配置快取歸零；該程序推論期間峰值約 4.35 GB。這是 MLX 配置器量測，不能當作整個 App 的 RSS。

## 評測揭露的問題

保留原始結果於 `artifacts/evaluation/development-initial`，修正設定後結果於 `artifacts/evaluation/development`。

1. Apple 初始回答曾把圖片上的 `LOCAL CAMERA TEST` 當作聲音內容。已補強單張圖片沒有音訊或時間序列的指令；重新測試沒有再捏造具體聲音。
2. MLX 曾產生重複括號及過長的非回答內容。已明確設定 Qwen 的 thinking template 協定、限制輸出陣列數量，並拒絕結構退化的結果。
3. MLX 曾在沒有任何移動工具紀錄時宣稱「已向左移動一小步」。不能只檢查是否真的送出動作；現已把已知的完成宣稱形式與工具紀錄核對，不符者拒絕顯示為有效回答。
4. **計數仍有已知錯誤。** 修正設定後的一次 MLX 回答把兩個幾何圖形加上標題文字算成三個。Apple 將正方形較籠統地稱為矩形。不可宣稱精確計數能力已驗收。
5. 原來的 lexical checker 會把列舉中的「2.」誤當成「有兩個」，也會將合法的中文轉述誤判為未讀到英文。因此它只作快速檢查；來源、答案與人工判讀必須保留，不能將 lexical 通過率當事實正確率。

工具紀錄核對是針對已觀察到的錯誤所加的保護，不是一般語意的完整判定器。權限、停止、有限步數及取消仍由程式獨立執行。

## 工具與取消

- Foundation Models 27 Dynamic Profile 按當次能力裝配取像、OCR、條碼及有界移動工具。
- 每次最多六個工具、三個小幅移動；並行工具會序列化。
- 使用權變更、人工操作、停止或重连會使舊 interaction stamp 失效。
- 停止先使尚未送出的 USB 寫入許可失效，再執行不受原任務取消影響的保持／回讀工作。停止也撤回 AI 移動權。
- IPC 用戶端取消、直接斷線、取消比原請求先抵達，以及八個普通工作已占用時的停止請求，均有無硬體測試。
- Apple Evaluations 的 replay runner 已加入，用實際 App 工作流程紀錄檢查動作、完成宣稱與動作後影格。沒有紀錄時不以空測試替代。

## Core AI

模型為 [YOLOS tiny](https://huggingface.co/hustvl/yolos-tiny)，revision `95a90f3c189fbfca3bcfc6d7315b9e84d95dc2de`。使用 Apple Core AI 匯出工具，程式來源 revision `df8119879f125ad1e2e4c6249c2cddded75c190a`，可由 `Scripts/export-coreai.py` 重現。

用原生前處理輸出的同一個 `[1,3,512,512]` tensor 比較原始 PyTorch 模型與 Core AI，避免不同 resize／normalise 流程混入轉換誤差。

| 路徑 | logit 平均絕對差 | logit 最大差 | bbox 最大差 | 判定 |
|---|---:|---:|---:|---|
| Float16 自動 vs 原始 Float32 | 0.0265 | 0.7647 | 0.07647 | 未通過 |
| Float16 自動 vs 原始 Float16 | 0.0350 | 2.875 | 0.09766 | 未通過 |
| Float32 CPU only vs 原始 Float32 | 0.0000313 | 0.003797 | 0.0001185 | 通過 |
| Float32 GPU 偏好 vs 原始 Float32 | 0.0000217 | 0.0002823 | 0.00007075 | 通過 |

門檻事先設為平均 logit 差 ≤0.03、最大 logit 差 ≤0.2、最大 bbox 差 ≤0.01。保留 Float16 失敗紀錄，不放寬門檻使其通過。兩個 Float32 路徑的 query 類別一致率均為 100%，但這是轉換一致性，並非物件辨識準確率。

預設資產已改用 Float32，並優先請求 GPU。Neural Engine 的可用性列舉或 preferred 設定不能證明實際執行在 ANE；後續 Instruments 結果見下節。Debug 版本前處理本身可耗約 140 ms，因此必須分開模型執行時間並以 Release 重測，不能把整段時間當作 GPU 推論時間。

原始測試後的補驗結果記於下節；當前尚缺項目以 `ACCEPTANCE_AUDIT.md` 為準。

## 後續離線驗證

- 保留題集的 `K9-317 / QTY 4` 與四個綠色圓形，Apple／MLX 共四個回答均經人工核對正確。樣本數很小，不消除開發題集已觀察到的計數錯誤。
- Apple Evaluations 已輸出 `.xcevalresult`，對六條實際原生 App 模擬工作流程的動作、完成宣稱、動作後影格及目標文字做 replay 檢查，四項平均均為 1。
- 真正 stdio MCP 取消測試：取消通知約 22 ms 抵達隔離 bridge，之後仍能列出工具。此為協議測試，不涉及相機。
- Core AI 在從 Instruments 啟動的 App 中留下 136 筆框架事件；43 次 MPSGraph 呼叫中位約 2.97 ms。目標 App 有 303 筆 M3 Max GPU Compute 區間，其中 53 筆與這些呼叫重疊；ANE 區間為 0。這證明該次工作使用了 MPSGraph／Metal GPU，不宣稱所有平台或所有模型都不使用 ANE。
- 以上 trace 是 Debug 建置，系統上有其他 App 活動；用於確認路徑，不能取代 Release 的獨立效能量測。原始 trace 可能含程序環境，只保留在忽略的本地 artifacts；摘要已排除環境及其他程序資料。

實際 trace 以模型活動和 GPU／ANE 軌跡交叉檢視，方法參考 [Apple Core AI Instruments 文件](https://developer.apple.com/documentation/coreai/analyzing-model-runtime-performance-with-instruments)。

## 搬移與 Release

Release App 已從 /tmp 複本執行，且測試期間原專案 `.build` 不可見。實際 MLX 圖片推論、Core AI Float32 物件偵測與模型卸載都通過，未使用相機。這比只確認檔案存在更直接地驗證了 metallib、模型與資源路徑。

目前 Mac 的螢幕鎖定且顯示器休眠，popover 動畫不能以完成通知驗收。測試只在此環境暫時關閉動畫，檢查呈現與 host 釋放，並輸出 `animationVerified=false`；正常使用的動畫設定保持原樣。

## Release 比較與下載狀態補驗

同一個 COCO 範例的五次熱執行中位數（Release App，包含原生圖片準備／後處理）：CPU 58.7 ms、GPU 偏好 34.9 ms、Neural Engine 偏好 32.0 ms、自動策略 40.1 ms。偏好不等同實際裝置，這些短測也不是獨占機器的穩定性測試。

Vision `VNRecognizeAnimalsRequest` 在同張圖辨識兩隻貓，熱執行中位約 5.48 ms。它只支援貓狗，不能把這個速度當作一般 COCO 偵測的等價比較；因此仍使用 Vision 做合適的窄任務，Core AI 保留一般物件感知功能。

隔離的模型下載 transfer 測試覆蓋共享下載、取消後重試、舊進度回報隔離、部分檔案刪除與完整性錯誤狀態。生產下載仍使用固定 revision 的 Hugging Face client；沒有重新下載 3 GB 權重來冒充額外驗收。

偵測結果新增同類別 IoU 去重與座標邊界檢查，解決範例中同一個遙控器被列為兩筆的情況。模型原始 tensor 比對不受這個後處理影響。
