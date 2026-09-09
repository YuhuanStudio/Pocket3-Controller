# 使用 Pocket 3 Controller

[English](../guide.md) · 繁體中文 · [简体中文](../zh-Hans/guide.md)

[文件入口](README.md) · [專案概觀](../../README.zh-Hant.md)

本指南涵蓋已發布的 **0.0.1 beta 1，build 9**，並另外標明build22開發版。build22已通過離線軟體、打包App及UI驗收，尚不是公開下載；build16硬體結果是歷史證據，不代表build22另做了真機驗收。停用或標為實驗性的控制，不表示對應機身功能已支援。

## 安裝與首次啟動

從 [beta 1 發行頁](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1) 下載 DMG 或 ZIP，把 **Pocket 3 Controller.app** 放入 **Applications**。需要 macOS 27 與 Apple Silicon；發行頁也提供 SHA-256 checksums。

此 Beta 使用本機開發憑證，尚未 Apple 公證。若 macOS 阻擋首次啟動，先確認下載來源，再依「系統設定 → 隱私權與安全性 → 仍要打開」提示允許該 App。目前沒有 Homebrew cask；其他 Mac 的首次啟動行為尚未全面驗證。

以 USB 連接 Pocket 3，在機身選擇 **Webcam**，再於 App 選擇相機並連接。不需要更改 Mac 的 Wi-Fi。

## 存取權與隱私

存取選項決定 AI 與外部客戶端可以對即時相機做什麼：

| 選項 | 行為 |
|---|---|
| **僅手動操作（Manual only）** | 預設。可以使用 App 預覽與手動控制；沒有授予 AI 觀察或動作權限。 |
| **只允許觀察（Observe only）** | 允許影格觀察與圖片問答，不授予相機移動權限。 |
| **允許觀察與移動（Observe and move）** | 允許觀察及符合條件的相機動作；每次動作仍檢查能力與驗證要求。 |

連接時會請求 macOS 相機權限。使用音訊時需要麥克風權限，明確啟動 Bluetooth 操作時才請求其權限。若先前拒絕，先在系統設定更改相應權限，再重試該功能。

**停止（Stop）** 取消待執行的相機工作並嘗試相應保持操作。**隱私暫停（Privacy pause）** 停止目前工作並釋放擷取輸入。關閉主視窗會保留選單列服務；**結束（Quit）** 才會結束服務。選單列圖示左鍵開面板，右鍵開功能選單。

## 遠端桌面與背景使用

相機服務沒有實體螢幕亮起的要求。App須在已登入使用者的macOS工作階段持續執行；本機CLI／MCP helper使用同一使用者的服務，不是在登入前啟動的系統daemon。遠端桌面操作仍需能進入桌面，並由App視窗接收手勢。螢幕關閉、桌面鎖定及整機睡眠是不同狀態。

開發build18在持續取像時持有活動保護，防止閒置系統睡眠及App Nap，但不要求螢幕保持亮起；暫停、斷線與取像結束會釋放。明確讓整台Mac睡眠仍會暫停相機，喚醒後需重連。這是開發版新增能力，不是beta1的既有功能宣稱。實際Mac Studio遠端桌面、熄屏及遠端斷線時的手勢測試仍待完成；build17的外部MCP縮放測試是在螢幕已亮起時執行。

## USB 預覽與格式

先使用 Beta 基本流程驗收的 **1920×1080、NV12、30 fps**。選擇其他解析度、幀率或輸入格式後，重新連接才會生效。720p30 與 1080p24 也已取得新影格，4K30 NV12 有較早的有界實測證據。格式選單反映裝置宣告，不代表每個組合都會產生影格。

直幅結果取決於機身實體方向及選定模式。早期直幅試驗在改變機身方向後通過；不能假設只選擇直幅解析度就會旋轉相機或啟用全部原生直幅模式。UYVY／H.264 路徑及 4K60 仍沒有通過的取像結果。沒有新影格時，回到已測的 1080p30 NV12。

單張擷取只取得一張圖片；CLI 會寫入你明確提供的 `--output` 路徑。可以預覽不代表 App 已能錄影或控制全部機身錄影模式。

## 手動雲台控制

按住方向按鈕或拖曳搖桿，移動 pan／tilt；離中心越遠，要求的移動越快。放開輸入、失焦或按停止都會結束手勢。手動操作優先於 AI，透過 USB 位置目標控制，Mac 保留原有網路。

先做小幅手勢，確認畫面結果。物理速度、完整範圍及最壞情況的停止延遲尚未校準。停止後穩定讀回是軟體證據，不是機械急停認證。若 App 回報無法確認停止，請查看相機實際狀態，不要自動重複前一個移動。

原生快速回中及正反面翻轉仍在開發，慢速 USB 移動不是等價替代。

## 縮放與實驗性 Roll

使用縮放滑桿或減／加按鈕。百分比表示裝置回報範圍內的控制行程，不是光學放大倍率。已測裝置回報原始值 100–400、step 1，並完成 100 → 200 → 100 往返。其他裝置或連線必須使用各自讀到的能力。

Roll 標為**實驗性**，數值是裝置控制單位，不是已校準的物理角度。目前只有 0 → 1 → 0 原始值往返的驗證；物理方向及較大調整中的停止仍待驗收。縮放或 pan 通過不等於 Roll 也通過。

## Bluetooth 只讀狀態

開啟 Bluetooth 連接面板，明確掃描、選擇相機並配對。機身出現提示時確認配對要求。此流程不會讓 Mac 加入相機 Wi-Fi。

配對後，面板可顯示機身回報的電量、充電、姿態、AF 模式、白平衡及曝光。用讀取操作更新三個機身設定值；缺少或過期的資料不視為已確認的目前狀態。低電量與持續下降趨勢會分別顯示，不和充電狀態混為一談。

這些值是只讀資料。BLE peer 不自動視為選定的 USB 相機，BLE 姿態也未與 USB 座標校準。機身可以支援點按對焦，而 App 內的點按對焦仍不可用；AF 模式讀回不是設定對焦點的功能。

## 本機 AI

在「AI 引擎與接入」選擇引擎。Apple Foundation Models 需要相應系統模型可用。MLX Qwen 3.5 為選配，透過下載操作取得，預留約 3.1 GB 模型空間。下載需要網路，推論使用已在本機的模型。

### build22開發版：圖片檔案工作區

以下流程已在build22開發版的真App、無相機條件下通過基本流程測試：Apple問答、MLX計數與定位、Vision OCR、取消、換圖及過期結果清除。軟體／打包gate及三語UI檢查也已通過；已發布的beta1 build9不包含這些功能。

![build22開發版圖片工作區](../images/image-workspace-zh-Hant.png)

*build22開發版；匯入圖片與分析內容已隱去，這不是公開beta1的畫面。*

把觀察來源切成 **Image file（圖片檔案）**，按 **Open image（開啟圖片）**，選取8 MB以下的本機圖片。**Replace image（替換圖片）**會更換檔案並清除上一份結果。選擇 **Ask about image（圖片問答）**、**Count objects（計算物件）**或 **Locate a target（定位目標）**，輸入問題或目標後開始分析；**OCR**可直接讀取可見文字，不需要先輸入問題。成功的定位結果會在匯入圖片上顯示標記。

圖片分析不需要Pocket3，只使用所選的Apple或MLX模型；OCR使用本機文字辨識。它不取得相機控制權，位置標記也不會變成雲台或對焦命令。切換觀察來源會保留既有相機連線與存取設定；要釋放正在進行的即時取像，另外使用「隱私暫停」。

物件數量、位置與回答都是模型估計，可能出錯；尤其是相似物件或部分遮擋，請對照原圖。「取消」會提出取消要求並等待目前工作結束，更換檔案或來源會清除過期結果。第一版工作區只接受靜態圖片，尚不包含影片播放或持續追蹤。

### build22開發版：本次任務與相機權限分開

使用**相機來源**時，可為本次問題選擇 **Observe only（只觀察）**或 **Assist framing（協助取景）**。這是任務模式，與全域相機存取選項分開，不會自行授予權限。

| 引擎與任務 | 模型行為 |
|---|---|
| Apple＋只觀察 | Apple使用只讀工具觀察影格；即使已有相機控制權，也不啟動MLX。 |
| Apple＋協助取景，且已有符合條件的控制權與能力 | 已下載的MLX執行允許的調整流程，App再取新影格給Apple回答。 |
| MLX＋只觀察 | MLX只觀察，不取得移動或縮放工具。 |
| MLX＋協助取景 | MLX只取得既有權限與能力檢查允許的調整工具。 |

原始碼的初始任務模式為觀察，不會自動下載模型。協助取景若需要尚未下載的MLX，會說明需求；Apple純觀察不需要該下載。模型角色本身不表示做過動作，仍需核對實際結果與讀回。build22的離線路由、CLI及UI檢查已通過；本輪沒有測試新的實體相機調整。

### build16的歷史硬體結果

較早的混合路由依可用控制權選擇流程，尚未區分本次任務模式。一次build16真機任務以38.039秒完成，11項檢查通過；MLX順序為`capture_frame → camera_zoom_status → camera_set_zoom → capture_frame`，只有一次raw200縮放並取得verified讀回。App再取新影格交給Apple，這不是額外的模型工具呼叫。其後恢復raw100及manual。

這是build16單一有界案例的證據，不是build22新增的硬體驗收，也不代表Apple曾獨立控制相機。公開beta1維持build9，詳見[硬體紀錄](../HARDWARE_ACCEPTANCE.md)。

## MCP 與 CLI

保持 App 開啟，從接入頁複製 MCP JSON，或使用[首頁設定](../../README.zh-Hant.md#mcp-與-cli)。安裝後的 helper 路徑是 `/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3`，MCP 使用 `args: ["mcp"]`。它透過私有本機 Unix socket 呼叫 App，遵守存取選項。

```sh
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' status
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' snapshot --output "$PWD/pocket3-frame.jpg"
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' ask --engine apple --question '讀取畫面上可見的標籤。'
```

build22開發版CLI以 `ask --intent observe|assistFraming` 明確指定本次任務；省略時預設為 `observe`。例如：

```sh
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' ask --engine apple --intent observe --question '畫面中有什麼？'
```

`assistFraming`仍需要符合條件的相機控制權與能力。Debug版 `evaluate-workflow` 的模擬相機也接受相同intent，省略時同樣只觀察；模擬動作不是硬體證據。

MCP維持六個基礎相機工具：`camera_status`、`capture_frame`、`move_gimbal`、`stop_gimbal`、`camera_zoom_status`、`camera_set_zoom`。CLI的`ask`、圖片檔案分析及評測入口沒有另包成新的MCP工具。

MCP 縮放先取得 `camera_status.capture.sessionID`，以 `expectedSessionID` 傳給 `camera_zoom_status`，再選擇符合其 minimum／maximum／step 刻度的整數 `rawValue` 呼叫 `camera_set_zoom`。檢查 `completed` 與 `verified`，再取得新影格。取消或未確認的動作不能觸發自動連續重試。

## 常見問題與更新

| 現象 | 下一步 |
|---|---|
| 找不到相機 | 檢查 USB 資料連接，並在機身選擇 Webcam。 |
| 列出相機但沒有預覽 | 檢查相機權限；若另一個取像 App 占用裝置，先結束它，再以 1080p30 NV12 重連。 |
| MCP 取像被拒絕 | 保持 App 已連接，並先選擇「只允許觀察」。 |
| 模型不可用 | 檢查系統模型是否可用，或完成選配 MLX 模型下載。 |
| AF、快速回中或翻轉不可用 | 這些 App 能力尚未完成，單純配對不會啟用它們。 |
| 電量持續下降 | 核對機身電量與供電連接；USB 配置值不是電流實測值。 |
| 關閉主視窗後相機仍在使用 | 以「隱私暫停」釋放擷取，或「結束」終止服務。 |

beta 1 已包含本專案 Sparkle 設定，Beta signed feed 也已完成 Keychain 簽署與發布。公開 HTTPS 下載的 feed 及 ZIP 已透過 CryptoKit 與本專案 Ed25519 公鑰驗證。自動檢查依你的偏好啟用，也可透過 [GitHub Releases](https://github.com/YuhuanStudio/Pocket3-Controller/releases) 手動下載。實際從一個已發布版本更新到下一版的安裝、替換與重啟尚未驗收；不要把 `main` 的開發版視為更新的公開下載。
