# Pocket 3 Controller：完整能力盤點與產品路線

研究日期：2026-09-12  
基準版本：`387857f`、build 25、Pocket 3 韌體 `01.06.10.04`（camera `10.00.50.51`、gimbal `01.00.15.81`）

## 結論

Pocket 3 的機身功能還沒有挖掘完，也沒有完整適配完。目前專案已具備可靠的 macOS Webcam 基礎、USB UVC 預覽與部分雲台／縮放控制、BLE 配對與唯讀遙測、MCP／CLI、更新機制、三語介面，以及本機 AI 的第一版架構。但「Pocket 3 Controller」真正需要的機身控制層仍只有研究、解碼器、候選 writer 與少量失敗或有限成功的實機證據。

接下來不應把專案收斂成單純 API server 或 MCP server。正確形態是：**原生 macOS 創作者控制台作為產品本體，內含單一相機核心與背景 bridge；CLI、MCP、App Intents、Shortcuts 和之後的 SDK 共用同一套 typed capability API。** MCP 是其中一個入口，AI 是建立在可靠相機能力與時間軸資料之上的工作流，不是另一個孤立頁面。

最重要的工程轉折，是把目前散落在 UVC、BLE、Wi-Fi／DUML、App UI 和 AI tools 的能力收斂為一份動態 capability graph：每項功能都分開記錄「機身有沒有、目前 session 可不可用、能否讀、能否寫、寫後是否確認、是否在本機實機通過」。只有這樣才能避免把官方機身規格、別人的逆向結果、USB descriptor 與我們的實機成功混成同一個「支援」。

## 證據標準

本文使用五級證據，不用單一勾選框掩蓋差異：

| 等級 | 定義 | 可以對使用者宣稱 |
|---|---|---|
| A | DJI 官方規格或手冊 | 機身具備此功能；不代表第三方可控制 |
| B | 公開、可核對的同機型／同韌體逆向與實機紀錄 | 協議有強證據；仍不是我們的實機成功 |
| C | 本專案 parser、encoder、fixture 或模擬測試 | 軟體資料層已完成 |
| D | 本機唯讀實機回報 | 此機／此 session 能讀 |
| E | 本機受控寫入、matching readback、物理效果及恢復 | 可以正式開放為控制功能 |

UI 必須同時反映 session 狀態。某項能力即使達到 E，也可能因拍攝模式、錄影中、USB ownership、相機方向或 Wi-Fi datalink 未就緒而暫時不可用。

## 目前真正完成的範圍

### USB Webcam 與 host 影像

- 本機枚舉到 16 個 AVFoundation 格式：720p、1080p、4K 橫幅，以及 720×1280、1080×1920 直幅。機身轉直後沒有新增 3K UVC descriptor。
- 13 個 NV12 橫／直幅模式已在 build 25 以暖機、freshness、尺寸與 FPS 指標驗證；4K 24／25／30 暖機後分別約 23.98／25.00／29.97 fps。
- 1080×1920 與 720×1280 的 24／25／30 組合已有多項實機證據。直幅預覽邊緣指標沒有顯示明顯上下黑邊。
- UYVY 雖由裝置宣告，但 1080p30 與 4K60 在 AVFoundation 路徑仍為零 sample。不能宣稱支援。
- AVFoundation host H.264 output 已通過 1080p30 與 4K30；直幅供給率不足 30 fps。此為 Mac 端輸出 codec，不是相機 USB wire H.264。
- HEVC parser、VideoToolbox decoder 和本機合成 round-trip 已完成，但 AVFoundation 沒有提供 Pocket 3 `hvc1` output；仍未取得實際相機 HEVC frame。

DJI 官方韌體更新資料確認 Pocket 3 後續加入 4K UVC、直播 ActiveTrack 與 DJI Mic 2；官方機身拍攝規格則另列 3K 1:1 與 3K 直拍。這些是不同能力面。[1][2a] OpenPocketCine 的同機型調查也只在 UVC descriptor 中看到 720p、1080p、直幅與 4K，原生 3K 是機身錄影格式而非 USB Webcam 選項。[3]

### USB 控制

- UVC absolute pan／tilt／roll／zoom 的 range、readback、停止與有限回復流程已建立。
- 目前手動雲台是 USB UVC 連續控制路徑；速度依搖桿離中心距離映射。
- UVC 控制不等於機身搖桿語義。雙擊回中心和三擊前後翻轉應使用原生 gimbal command，不能用逐步 pan 模擬。
- 完整物理視角、所有邊界、移動中 stop latency、碰撞／機構限制仍未完成 E 級驗收。

### BLE／原生 session

- 已配對同一 Pocket 3，且不改變 Mac 的主要網際網路路由。
- 電量、充電狀態、容量、剩餘錄影時間、錄影狀態、姿態與部分 camera properties 已有 D 級證據。
- AF-C、WB Auto、曝光 Auto／EV 0、HEVC body setting 曾讀回。
- WB、壓縮格式、tap AF 等 writer 已做成受控單次寫入器，但實機沒有 ACK 或 matching readback，不能開放為正式控制。
- BLE-only 雲台指令會受 camera live-session 狀態影響；不能再把「已配對」當成所有原生控制都可用。

## Pocket 3 機身能力完整盤點

下表是產品需要覆蓋的能力面，而不是聲稱目前全部可寫。

| 能力群 | Pocket 3／協議證據 | 本專案現況 | 下一個可交付結果 |
|---|---|---|---|
| 拍攝模式 | Video、Low-Light、Slow Motion、Photo、Panorama、Timelapse、Motionlapse、Hyperlapse 有狀態 enum；公開逆向有部分 mode setter | 能讀部分模式，沒有安全的 mode capability table | 先唯讀顯示合法模式；逐模式做單次切換與恢復 |
| 機身錄影格式 | 16:9 1080／2.7K／4K、1:1 1080／2160／3K、9:16 1080／2.7K／3K；`02/18` resolution byte 同時帶 aspect，FPS 為 sparse enum | decoder 與部分 writer foundation 已有；UI 仍以 Webcam 格式為主 | 新增獨立「機身錄影」頁，僅呈現 `camcap_video_format` 當前合法 pair |
| H.264／H.265 | `02/AB` 與 body readback 有公開證據；可用性受色彩／模式影響 | HEVC readback 成功，HEVC→H.264 writer 未生效 | 捕捉正確 transaction／routing；先 no-op，再一次往返 |
| 錄影 | `02/02 01/00`；終態由 recording／transition bits 判定 | 唯讀狀態有；未開放機身錄影按鈕 | Start／Stop 各一次，必須終態 readback；避免 toggle |
| 對焦模式 | `02/24` S-AF／C-AF；Product Showcase 為 keyed param | AF mode 可讀，setter 未實機確認 | 先完成 S-AF↔C-AF；再以 readback 實作 Showcase sequence |
| 點按對焦 | 最新公開實機資料顯示是 `02/22 → 02/30 → 02/68 → 02/32` 四步 burst | 目前只送到前段後 timeout，坐標映射也未定案 | 依四步完整重構；橫／直幅、鏡像、rotation 各做 4 角＋中心驗證 |
| 曝光 | Auto／Manual、EV、ISO、ISO limit、shutter 有命令；有效 ISO 與 selected selector 不同 | Auto／EV／有效 ISO 可讀；writers 未通過 | 先 Auto EV；再 Manual mode＋ISO／shutter atomic preset |
| 白平衡 | Auto／Custom Kelvin／tint，`02/2C`；公開資料要求單一 in-flight/coalescing | Auto 可讀；5600K writer 無 ACK | 對齊 datalink ACK pump 後做 Auto↔Custom 往返 |
| 色彩 | Normal、HLG、D-Log M 有 Pocket 3 專用 byte | decoder／encoder 有，未實機寫入 | 只顯示本機 capability；寫後驗證色彩 state，不宣稱 USB 10-bit |
| 影像調整 | 官方韌體提供 sharpness、noise reduction；後續另有 breathing compensation | 尚未建立 typed state／writer | 先找 capability／readback，再做各模式可用性矩陣 |
| Med-Tele | 官方韌體提供高品質 2×／40 mm 等效；最大 ISO 1600，與 ActiveTrack 互斥 | 只有公開 candidate command，未實機驗證 | 作為獨立 lens mode，不混成 digital zoom；顯示互斥條件 |
| 美顏／外觀 | App Glamour 有 keyed parameter blob；機身另有 skin tone／外觀選項 | 尚未形成安全 schema | 唯讀完整 blob，保存未知欄位；確定各 mode 支援後才開放 |
| 原生縮放 | `02/B8` absolute／relative／stop；上限隨 4K／2.7K／1080 變化 | 正式產品仍主要用 UVC raw 100…400 | 新增語意倍率與相對 slew；由當前 body format 限制 2×／3×／4× |
| 雲台快捷 | `04/4C FE08` 回中心、`FE09` 180°；`04/01` joystick；`04/50` follow／tilt lock／speed | USB連續控制可用；原生快捷尚未正式可用 | 建立 datalink-ready gate，實測雙擊／三擊語義並立即定位 |
| 雲台模式 | Follow、Tilt Locked、FPV、速度 preset 有公開命令與狀態 | 尚未做完整 UI／readback | typed mode state、一次切換、姿態與機身 UI 雙驗證 |
| ActiveTrack | `02/A6` tracking box、`02/A5` lock poll、`02/89` live subject box 有公開實機證據 | 只有 off baseline；先前沒有取得有效 on/off 差異 | 先 passive on/off capture，再 box set／clear，最後才接 preview 選框 |
| Photo | 16:9／1:1、JPEG／JPEG+RAW、倒數、shutter | parser 有部分欄位，無產品流程 | Photo mode capability＋一次 shutter；檔案出現作為完成條件 |
| Panorama | 180°／3×3、pano shutter、RAW 有命令 | 未實作 | 先 read-only；有可取消／可恢復的專用流程後才寫入 |
| Timelapse 系列 | interval、duration、save type、motion path 有公開結構 | decoder 有部分欄位，無完整控制 | 先解碼 capability；建立 preview path editor 與 abort／restore contract |
| 音訊 | channel、Vocal Boost、wind／directional DSP blob 有公開命令 | USB PCM 擷取已做；機身 DSP 尚未產品化 | GET 完整 blob、原封保留未知 bytes，只改單一已知欄位再 SET |
| 電池／供電 | BLE battery push 與 macOS USB power 可觀察 | 已顯示電量、notCharging；「插線但不充電」仍需跨訊號判定 | 建立 USB present＋battery trend＋charging flag 的有時間窗診斷 |
| 儲存與媒體 | 容量、剩餘時間、列表、HTTP range download、favorite、delete 有公開流程 | 容量只讀；沒有媒體庫 | 可選 Wi-Fi transport，先 read-only list／download；刪除與 format 最後做 |
| Live view over Wi-Fi | datalink 上 720p 約25fps H.264；單 client、IDR 與 ACK pump 有嚴格生命週期 | 不採用，因不能犧牲 Mac 網際網路 | 僅作「第二網卡／專用網路介面」可選 backend，不取代 USB 預覽 |
| 系統／附件 | 螢幕方向、韌體、序號、SD、DJI Mic 2、Battery Handle 等 | 方向、韌體與部分狀態已知，附件未完整辨識 | typed accessory inventory 與 compatibility warnings |
| 機身行為 | Screen Rotate & Capture、Auto Power Off、Wearable mode、Selfie Flip 等由韌體提供 | 沒有完整狀態／控制 | 先當 read-only device preferences；避免遠端環境被自動關機 |
| Webcam／直播增強 | 官方韌體新增 4K UVC、Webcam D-Log M，直播可用 ActiveTrack 與 DJI Mic 2 | 4K30 capture 已驗證；其餘沒有完整矩陣 | 分別驗證 Webcam 色彩、追蹤、麥克風與 OBS 工作流 |

以上命令細節主要由近期 Pocket 3 實機逆向 catalog 支持，包括原生格式、追蹤、四步 tap AF、雲台快捷、雲台參數與音訊 DSP。[3][4] 它不是 DJI 公開 SDK，因此每一個 setter 仍要在本專案升到 E 級後才進穩定 UI。

## 為什麼先前 writer 不生效

目前最可能的根因不是 payload 全部錯，而是把 BLE 配對通道與完整 datalink 控制 session 混為一談。最新公開實作指出 camera command replies 會走 datalink packet type `0x03`，需要正確的 window ACK pump；live session 還需要約 1 Hz presence keepalive，影像啟用後 window ACK 可達約 40 Hz。[4][5] 我們在 pair-only BLE 路徑送 WB、壓縮與 tap AF 時收到 telemetry，卻拿不到 setter ACK／matching property，符合「狀態通道成立、可寫 session spine 未成立」的症狀。

因此下一步不是繼續隨機重送不同 payload，而是：

1. 建立 `NativeCameraSession` 狀態機：disconnected → BLE paired → credentials available → datalink handshaking → command ready → live ready。
2. 每個 command 明示最低 readiness。唯讀電量只需 paired；WB／record／track 要 command-ready；Wi-Fi preview 才要 live-ready。
3. 實作 window ACK、presence keepalive、sequence ownership 和一個 in-flight command registry。
4. 在 Mac 保持 Internet 的限制下，先用專用網路介面或第二 NIC 做 datalink 研究；產品不得自動切走主要 Wi-Fi。
5. 先完成純 protocol replay 與狀態機測試，再做一次 no-op read／write。沒有 matching state 就不重試。

Camera Wi-Fi 是 `192.168.2.1` SoftAP 流程，單純加入 AP 不會自動複製既有 live stream，而且單 client 行為與 5-tuple 綁定。[5][6] 這也解釋了為何 Mac Studio 遠端使用不應依賴「螢幕開著」或主要 Wi-Fi 被相機占用。

## 建議產品形態

### 1. 原生 macOS App 是主產品

App 應有五個一級工作區：

1. **Live**：低延遲預覽、連續雲台、語意縮放、tap AF、追蹤框、錄影狀態。
2. **Camera**：機身拍攝模式、格式、曝光、WB、色彩、focus、audio；與 USB capture 設定明確分開。
3. **Scenes**：可命名的整體 preset。一次保存 host capture、body mode、gimbal、AI 與輸出策略，並以 dependency-aware transaction 套用。
4. **Library & Timeline**：本機錄影、相機媒體索引、事件標記、轉錄、物件與鏡頭運動 metadata。
5. **Automation**：MCP、Shortcuts／App Intents、HTTP/local IPC、hotkeys、Stream Deck／OSC 等入口與權限。

狀態列應表達當前產品事實：USB、native session、相機供電／電量、capture、body recording、AI、automation 和更新。它應沿用 YunAudio 的視覺語言與高度／間距規則，但資訊模型必須針對相機重新設計。

### 2. 單一核心，多種入口

所有入口只能呼叫同一套 actor-isolated `CameraCapabilityService`，不能各自直接碰 USB／BLE／socket。核心回傳 typed result：requested、submitted、acknowledged、observed、physicallyVerified、restored、generation 和 evidence source。

- App：完整互動與視覺 feedback。
- CLI：診斷、腳本與 headless 管理。
- MCP：工具、resources、prompts、notifications；協議版本保持 `2025-11-25`。MCP 官方把 tools、resources、prompts 分成不同控制面，適合把「動作」與「相機狀態／時間軸上下文」分開。[7]
- App Intents／Shortcuts：常用、可預測、可取消的高階動作，如「切換到直拍訪談場景」「回中心」「開始本機錄製」。macOS 27 的 App Intents 可將 actions 與 entities 暴露給 Siri／Apple Intelligence，適合 Scene、Camera、Recording、Marker 等實體。[8]
- SDK／plugin：待 capability API 穩定後再開放，不先承諾 ABI。

### 3. Headless 與 Mac Studio

遠端 Mac Studio 是一級使用情境，不是例外。需要：

- background agent 在沒有 App window 時維持 USB capture／控制 ownership；UI 只是 client。
- 登入後 headless、螢幕鎖定、螢幕休眠、Remote Desktop 連入／斷開各有 acceptance test。
- 虛擬顯示或 portrait effect 不得成為 capture 必要條件；關閉視窗不應觸發 privacy pause，除非使用者明確停止。
- 硬體 disconnect、USB bus reset、App crash 後可恢復；不盲目重送可能改變相機狀態的命令。
- 遠端 health endpoint 僅回 telemetry 和診斷，不洩露影像或 Wi-Fi credentials。

## AI 與內容工作流

AI 的產品價值不應是「聊天控制相機」。應該建立一條即時、可回看、可自動化的影像理解管線：

`Capture → Frame sampler → deterministic perception → temporal event store → VLM enrichment → rules/agent → user-approved camera action`

### 即時層

- Core AI／Vision 做人臉、人體、物件、文字、構圖、blur／曝光、聲音活動與 tracking primitives。
- 這層必須低延遲、可量測、無 LLM 也可運作，用於 auto-framing 建議、錄影品質警示與事件觸發。
- macOS 27 的 Core AI 提供 Swift API、ahead-of-time compilation、Apple Silicon 執行與專用 Instruments；Apple 也明確建議新的自訂 neural-network 工作優先考慮 Core AI。[9][10]

### 語意層

- MLX Swift LM 保留為可下載、可替換的本機 LLM／VLM runtime，適合進階視覺問答、離線摘要與研究模型。官方 MLX Swift LM 同時提供 LLM 與 VLM，圖片與文字可以走同一 generation API。[11]
- Foundation Models 在 macOS 27 可直接接受 `NSImage`、`CGImage`、`CVPixelBuffer` 等 image attachments，並能以 Dynamic Profiles 切換 tools、模型與 instructions。[12]
- 影片不要逐幀送進 LLM。Apple 的框架目前沒有內建 video input；應先用 Vision／Core AI 產生關鍵影格、轉錄與事件，再交給 VLM／LLM 做跨時間推理。[13]

### 可以形成產品差異的功能

- **Director Monitor**：構圖、焦點、人物出框、曝光、收音、儲存與供電的即時提示。
- **Semantic Replay**：用自然語言搜尋「講到 beta 2、人物轉身、畫面失焦前十秒」。
- **Smart Markers**：手勢、語句、鏡頭運動、record transition 或異常自動打標。
- **Scene Copilot**：把自然語言轉成可預覽的 Scene transaction，先顯示將改哪些值，再執行；底層仍使用 deterministic tools。
- **Local Auto-framing**：當 DJI tracking 不可用時用 host perception 產生 bounded gimbal command；先 suggestion mode，再 supervised mode，最後才 continuous autonomous mode。
- **Multi-camera future**：capability graph 不綁死 Pocket 3 enum；可吸收 Pocket 4／4 Pro／Nano，但每個 model profile 必須有獨立證據。

## 執行順序

### Phase 0：把事實模型整理正確（1–2 週）

1. 新增 capability graph 與 evidence level，取代散落 boolean。
2. 把 UVC capture format、host output codec、body recording format、Wi-Fi live profile 分成四個型別。
3. 更新既有 settings 文件到最新 Pocket 3 command catalog；修正 tap AF 為四步流程、原生 gimbal shortcut、zoom、tracking 與 gimbal params。
4. 稽核 audio DSP blob 長度與未知 bytes 保留策略；以實際 GET 回覆為準，不硬編寫長度。
5. 建立每個可寫動作的 transaction／restore result 契約。

退出條件：App、CLI、MCP 對同一能力回傳相同 availability 與 evidence；3K 不再出現在 USB 格式選單，而會出現在 body recording capability。

### Phase 1：原生 command-ready session（2–4 週）

1. 實作 datalink handshake、presence、window ACK、sequence owner、generation teardown。
2. 在不影響主要 Internet 的第二介面測試 command-only session。
3. 依序驗證 no-op WB、AF mode、color、body format、gimbal mode。
4. 每項只做一次往返並恢復已知原值。

退出條件：至少 WB、AF mode、body format、原生 recenter／180° 各有 E 級證據；斷線後不會誤用舊 ACK／readback。

### Phase 2：創作者必要功能（4–8 週）

1. body record start／stop 與錄影終態。
2. 3K／直拍／1:1 的 body format capability UI。
3. tap AF 完整座標校準與 Product Showcase。
4. native zoom、gimbal mode／speed、快捷鍵與 Scene preset。
5. 供電異常、容量、溫度／斷線與錄影風險提示。

退出條件：使用者不碰機身，也能完成一次「選模式 → 構圖／對焦 → 錄影 → 停止 → 確認檔案」流程。

### Phase 3：追蹤、媒體與 headless（8–12 週）

1. DJI ActiveTrack passive capture、box set／clear、lock state 與 subject box overlay。
2. optional camera network backend：read-only library／download，保留 Mac Internet；delete／format 不在首版。
3. background agent、screen-locked／display-off／Remote Desktop acceptance。
4. App Intents、MCP resources／notifications、Scene automation。

退出條件：Mac Studio 無本地螢幕互動也能穩定連線、預覽／錄製、執行 scene 並回報健康狀態。

### Phase 4：AI 工作流（與 Phase 2 後段並行）

1. 建立無影像持久化的 frame sampler 與 temporal event schema。
2. 以 Core AI／Vision 實作 deterministic quality signals。
3. 以固定 evaluation dataset 比較 Foundation Models、MLX VLM 與特定 Core AI models。
4. 先做 Director Monitor 與 Semantic Replay；之後才做可移動雲台的 agent。

退出條件：AI 功能在固定資料集上有 precision／latency／memory／energy 指標，且任何 camera action 都可解釋、取消、限速與恢復。

## 接下來最值得追的十個發現

1. **正確 native session spine**：找出目前 setter 無 ACK 的確切缺環節。
2. **Pocket 3 `camcap_video_format`**：取得當前 mode 真正合法的 3K／FPS pair，不以靜態笛卡兒積猜測。
3. **四步 tap AF**：確認每一步 routing、ACK、座標方向與機身 focus region readback。
4. **ActiveTrack on/off 差異**：只做事件捕捉，先證明 `A5/A6/89` 在此韌體成立。
5. **原生 `FE08/FE09`**：驗證雙擊回中心與三擊翻轉的直接定位與 latency。
6. **機身錄影完整生命週期**：開始、transition、recording、停止、媒體出現。
7. **供電診斷**：USB present 但 `notCharging` 是正常滿電、功率不足、溫度、接觸或模式限制中的哪一類。
8. **第二網路介面**：USB Ethernet／Thunderbolt bridge／額外 Wi-Fi 是否能綁定 camera route 而保留 default route。
9. **direct UVC ownership**：在公開 API 與安全 teardown 下取得 VS interface，決定 4K60／wire H.264 的可行性。
10. **headless capture**：登入後無顯示器、鎖屏、螢幕休眠與遠端桌面的實際 CMIO／AVFoundation 行為。

這些實驗都有明確的正／負結果；遇到負結果後應前進到下一項，不再因單一未知命令卡住整個專案。

## 1.0 的完成定義

1.0 不要求逆向出機身每個隱藏工程參數，但需要完整覆蓋使用者可見且與 Mac 工作流相關的功能：連線、預覽、橫／直幅、機身錄影格式與錄影、曝光／WB／色彩／focus／zoom、連續雲台與快捷、追蹤、音訊、供電／容量、場景、headless、自動化與診斷。

每個宣稱支援的 setter 必須至少有一個目前支援韌體的 E 級驗證；每個未支援項目要顯示具體原因。高風險的刪除、格式化、韌體更新與無監督連續雲台動作需要獨立設計和更高驗收門檻。AI 功能必須能在完全關閉時不影響相機核心。

## Sources

[1]: [DJI Osmo Pocket 3 Support / specifications](https://www.dji.com/support/product/osmo-pocket-3)

[2]: [DJI Osmo Pocket 3 firmware release notes](https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20250826/DJI_Osmo_Pocket_3_Release_Notes_en.pdf)

[2a]: [DJI 2024-05-15 release notes — 4K UVC, livestream ActiveTrack and DJI Mic 2](https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20240515/DJI_Osmo_Pocket_3_Release_Notes_en.pdf)

[3]: [OpenPocketCine — Pocket 3 findings](https://openpocketcine.app/docs/protocol/pocket3/)

[4]: [OpenPocketCine — command catalog](https://openpocketcine.app/docs/protocol/commands/)

[5]: [OpenPocketCine — live view](https://openpocketcine.app/docs/protocol/live-view/)

[6]: [OpenPocketCine — camera Wi-Fi](https://openpocketcine.app/docs/protocol/wifi/)

[7]: [Model Context Protocol 2025-11-25 — server primitives](https://modelcontextprotocol.io/specification/2025-11-25/server/index)

[8]: [Apple WWDC26 — Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/)

[9]: [Apple WWDC26 — Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/)

[10]: [Apple WWDC26 — Coding Intelligence, Machine Learning & AI Group Lab](https://developer.apple.com/videos/play/wwdc2026/8121/)

[11]: [Apple MLX — mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)

[12]: [Apple WWDC26 — What’s new in the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2026/241/)

[13]: [Apple WWDC26 — Apple Intelligence Group Lab](https://developer.apple.com/videos/play/wwdc2026/8011/)

[14]: [lib-osmo-ble protocol notes](https://github.com/yigitkonur/lib-osmo-ble/blob/main/PROTOCOL.md)

[15]: [Osmosis protocol map](https://github.com/KonradIT/osmosis/blob/main/docs/01-protocol-map.md)

[16]: [DJI Pocket 3 direct UVC 4K60 reference](https://github.com/stephanebhiri/DJI_OSMOPOCKET3_TO_HDMI_4K_60P_50P)
