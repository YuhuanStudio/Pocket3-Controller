# Pocket 3 裝置功能擴充路線

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

更新：2026-09-08。使用者已將範圍擴大為「盡力支援 Pocket 3 本身可用的設定與功能」，包含完整可用視角、前後轉向、回中、更多橫直式格式，以及供電／充電提示。本文件取代先前將這些裝置功能一律留待 1.0 之後的排序；不把可行性研究列成已完成功能。

**2026-09-09補充：** build 5已把低電量／持續下降提醒與只讀BLE姿態接入日常介面，並通過本批離線Release gate；它們使用已存在的BLE回報，沒有新增無線寫入。新的整合實機回歸仍待相機開啟。[功能與規則](BLUETOOTH_TELEMETRY.md)。下表其餘狀態為研究時快照，最新實作／實機證據以前述文件及[TODO](../TODO.md)為準。

目標仍是同一個 Pocket 3 MCP 原生 App，共用相機服務、AI、MCP／CLI 和 YunAudio／YunUI 設計。USB 模式先擴充已宣告的能力；需要 DJI 私有協議的設定，新增明確的裝置遙控連接模式，而不是把不存在的 USB 控制項畫成可用按鈕。完整功能支援包括狀態讀取、合法選項、寫入、回讀、錯誤和中斷處理。

本輪操作者回報版本：整機 **01.06.10.04**、Camera **10.00.50.51**、Gimbal **01.00.15.81**。USB `bcdDevice=0x0504` 不代替這些韌體版本。以下「本案狀態」是研究時的快照；同步開發中的功能只有在新實機報告通過後，才能提升為已驗收。

## 1. 實作順序與判定

| 批次 | 要交付的裝置功能 | 完成標準 |
|---|---|---|
| P0：目前 USB 擴充 | 可用格式清單、橫直式、完整宣告範圍目標、USB 回中／前後預設、供電資訊與未知充電提示；接著 zoom／roll | 所選輸出有新影格；控制往返、停止、邊界和每個預設有實機證據；UI 如實標示 USB／機身差別 |
| P1：裝置遙測與無線連接 | 原生 CoreBluetooth 配對、DUML frame／CRC／通知、電池／充電、相機狀態、儲存資訊；必要時 Wi-Fi UDP session | 逐筆資料有來源、版本、session、時間與有效期；先證明 USB 共存情況，不能為遙測默默中斷既有取像 |
| P2：已有 Pocket 3 協議依據的設定 | 曝光、白平衡、對焦模式、色彩、機內錄影／拍照、格式、音訊聲道、原生回中／轉向 | 獨立 setter、狀態回讀、模式相容性、寫入失敗處理；依目前韌體逐項驗收 |
| P3：需補協議或複合狀態的功能 | 原生追蹤、完整雲台模式、降風噪／指向音、美顏、機身方向策略、素材管理與系統選項 | 取得 Pocket 3 的獨立命令和回讀證據後實作；沒有證據的欄位保留研究狀態 |

「待 transport」表示目前 USB 核心沒有取得該能力所需的通訊路徑，不代表硬體不能做。「已有開源實作」也不等於已在這台相機驗收。每項 capability 建議記錄 `read/write`、transport、合法值、依賴模式、證據等級及不可用原因。

## 2. USB、視角與取像

本案現有 USB 枚舉只列 `pan-tilt-abs`、`zoom-abs`、`roll-abs`；沒有曝光、白平衡、對焦、電池或相機設定的標準 UVC 控制。枚舉證據見 [完整 UVC 控制表](../research/2026-09-07/uvc-controls-complete.txt)。不能因 UVC 規範定義某控制，就認為這台相機有實作它。

| 功能 | 本案狀態 | 已知能力／實作路徑 | 下一步與限制 |
|---|---|---|---|
| USB 選擇、權限、熱插拔、獨立 session | 已實作；恢復驗收持續補齊 | 同一 AVFoundation 來源對應 USB attachment；顯式選擇及偏好保存 | 斷線撤回控制、清除舊影格；多台同型號不能選第一台代替 |
| 1080p30／4K30 預覽及 JPEG | 已有實機基線 | AVFoundation；4K UVC 25/30P 由韌體 01.04.08.02 加入。[DJI 韌體紀錄][rn] | 最新格式管線需核對實際輸出，不能只顯示請求值 |
| 原生 USB 直式 | 本輪擴充中 | 舊枚舉有 720×1280@25/30、1080×1920@24/25/30；官方也說 Webcam 支援直拍。[本機格式](../research/2026-09-07/avfoundation-inventory.json)、[DJI Webcam][webcam] | 先協商真正直式格式，驗證方向、黑邊與回讀；不是將橫式圖片裁切後冒稱原生直式 |
| 更多橫式解析度／fps | 本輪擴充中 | 舊枚舉有 1280×720、1920×1080、3840×2160，依各格式宣告選項。[本機格式](../research/2026-09-07/avfoundation-inventory.json) | 從裝置產生清單；24/25/30 分別驗證；60fps 舊測無影格，不能因枚舉存在便標示已支援 |
| 3K／2.7K 直式、1:1、高幀率 | 機內有；USB 未證實 | 官方普通錄影包括 1728×3072、1512×2688、1080×1920 與方形格式。[DJI 規格][specs] | 舊 USB 枚舉沒有 3K／2.7K 直式；Pocket 4 的 Webcam 規格不得套用到 Pocket 3 |
| pan／tilt 完整可用目標 | 小步進已有基線；絕對目標政策已寫入，正在整合 | 本案 USB 宣告 pan −126000…774000、tilt −324000…324000；依裝置範圍驗證目標 | 不是只允許一度小步；大目標需停止、逾時、路徑與終點驗證；未知結果不自動重試 |
| USB 回中／前方／後方 | 政策已實作；各預設待實機 | 回中／前方取 GET_DEF；後方取同預設 pan±180° 中合法的一側，保留預設 tilt | 這是 App 定義的 UVC 預設位置，不能宣稱已送出 DJI 搖桿雙擊／三擊命令 |
| 原生 DJI 回中、前後切換 | 機身可用；本案待無線 transport | 機身雙擊／三擊搖桿；Kaze 有 `04/4C FE08` 回中與 `FE09` 前後切換實作。[DJI 手冊][manual]、[Kaze 雲台寫入][kgimbal] | 和 USB 預設分開驗證。Kaze 對 FE09 的文件證據為強相關辨識，不能提高成本案已實測 |
| Zoom | USB 已宣告，未作已驗收控制 | 100…400，step 1。[UVC 控制表](../research/2026-09-07/uvc-controls-complete.txt) | 加入讀取、有限寫入、復原及畫面驗證；實測前不把原始 100…400 當成已校準光學倍率 |
| Roll | USB 已宣告，未作已驗收控制 | −30…30，step 1。[UVC 控制表](../research/2026-09-07/uvc-controls-complete.txt) | 與水平校正／畫面旋轉分開；不能寫 ±90 來冒充直式機身模式 |
| 水平鏡像／90° 畫面旋轉／裁切 | 可在 Mac 管線新增 | 屬輸出變換，不是雲台移動。DJI Selfie Flip 本身指鏡像。[DJI 手冊][manual] | 預覽、儲存、AI、MCP 必須共用明確變換；metadata 保留來源尺寸／方向與變換 |
| 外接廣角鏡頭、ND、黑柔鏡 | 僅實體配件 | 不是 USB 軟體可開啟的硬體。[DJI 規格／配件][specs] | 可保存使用者配件偏好與對應校準，不能偵測不到卻回報已安裝 |

DJI 官方可控範圍為 pan −235°…58°、tilt −120°…70°、roll −45°…45°；機械範圍更大。這組物理數字與本案 UVC 宣告座標不同，不能互相取代，更不能把機械極限當成允許寫入的範圍。[DJI 規格][specs]

## 3. 電池、外部供電與充電偵測

DJI FAQ 說明錄影時直接使用外部電源輸入，停止錄影後才充電；因此「沒有充電圖示」不必然等於「完全沒有外部供電」。Webcam 支援頁對 USB 供電／充電作一般性描述，不能據此保證任何電腦埠和線材都能讓電量增加。[DJI FAQ][faq]、[DJI Webcam][webcam]

官方充電溫度為 5–45°C，最高充電功率 36 W，建議 DJI 30W 或 65W PD 充電器。這不是說 Webcam 必須取得 36 W，亦不能拿 36 W 與 USB descriptor 的 2.5 W 直接比較來診斷故障。[DJI 充電故障說明][charging]

| 功能 | 本案狀態 | 可用來源 | 實作與提示規則 |
|---|---|---|---|
| USB 連接／配置供電資訊 | 本輪實作中 | 精確 attachment 的 IOKit properties、configuration descriptor | 顯示已連線與系統宣告／配置值；不是實際電流，也不是電池充電狀態 |
| USB 電力配置失敗 | 可作條件偵測 | IOKit 若真的提供 `kUSBFailedRequestedPower` 等失敗訊號 | 只在匹配裝置的有效欄位顯示失敗；欄位缺少不等於正常或失敗 |
| 即時耗電／PD 協商功率 | 未取得可用遙測 | 需要真正電源測量或可核對協商資料 | 不從 480 Mb/s、500 mA 配置、`DesiredChargingCurrent` 推算當前耗電 |
| 電池百分比 | USB 未提供；已有 Pocket 3 私有協議依據 | Kaze `0D/02` payload byte 20；需至少 33 bytes、百分比 0…100。[Kaze 電池解析][ktelemetry] | P1 加入 transport 後，以機身畫面對照數個電量、重連及過期樣本 |
| 正在充電／未充電 | USB 未提供；已有開源解析 | 同封包 byte 32：0 未充電、1 充電、其他未知。[Kaze 電池解析][ktelemetry] | 布林三態，附來源與樣本時間；失聯回到未知，不保留上一個充電圖示 |
| 外部電源存在 | 尚無可靠裝置端欄位 | USB attachment 只能證明資料連接，`isCharging` 也不是 external-power 位元 | 保留獨立 unknown；百分比不變也不能證明外部供電正常 |
| 電量下降／低電量警告 | 待真實電池遙測 | 同一裝置、同一 session 的有效百分比趨勢 | 多樣本下降後提示「電量仍在下降，請檢查供電」；不要直接斷定線材或埠故障 |
| 溫度／熱保護原因 | 尚未核對 Pocket 3 telemetry 欄位 | 機身提示為目前可用確認來源 | Mac CPU 溫度不代替相機電池溫度；不能自動宣稱因過熱停止充電 |
| Battery Handle 電量 | 待獨立 protocol | 機身可查看主機與手柄兩個電量。[DJI 手冊][manual] | 不把主機百分比當手柄百分比；handle 本身亦非第二條已知 USB telemetry |

USB 的 `bMaxPower` 描述配置需求上限，不是電流感測器。[USB-IF Type-C 測試規範][usbpower] 本機 SDK 的 `GetDeviceBusPowerAvailable` 回傳「可用」供電，單位為 2mA；`kUSBDesiredChargingCurrent` 名稱也只表示要求值。讀取這些屬性不應改寫 USB 配置或要求更多電流。

建議資料契約：`usbConnected`、`configuredCurrentMilliAmps?`、`availableCurrentMilliAmps?`、`batteryPercent?`、`chargingState=unknown|charging|notCharging`、`externalPowerState=unknown|present|absent`、`source`、`sampleTime`、`fresh`。欄位不能互相推導出沒有量測的結論。

當前可交付的誠實提示是「USB 已連線，充電狀態尚無法讀取」，另提供本機供電資訊和機身檢查指引。若使用者明確回報未充電，標示為使用者回報，不冒充自動偵測。取得有效 battery telemetry 後再升級為低電量／下降警告；100% 且未充電不應直接顯示故障。Kaze 特別記錄外接電源且高電量時也可能不在充電。[Kaze 電池協議說明][kprotocol]

## 4. 相機設定、拍攝與畫質

下表「Kaze 寫入」來自固定版本的 Pocket 3 專用 setter 與讀回程式，而非 Pocket 2、Action 或 DJI 無人機 API。現階段本案沒有此 Wi-Fi 相機設定 transport，因此均不能在 USB 模式假裝已生效。

| 功能 | 本案狀態 | Pocket 3 依據／候選路徑 | 優先級與實作重點 |
|---|---|---|---|
| Pro 開關 | 待 transport | Kaze `proEnabled`，`02/8E` PID 0000。[設定 source][ksettings] | P2；與各拍攝模式合法參數聯動 |
| 自動／手動曝光、ISO、ISO MAX | 待 transport | `exposureMode`／`manualISO`／`isoMax`。[設定 source][ksettings] | P2；以合法枚舉和真實讀回呈現，低光等模式另驗證 |
| 快門速度 | 待 transport | `manualShutter` 有 Pocket 3 對照表；影片快門下限受 fps 約束。[設定 source][ksettings] | P2；不將 Photo 全選單套給 Video／Slow Motion |
| EV | 待 transport | `autoEV(thirdStops:)`。[設定 source][ksettings] | P2；自動曝光模式下檢查生效條件 |
| 白平衡 Auto／Kelvin | 待 transport | `whiteBalance`；`cam_image_effect` 回讀。[設定 source][ksettings]、[讀回 source][kreadback] | P2；寫入後顯示實際回讀值 |
| AF-S／AF-C | 待 transport | `focusMode`；`cam_lens_state` 回讀。[設定 source][ksettings]、[讀回 source][kreadback] | P2；區分模式與是否已合焦 |
| 產品展示對焦 | 待 transport | `productShowcaseEnabled`，PID 003B。[設定 source][ksettings] | P2；顯示和追蹤／曝光模式的互斥條件 |
| 點選對焦／測光、手動焦距 | 研究中 | 機身有點選對焦／測光；本輪固定 source 未取得獨立座標 setter。[DJI 手冊][manual] | P3；不能用 VLM 框選或後製銳化冒稱已改對焦 |
| Normal／D-Log M／HLG | 待 transport | Kaze `colorProfile`；DJI 已加入 Webcam D-Log M 選項。[設定 source][ksettings]、[DJI 韌體][rn] | P2；模式可選不等於 Mac 已取得 10-bit；另驗證實際像素格式／色彩 metadata |
| LUT／色彩還原預覽 | 可先在 Mac 實作 | 對已知來源色彩作預覽轉換，不必寫相機 | P2；預覽和原始輸出分開，不將 LUT 套在未知色彩資料上 |
| 銳度／降噪、呼吸補償、Med-Tele | 機身可用；setter 未確認 | 韌體記錄有功能；本輪固定 setter 未覆蓋。[DJI 韌體][rn] | P3；分別核對模式限制，不能把普通數位 zoom 當 Med-Tele |
| 機內開始／停止錄影 | 待 transport | Kaze `02/02` 寫入，`02/80` recording state 確認。[相機協議][kprotocol] | P2；accepted 不等於錄影已開始；SD 卡、剩餘時間、實際狀態要一起顯示 |
| Mac 本機錄影 | 尚未實作，可用 USB 管線新增 | AVFoundation／AVAssetWriter；與機內錄影獨立 | P2；檔案位置、音訊授權、掉幀與容量可控；明確顯示儲存在 Mac |
| 機內單張拍照、JPEG／RAW、倒數、照片比例 | 待 transport | `shootPhoto`／`photoFormat`／`photoCountdown`／`photoFrame`。[設定 source][ksettings] | P2；與現有 USB JPEG 截圖分開命名，RAW 不得由 JPEG 假造 |
| 機內解析度、fps、HEVC／H.264 | 待 transport | `videoFormat`／`videoCompression`；`cam_video_param_v2` 回讀。[設定 source][ksettings]、[讀回 source][kreadback] | P2；不同於 USB 輸出格式；以目前模式的合法組合建立選單 |
| 機內橫／直／自動方向策略 | 研究中 | `cam_sensor_aspect_ratio` 已有有效方向讀回，但 setter 未解；9:16 格式碼本身不改機身方向。[方向語義][ksettingsdoc] | P3；畫面旋轉不代替機身策略，不重播未拆解複合 payload |
| 普通／低光／慢動作等模式 | 部分命令已知，完整切換待驗證 | Kaze mode IDs 與部分 mode setter；讀回 ID 不等於所有寫入路徑已證實。[設定說明][ksettingsdoc] | P2/P3；先普通 Video／Photo，再逐個模式；不能把高幀率機內格式當 USB |
| Timelapse／Hyperlapse | 待 transport | `timelapse`／`hyperlapseSpeed`。[設定 source][ksettings] | P2；有界任務、實際錄影狀態、間隔／時長合法表 |
| Motionlapse、最多四點、預覽路徑 | 待 transport，路徑取消仍缺證據 | 固定版有依序設點、反序刪除及 Preview；文件未觀察到獨立 Preview stop。[設定說明][ksettingsdoc] | P3；不能把原 USB stop 驗證推廣成原生路徑一定可中斷 |
| 180°／3×3 全景 | 待 transport | `panoramaType`／`panoramaPhotoFormat`／`shootPanorama`。[設定 source][ksettings] | P2/P3；先核對流程、SD 輸出與中斷，不把機身全景當 App 圖片拼接 |
| 美顏／自然膚色等複合效果 | 研究中 | Beauty PID 0039 是多欄位 block，Kaze 未提供獨立安全 setter。[設定說明][ksettingsdoc] | P3；先做讀回與單欄位捕獲，避免帶入別的舊設定 |

## 5. 追蹤、雲台模式與音訊

| 功能 | 本案狀態 | 證據／可行路徑 | 下一步 |
|---|---|---|---|
| 原生 ActiveTrack 6.0 開關／選取目標 | 機身支援；未有本案遠端 writer | DJI 有觸控選取；部分 Webcam 使用情境也支援追蹤。[DJI FAQ][faq]、[韌體][rn] | P3：取得 Pocket 3 的開始／停止／目標座標命令；不拿無人機 ActiveTrack SDK 代用 |
| FT 自拍跟隨、Face Auto-Detect、Dynamic Framing | 機身功能；本輪 writer 未核實 | [DJI 官方功能說明][support] | P3；先顯示「需在相機操作」與控制衝突，不假造 toggle 狀態 |
| App 本機視覺追蹤 | 可建立於現有 Vision／Core AI + UVC | 屬我們的追蹤器，獨立於 DJI ActiveTrack | P2/P3；有停止／失去目標策略後實作，命名不可混淆 |
| 軟體雲台鎖定／解除 | 待無線 transport | Kaze `lockPayload` 使用 `04/4C` 00 00／01 00。[雲台 source][kgimbal] | P2；這對命令不代表完整 Follow／Tilt Locked／FPV 映射 |
| Follow／Tilt Locked／FPV／FPV-⊥ | 研究中 | 機身模式存在；Kaze 未完成三模式隔離映射；FPV-⊥ 由後續韌體加入。[設定說明][ksettingsdoc]、[韌體][rn] | P3；逐項寫入／姿態回讀／操作結果對照 |
| 原生 SpinShot／Wearable | 研究中 | 機身可用。[DJI 手冊][manual] | P3；不能用普通 pan／roll 大角度寫入冒稱原生模式 |
| App 搖桿速度／方向靈敏度 | 可在本機實作 | 由我們的排程／步幅決定，並非已修改機身 Joystick Speed | P0/P2；先限制步幅和取消延遲，不以連續 USB 轟寫取代控制排程 |
| USB 音訊與音量診斷 | 已有 stereo 48kHz PCM 基線／有界測試 | 選定 DJI 音訊來源；預設關閉 | P0：長測、零樣本、格式變化與關閉清理 |
| 機內 Mono／Stereo | 待 transport | `audioChannel`，PID 0020。[設定 source][ksettings] | P2；和 Mac 輸出混音分開 |
| 降風噪／指向音／Audio Zoom | 部分機身功能，writer 待研究 | Kaze `02/9F` 是多欄位結構；Audio Zoom 為機身行為。[設定說明][ksettingsdoc]、[DJI FAQ][faq] | P3；解開複合欄位後逐一寫入，不整包重播 |
| 內建麥克風增益 | 不列為可任意調節的機身功能 | DJI FAQ 說內建錄音不支援使用者自訂增益；外接音訊裝置另論。[DJI FAQ][faq] | 可提供 Mac 音量處理，但須標示主機處理，不能宣稱改了相機增益 |
| DJI Mic 2／Mic Mini 配對、增益、降噪、電量、備份 | 相機部分支援；本案待 accessory protocol | Mic 支援依韌體，不能把相機電池資料當 Mic 電池。[DJI 韌體][rn] | P3：分清主機／TX1／TX2，先查各配件 capability；不占用 USB 資料口假設同時接全部附件 |
| 監聽、播放音量、機內音訊備份 | 待分別核實／實作 | Mac 監聽可本機處理；機內設定另需協議。[DJI 手冊][manual] | P2/P3；防止把監聽音量當錄音增益；不擴張成目前已具備語音助手 |

## 6. 素材、無線、韌體與其他機身選項

| 功能 | 本案狀態 | 已知路徑 | 具體下一步 |
|---|---|---|---|
| 電池／儲存容量／錄影時間／相機模式 | 待 transport | Kaze `0D/02`、`02/DC`、`02/80` 與 `00/99` 讀回。[telemetry source][ktelemetry]、[讀回 source][kreadback] | P1 優先做讀取，可直接改善低電量與即時狀態 |
| BLE 配對與通知 | 本案尚未實作 | Pocket 3 專用 FFF0／FFF4／FFF5 與 DUML，兩個開源來源有實作 | P1：原生 CoreBluetooth、有界連接、明確配對身份和取消，先驗證只讀遙測 |
| Wi-Fi 相機直接連接／H.264 預覽 | 本案尚未實作 | Kaze BLE→Wi-Fi、TCP/7001 bootstrap、UDP/9004 datalink。[transport source][ktransport]、[協議][kprotocol] | P1/P2；需要完整序號／ACK／重組／逾時，不能只開一個 UDP socket 就稱已連線 |
| USB 與 BLE／Wi-Fi 同時使用 | 未在本案證實 | 不同模式可能限制通訊 | 先做短程共存驗證；若互斥，就提供明確「USB Webcam／無線遙控」切換，保留原有設定並停止舊任務 |
| 素材列表／下載／播放 | 待素材 transport | 官方可用 Mimo、USB 檔案傳輸或 SD；Kaze 這份設定實作不包含 media management。[DJI 手冊][manual]、[設定說明][ksettingsdoc] | P3；可先做使用者選定已掛載媒體的匯入。機身切換傳檔會改變 Webcam 工作狀態 |
| 刪除素材／格式化 SD | 尚未有本案可靠命令 | 屬機身破壞性操作，不從其他型號借 opcode | P3；先完成枚舉與精確檔案身份，再提供可審查清單和確認，不作批量猜測 |
| 韌體版本讀取與官方更新檢查 | 已記錄操作者回報；自動讀取待 protocol | 官方透過 Mimo 更新；本案可顯示版本、日期、官方 release notes。[DJI 支援][support] | P1/P3；不把 USB product version 當 firmware，也不把 Mic firmware 當相機 firmware |
| 自動刷寫相機／雲台韌體 | 無本案已驗證更新協議 | 目前保留官方 Mimo 流程 | 研究版本查詢與更新指引；取得完整簽章／恢復／電量規則前，不承諾 App 自刷 |
| 自拍鏡像、啟動方向、關屏錄影、自動關機、旋屏啟停 | 機身選項；大部分 writer 未解 | 手冊有操作項，但不等於已有遠端 API。[DJI 手冊][manual] | P3；逐個查詢／寫入，不以 App 視窗設定替代機身設定 |
| 螢幕亮度、LED、按鍵聲、語言、日期／命名 | 尚未核實 Pocket 3 遠端欄位 | 機身設定與 App 設定分開 | P3；先精確盤點此韌體選單，取得 readback／setter 再搬進 App |
| 網格、直方圖、斑馬紋、對焦輔助 | 可先做 Mac 預覽工具 | Kaze 研究認為多項為 Mimo 顯示功能，未發現隔離相機 setter。[設定說明][ksettingsdoc] | P2；用本機圖像工具實作，保持原始相機資料與輸出選項明確 |
| Timecode 顯示／重設／同步 | 機身有；本案未支援真實 timecode | host callback／AVFoundation PTS 不等於 DJI timecode。[DJI 手冊][manual] | P3；分開標示時間來源，先讀取再研究同步協議 |
| 原生雲台校準／恢復設定 | 機身有；本案無已驗證 writer | 不等同本案 UVC 停止驗證 | P3；操作前展示影響，取得原生完成／失敗狀態再提供 |
| RTMP 直播設定 | 機身有；本案未實作 | lib-osmo-ble 有相關流程，Kaze 本輪未納入穩定設定 writer。[BLE 協議][bleprotocol]、[設定說明][ksettingsdoc] | P3；串流目的地／憑證／狀態獨立管理，不自動替使用者開直播 |

## 7. 固定來源與值得避免的誤用

本輪直接查讀的 Kaze revision 是 `341a35de18493ff61f97c93b8b10161a7512aa36`（文件標記 2026-08-21）；已核對 Pocket3CameraSettings、Pocket3CameraReadback、Pocket3TelemetryDomain、Pocket3GimbalCommands 與 DumlTransport 的固定 source。這些資料是作者自己的 Pocket 3 逆向研究，並非 DJI 官方 API；「作者實測」和「我們實測」各自標示。

lib-osmo-ble 固定 `021e96c2bec7e9a2a81296292545bc1ee432af49`。其 [connection.mjs 第 131–135 行][bleconnection] 把任意 Battery cmdSet 的 `payload[0]` 當百分比，未檢查 cmdId，也沒有充電解碼；和 Kaze 已核對的 offset 20／32 不一致。不能原封不動用來顯示電池。此外其 [gimbal.mjs][blegimbal] 明寫 Pocket 3 忽略 BLE-only 馬達命令；有 API 函式不等於命令可執行。

本輪仍未找到 Pocket 3 對應的 DJI 公開控制 SDK。DJI 官方 [Osmo GPS Controller Demo][officialdemo] 列 Action 4／5 Pro／6、Osmo 360，沒有列 Pocket 3；不能將其 camera-status、battery 或 record 格式直接移植到本案。這是目前查核的型號界線，不是宣稱 DJI 永遠不會提供 Pocket 3 SDK。

本輪新增範圍應優先投入具體相機控制，先完成 P0，再以 P1 通訊與遙測帶動 P2。P3 仍持續尋找可驗證的實作途徑；真正沒有 transport／opcode 證據的項目，交付狀態就是清楚可見的限制與研究進度，不是永遠隱藏，也不是畫上無作用按鈕。

[specs]: https://www.dji.com/osmo-pocket-3/specs
[faq]: https://www.dji.com/osmo-pocket-3/faq
[support]: https://www.dji.com/support/product/osmo-pocket-3
[manual]: https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/UM/20250826/DJI_Osmo_Pocket_3_User_Manual_v1.0_en.pdf
[rn]: https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20250826/DJI_Osmo_Pocket_3_Release_Notes_en.pdf
[webcam]: https://repair.dji.com/help/content?customId=zh-cn03400006962&lang=zh-CN&re=CN&spaceId=34
[charging]: https://repair.dji.com/help/content?customId=01700006786&lang=en&paperDocType=ARTICLE&re=US&spaceId=17
[usbpower]: https://www.usb.org/sites/default/files/USB%20Type%20C%20Functional%20Test%20Specification%202024%2003%2003.pdf
[ksettings]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraSettings.swift
[kreadback]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraReadback.swift
[ktelemetry]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3TelemetryDomain.swift
[kgimbal]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/android/app/src/main/java/com/pocket3/gimbaltest/Pocket3GimbalCommands.kt
[ktransport]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/DumlTransport.swift
[kprotocol]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/docs/POCKET3_DUML_PROTOCOL.md
[ksettingsdoc]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/docs/CAMERA_SETTINGS_PROTOCOL.md
[bleconnection]: https://github.com/yigitkonur/lib-osmo-ble/blob/021e96c2bec7e9a2a81296292545bc1ee432af49/src/connection.mjs#L131-L135
[blegimbal]: https://github.com/yigitkonur/lib-osmo-ble/blob/021e96c2bec7e9a2a81296292545bc1ee432af49/src/controllers/gimbal.mjs
[bleprotocol]: https://github.com/yigitkonur/lib-osmo-ble/blob/021e96c2bec7e9a2a81296292545bc1ee432af49/PROTOCOL.md
[officialdemo]: https://github.com/dji-sdk/Osmo-GPS-Controller-Demo
