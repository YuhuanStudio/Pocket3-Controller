# 程式接入範例

`observe.py` 示範獨立 Python 程式如何使用 Pocket 3 MCP 的本機模型 API。它透過隨 App 打包的 CLI，不另行開啟 USB，也不需要 Python 的 AI SDK 或雲端 API key。

```sh
python3 Examples/observe.py '畫面中的標籤寫了什麼？' \
  --app "$PWD/dist/Pocket 3 MCP.app" --engine apple
```

先在 App 連接相機並開放 AI 觀察。若問題要求移動，還需要 AI 移動權限和該 USB 連接的控制驗證。回覆包含來源影格、實際工具紀錄與時間；每次請求最多三次小幅移動、六次工具呼叫。不要自行循環重試未確認的動作。

取消或超時會關閉此請求的連線，App 的請求監視器會取消對應工作。需要獨立停止相機時使用 `pocket3 stop`；它會撤回 AI 移動權。

離線開發時可用固定圖片（沒有使用相機）：

```sh
open 'dist/Pocket 3 MCP.app' --args --hardware-validation
python3 Examples/observe.py '請讀出序號。' \
  --app "$PWD/dist/Pocket 3 MCP.app" --engine mlx \
  --fixture artifacts/evaluation/fixtures/text.png
```

MCP 客戶端接入設定從 App 的「AI 引擎與接入」頁複製。可執行的標準 JSON-RPC 客戶端範例在 `Scripts/mcp-smoke.py`；相機關閉時可加 `--offline` 驗證初始化、工具清單與拒絕取像。

`POCKET3_BRIDGE_DIRECTORY` 可為 CLI／MCP helper 指定另一個本機 bridge 目錄，用於隔離測試。一般使用不需設定。
