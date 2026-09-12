# Pocket 3 原生相機設定：首批範圍與協定證據

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

初次研究日期：2026-09-08；進度更新：2026-09-12。最初固定設定來源為 Kaze for DJI `341a35de18493ff61f97c93b8b10161a7512aa36`；2026-09-12 再以 OpenPocketCine 的 Pocket 3 實機 command catalog 交叉核對原生格式、縮放、點選對焦、追蹤、雲台快捷與音訊。初次研究沒有操作相機；後續已實作首批 command encoder／純狀態管理與 BLE 只讀面板，並在本機取得 AF-C、WB Auto、曝光 Auto／EV0。**WB／EV／AF 模式 setter 仍未通過本機寫入驗收。** Kaze 來源全文、MIT 授權及16份檔案的 SHA-256 見 [PROVENANCE](../research/2026-09-08/camera-settings/PROVENANCE.md)，逐批結果見[硬體驗收](HARDWARE_ACCEPTANCE.md)。新增資料仍屬上游實機協議證據，不會自動升格成本專案真機寫入成功。[OpenPocketCine command catalog][opc-commands]

> 2026-09-12 更正：本文件後段「尚未納入」描述的是 2026-09-08 固定 Kaze 樣本的缺口。原生 zoom、四步 tap AF、Product Showcase、tracking、gimbal shortcut／params 與 audio DSP 現在已有可核對的公開協議證據；它們仍須在本專案完成 typed implementation 和 matching readback／物理驗證。

## 2026-09-09：點選對焦的新增證據

本機 `cam_lens_state` 的47-byte值可從 offset1／5讀到有限的 Float32 LE 候選座標。新的12秒被動觀察已取得31筆中心基準；機身點按後也有非中心值。第一次左上／右下操作混入使用者誤按鏡頭轉向，第二次軸向操作仍待使用者核對，因此尚未完成預覽座標、鏡像及方向校準；也沒有光學合焦成功的遙測欄位。

補充來源 OpenPocketCine `9c4e7334ca4d935c5d467abecaf8f968f7927d84` 提供四步點選流程：`02/22`準備測光、`02/30`焦點區域、`02/68`測光提示、`02/32`提交區域，皆由`02→01`、flags`40`送出。它的實際呼叫走 datalink，不能直接當成 Pocket3 BLE 可寫的證據。[命令](https://github.com/erik-sutton95/OpenPocketCine/blob/9c4e7334ca4d935c5d467abecaf8f968f7927d84/Sources/OpenPocketViewCore/Commands.swift#L270-L314)、[呼叫順序](https://github.com/erik-sutton95/OpenPocketCine/blob/9c4e7334ca4d935c5d467abecaf8f968f7927d84/ios/OpenPocketCine/CameraSession.swift#L2197-L2214)

本案開發探針限制單次序列、同 BLE peer/session 與新鮮 USB capture，逐步區分提交／ACK／座標讀回。Point、Hint、Commit 均要求800ms內成功ACK；其中要求 Hint 成功才繼續是本案較保守的政策，上游會忽略該步ACK失敗。中途取消或拒絕不重送、不猜恢復值；已提交步驟可能影響測光，必須保留部分完成狀態。一般預覽點選功能仍須取得可用傳輸和座標映射的本機證據才開放。

實測更新：build12暴露連續寫入時缺少CoreBluetooth額度等待；build13修正後，Prepare與Point已各單次提交，額度等待約10.472ms。但Point沒有800ms內ACK，後兩步未送，已觀察的lens座標也未匹配請求。這只確認排程修正，不確認BLE AF可用。[逐批結果與後續只讀窗口](HARDWARE_ACCEPTANCE.md#2026-09-09-build13-ble-點選對焦額度恢復point未確認)

## 建議先做什麼

原生配對／session 與停止機制通過後，先建立 `00/99` 個別屬性讀回，再開放 **白平衡、S-AF/C-AF、AUTO 模式下的 EV**。這三項的寫入結構小、選項明確，而且有對應的相機狀態解析與固定 fixture，可做到「讀取原值 → 一次設定 → 新狀態確認 → 恢復原值」。這是本專案的實作優先順序，不是 DJI 的建議。

| 順序 | 具體交付 | 開放條件 |
|---|---|---|
| 0 | 顯示相機回報的 WB、曝光模式／EV／有效 ISO、AF 模式、錄影狀態與錄影格式 | 個別 property 已在當次 session 收到，未知值維持未知 |
| 1 | WB Auto／2000–10000 K、S-AF/C-AF、AUTO EV −3…+3 EV | 每項都有新鮮基準與設定後的同屬性讀回；EV 不會暗中把 Manual 切成 Auto |
| 2 | 曝光 Auto/Manual、色彩模式、機身錄影開始／停止 | 先驗證既有曝光值及模式切換效果；錄影需終態 telemetry，不以 ACK 或 transition 當完成 |
| 3 | 機身錄影尺寸／FPS／編碼、Photo 設定 | 先有模式相容矩陣、方向讀回、busy/recording guard；不套用到 USB 擷取選單 |
| 暫緩 | Manual ISO、ISO MAX、快門的「已套用」UI；任意 mode 跳轉；原生 zoom／焦距／對焦點 | 部分有 setter，但缺完整 selected-value readback 或獨立 writer 證據，不能當作已確認功能 |

白平衡、EV、AF 的寫入與讀回可以交叉比對 [Swift encoders][settings]、[readback decoder][readback] 與 [固定讀回測試][readback-tests]。上游 UI 的 `lastSent*` fallback 不適合直接搬成我們的相機實際狀態；這點在下方列出。

## 證據分級

- **C**：上游記錄為 controlled Mimo capture 所確認；來源是 Pocket 3／Mimo 2.11.5 的研究，並非官方協定。
- **I**：固定版原始碼／測試／跨平台實作可核對編碼。
- **R**：固定版有對應的相機端狀態欄位解析；不代表我們已收到本機回讀。
- **H**：上游文件明確宣稱硬體驗證；本文件仍標成「上游 H」，不升格為本機結果。

`protocol/test-vectors/camera/camera.json` 的 ISO／ISO MAX fixture 自己標記為 `source-confirmed`，而且指向更早的 private source provenance。這些向量可防止抄錯 bytes，不能單獨作為實機效果證明。[fixture][vectors]

## 共用 routing 與結果契約

除另註外，設定送往 Camera receiver type `0x01`、id `0`，DUML source `0x02`、destination `0x01`、command set `0x02`、flags `0x40`（`cmdType=2`）。Sequence 由現有單一 transport owner 分配，不由每個設定控制器自行持有。這由 command defaults 與實際 `sendDuml` address packing 交叉核對。[command defaults][settings]、[routing][transport]

我們的每次操作應分開保存 requested value、transport/ACK 結果、observed value、接收時間與 session/generation。只在該次請求之後的新鮮、對應欄位相符時顯示「已確認」。沒有讀回就顯示 pending／unconfirmed；斷線或 timeout 不盲目重送。相機自己或 Mimo 同時更改值時，顯示新的實際值，不覆寫回使用者已變更的狀態。這是本專案需要補上的結果契約。

## 首批可寫設定的精確編碼

下表所有 bytes 都是 **DUML payload 的十六進位**；不是 USB UVC control、不是封裝後的 Wi-Fi datagram。Offset 表示解包後 property value 的零起算索引。型別範圍由 [Swift setter][settings]、[Android setter][android-settings] 與 [readback][readback] 核對。

| 設定 | Command / payload | 狀態讀回與最短 value 長度 | 證據／限制 |
|---|---|---|---|
| 白平衡 Auto | `02/2C` → `00 00 00 00 00` | `cam_image_effect` ≥6 bytes；`[4]=00` | C/I/R |
| 白平衡 Kelvin | `02/2C` → `06 KK 00 00 00`，`KK=Kelvin/100`；2000…10000，每次100 K；例5600 K=`06 38 00 00 00` | 同 property；`[4]=06`，Kelvin=`[5]×100` | C/I/R；未知 mode byte 不能當 Auto |
| 對焦模式 | `02/24` → S-AF `01`、C-AF `02` | `cam_lens_state` ≥1；`[0]=B1`／`B2` | C/I/R；只確認模式，不證明已合焦、對焦距離或對焦點 |
| AUTO EV | `02/2E` → `10+n`，`n=-9…9`，每格1/3 EV；−3=`07`、0=`10`、+3=`19` | `cam_expo_param` ≥20；`[6]−10` 為 third-stops；只接受 `[6]=07…19` | C/I/R；需 `[7]=01` 的 Auto 基準 |
| 機內錄影壓縮 | **待驗證 candidate** `02/AB` → H.264 `00 00`、HEVC/H.265 `01 00` | `cam_video_param_v2` ≥9；compression=`[8]` | build25 developer writer要求完整9-byte fresh baseline、一次寫入、ACK＋寫後matching readback。2026-09-11首次HEVC→H.264提交無ACK且readback維持HEVC，因此尚不可稱為可寫控制。這不是USB HEVC。 |

真機驗證先使用 `Scripts/validate-video-compression.py`。預設target為目前HEVC，且只接受no-op：它需要ready USB capture、明確paired BLE session/peripheral與完整fresh property baseline，最後必須回`noOp=true`、`localSubmitted=false`、`end=noOp`。任何不同target均須額外傳`--allow-change`。

完整往返使用 `Scripts/validate-video-compression-roundtrip.py`：預設只做dry-run；只有明確的`--execute`才容許**一次**HEVC→H.264與**一次**H.264→原始HEVC回復。每次寫入必須有ACK和matching post-submission readback；第一個切換後還要獨立query到H.264才允許回復。若切換提交後發生逾時，驗證器只會再做一次唯讀query，僅在實際讀到H.264時才嘗試一次回復，絕不盲寫或重試。2026-09-11的第一次實機提交沒有ACK，所有後續與failure readback均保留HEVC，所以驗證器正確地沒有送回復命令；需找到Pocket 3 firmware對應的setter與完整handshake後才可再次測試。兩個驗證器都不匯出畫面、不操作Wi-Fi或雲台，也不把機內壓縮設定稱作USB codec。
| 曝光模式 | `02/1E` → Auto `01 00`、Manual `04 00` | `cam_expo_param[7]`=`01`／`04` | C/I/R；切 Manual 後快門／ISO 的原值仍需另核對 |
| 色彩模式 | `02/42` → Normal `00`、HLG `3C`、D-Log M `3D` | `cam_image_effect[2]` | C/I/R；設定回讀不等於 USB／預覽已驗證 HDR 或10-bit |

WB、EV 的邊界及 5600 K fixture 有明確 [encoder tests][settings-tests]。本專案應先在相機 idle、停止雲台輸入時逐项測試；這是縮小首輪變因的測試安排，不宣稱相機一律禁止錄影中調整這些值。

## 曝光進階項目：編碼已知不等於完整讀回

| 設定 | 精確已知編碼 | 尚缺／效果界線 |
|---|---|---|
| Manual ISO | `02/2A` 一 byte：Auto=`00`、50=`02`、100=`03`、200=`04`、400=`05`、800=`06`、1600=`07`、3200=`08`、6400=`09` | `01` 在已捕捉選單中未出現，不能自行補名；`cam_expo_param[16…19]` 是 u32 LE **有效 ISO**，不等於已選的 manual/auto ISO selector |
| ISO MAX | `02/8E` → `01 01 0F 00 01 XX`；100…6400 selector依序 `01…07` | 上游有 H 宣稱；但目前 readback model 沒有 ISO MAX 欄位，UI 明示 writer readback 尚未解碼 |
| Manual shutter | `02/28`，7 bytes。1秒=`01 01 00 00 00 00 40`；普通倒數 `1/d`=`01 LE16(8000 OR d) 00 00 00 40` | 完整 Photo 40項選單有 C/I；目前沒有已解碼 shutter readback，不能從未命名 exposure bytes 猜位置 |
| Pro master | `02/8E` → `01 01 00 00 01 XX`，off/on=`00/01` | setter孤立、C/I；沒有可直接當作 actual Pro state 的 named-property parser，不默認關閉也不自動開啟 |

ISO 表及40個快門選項均有 [Swift tests][settings-tests]；選項範圍與快門策略亦見 [camera policy][domain]。快門 fractional 分母有固定例外：1/1.25=`01 01 80 19 00 00 40`、1/1.67=`01 01 80 43 00 00 40`、1/2.5=`01 02 80 05 00 00 40`、1/6.25=`01 06 80 19 00 00 40`、1/12.5=`01 0C 80 05 00 00 40`。不能用四捨五入公式代替這些捕捉值。

`02/8E` 的已知 request schema 是 GET=`00 01 <pid:u16LE>`、SET=`01 01 <pid:u16LE> <length:u8> <value>`。知道 GET 的請求長相仍不足以推出回覆 value 的位置或 selected-state 語義；目前 ISO MAX／Pro 的完整回覆解析不在上述 public readback model 中。[keyed parameter 說明][settings-doc]

上游 normal Video 的最慢 shutter 選單限制為：24/25 fps→1/25；30→1/30；48/50→1/50；60→1/60。Photo 才使用完整1秒…1/8000選單；120/240 fps、Low-Light 或其他拍攝模式沒有被該 policy 泛化支援。[policy 與限制][domain]

## 錄影模式／格式不是 USB 擷取格式

`02/18` 控制**機身錄影格式**：`[resolution][fps][00][slow multiplier][00]`。它不等於 App 的 AVCapture 輸入 pixel format、USB COMMIT codec 或原生 Wi-Fi preview profile。尤其送9:16錄影尺寸不會替代機身直拍方向設定。[上游實測說明][settings-doc]

| 參數 | 固定版捕捉到的值 |
|---|---|
| Resolution | 1080p=`0A`、2.7K=`2D`、4K=`10`；1:1 1080/2160/3K=`69/6A/6B`；9:16 1080/2.7K/3K=`42/43/6C` |
| FPS | 24/25/30/48/50/60/120/240=`01/02/03/04/05/06/07/08` |
| Slow-motion multiplier | normal=`00`、4×=`04`、8×=`08` |
| Compression | `02/AB`：H.264=`00 00`、HEVC=`01 00` |
| Format readback | `cam_video_param_v2` ≥9；resolution `[0]`、fps `[1]`、compression `[8]` |
| 實際方向 readback | `cam_sensor_aspect_ratio[0]`：Landscape=`00`、Portrait=`01`；不是 Auto/Landscape/Portrait policy enum |

上述數值是編碼字典，**不能取所有 resolution×FPS×mode 的笛卡兒積**。已列出的模式樣本包括 Low-Light 的1080p／4K、24/25/30 fps；Slow Motion 的4K或2.7K 120 fps 4×、1080p 120 fps 4×或240 fps 8×。首輪應限制在已讀到並確認的當前模式，格式切換與 USB 同時取像的行為需另測。[mode observations][settings-doc]、[測試向量][settings-tests]

Shooting mode 的 `02/80[57]` 已解碼值為 Slow Motion `00`、Video `01`、Timelapse `02`、Photo `05`、Hyperlapse `0A`、Panorama `0C`、Motionlapse `18`、Low-Light `28`。`02/E1` 的 generic setter 確實存在，但文件特別限制 writer 證據：Timelapse `02` ↔ Motionlapse `18` 有獨立 capture／上游 H，其他 readback enum 不自動成為安全的任意 mode writer。[readback][readback]、[writer 證據界線][settings-doc]

## 機身錄影開始／停止

原生 `02/02` payload `01` 請求開始、`00` 請求停止；上游文件確認 response payload `00` 只表示接受請求。完成狀態須看新的 `02/80`：首 byte `01` idle、`41` transition、`C1` transition+recording、`81` recording；bit `80` 是 recording，bit `40` 是 transition。[錄影協定][protocol-recording]

我們應以 `recording bit == target` **且 transition bit 已清除**確認終態。上游 `recordRequestResolved` 遇 transition 會返回 true，那是解除 request-in-flight guard 的策略，不能搬來當錄影完成證據；上游程式亦保留獨立的 transition state。它使用2秒 command guard，這不是所有韌體的完成時間保證。[state policy][domain]、[實際 request pump][session]

啟動前需要當次 session 已知 recording state、沒有前一個 request／transition，並確認使用者選擇的是機身 SD 錄影。`02/80` ≥58 bytes 另提供：total/free storage MiB=`[5…8]/[9…12]` u32 LE、remaining seconds=`[17…18]` u16 LE、elapsed seconds=`[29…30]` u16 LE。單次 `02/01 01` 則是 Photo 觸發，不能混成錄影 toggle。[camera domain][domain]

## 屬性訂閱與解析契約

先在已就緒的原生 session 訂閱固定 allowlist。`00/99` receiver type `08`／id `1`，即 source `02`、destination `28`，flags `40`。Subscription payload：

```text
02 02 00 00 | transaction:u32LE | 00 00 00 |
(ASCII-name-length + 6):u16LE | ASCII-name-length:u16LE |
ASCII-name | 00 00 00 00
```

Push 的 payload `[0…3]` 必須為 `02 06 00 00`；transaction在 `[4…7]`；name length在 `[13…14]`；name從15開始；name後六個保留 bytes，接value length:u16LE與value。每個 offset／長度都要先做邊界檢查，名字只接受allowlist，其他欄位維持未解碼。[parser][readback]、[完整 subscription／push fixtures][readback-tests]

| Property | 最小 value bytes | 本次可採用的已解碼欄位 |
|---|---:|---|
| `cam_video_param_v2` | 9 | resolution[0]、fps[1]、compression[8] |
| `cam_sensor_aspect_ratio` | 1 | effective orientation[0] |
| `cam_image_effect` | 6 | color[2]、WB mode[4]、Kelvin/100[5] |
| `cam_expo_param` | 20 | EV[6]、exposure mode[7]、effective ISO:u32LE[16…19] |
| `cam_lens_state` | 1 | focus mode[0]，只認B1/B2 |
| `cam_photo_param` | 13 | frame[1]、format[3]、countdown seconds[7] |

Timelapse、Hyperlapse、Motionlapse、Panorama 的額外欄位存在於同一 decoder，但不屬於首批設定 UI。[Android readback 對照][android-readback]

每個 property 要獨立帶接收時間與 connection generation。收到未改變的有效值仍須更新 freshness；上游 session 只在 value change 時 publish，不能用那個 UI publish 時間取代接收時間。`hasCoreReadback` 只代表「曾收到至少一種 property」，不足以啟用全部設定。未知 enum 值、斷線或某 property 停止推送時，保留 unknown/stale，而不是沿用 `lastSent*` 當真實相機值。[session push handling][session]、[上游 UI fallback][screen]

## 尚未納入的項目

| 項目 | 本次來源能支持的結論 |
|---|---|
| Zoom | 新來源確認 `02/B8` 的 absolute slider、relative slew 與 stop，並以 lens state offset 14 顯示倍率；上限依機身格式為 4K 2×、2.7K 3×、1080p 4×。本專案現有 UVC `zoom-abs` 仍是另一條 transport，不能當作原生 zoom 驗證。[命令][opc-commands] |
| 對焦點／MF距離 | 新來源確認 Mimo 的四步 burst：`02/22` spot、`02/30` focus region、`02/68` AE hint、`02/32` AE region。現有 probe 已採四步，但 BLE 實測停在 Point 無 ACK；在 command-ready datalink 與橫／直幅座標校準完成前不開放。[命令][opc-commands] |
| Product Showcase | `02/8E` pid `003B` 已有 Default／Showcase／Lock／Priority 的公開 schema；仍缺本專案實機 selected-state 與寫入驗證。[命令][opc-commands] |
| Photo格式／倒數 | `02/12 00 01/03`（16:9/1:1）、`02/16 01/02`（JPEG/JPEG+RAW）、`02/4A 00 01 SS 00 00 00`（SS=00/03/05/07），有property readback；可在Photo模式的後續工作加入。 |
| 自動Motionlapse／Panorama | 有部分isolated commands及上游H，但會移動雲台或觸發拍攝；Preview沒有觀察到獨立stop command。不得混入本輪設定操作。 |
| Tracking | 新來源列出 `02/A6` box SET／clear、`02/A5` lock poll、`02/89` live subject box。先完成 off/on 被動差異與 typed parser，再做 box write；舊的 off baseline 不是 ActiveTrack 成功。[命令][opc-commands] |
| Gimbal shortcuts／params | `04/4C FE08` 是回中心、`FE09` 是 180°；`04/50` 提供 Follow／Tilt Locked 與速度 preset。它們是機身搖桿語義，不能再用慢速 UVC absolute movement 模擬。[命令][opc-commands] |
| Beauty／Wind Noise／Directional Audio | App Glamour 是 keyed blob；audio DSP 使用 `02/A0` GET 與 `02/9F` SET 同一 blob。實作必須保留所有未知 byte，只改已確認欄位，不能重播別次 session 的整塊 capture。[命令][opc-commands] |

原始範圍界線由 [settings API][settings]、[domain API][domain] 及 [刻意未公開項目][settings-doc] 交叉核對；2026-09-12 新增項目則以 [OpenPocketCine command catalog][opc-commands] 為協議證據，兩者都不取代本專案實機驗收。

## 原生配對後的首輪實機驗證安排

1. 只訂閱並保存上述核心property的型別化值與時間；確認切斷／重連會清除舊generation。先不寫設定。
2. 逐項以相機當前狀態作基準：WB 變一次100 K或Auto/5600 K、focus mode切一次、AUTO EV變一格。每次只送一個明確命令，不並行修改其他設定；讀回成功後僅恢復當次已知原值。
3. 記錄 requested、wire payload、transport result、新property value與機身/Mimo目視結果。Timeout、缺property或外部使用者改值時，結束該項，不能盲重送或覆蓋新狀態。
4. 這三項在本機成立後才接入使用者UI／MCP setter；錄影与格式切換另開驗收，不用設定ACK替代文件保存或畫面輸出驗證。

這些是待執行的有限步驟；本次研究沒有代使用者進行配對、變焦、曝光改動或錄影。

[settings-doc]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/docs/CAMERA_SETTINGS_PROTOCOL.md
[settings]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraSettings.swift
[readback]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraReadback.swift
[domain]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraDomain.swift
[settings-tests]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3ControllerTests/Pocket3CameraSettingsTests.swift
[readback-tests]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3ControllerTests/Pocket3CameraReadbackTests.swift
[vectors]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/protocol/test-vectors/camera/camera.json
[transport]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/DumlTransport.swift
[session]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3GimbalSession.swift
[screen]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/CameraControlScreen.swift
[android-settings]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/android/app/src/main/java/com/pocket3/gimbaltest/Pocket3CameraSettings.kt
[android-readback]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/android/app/src/main/java/com/pocket3/gimbaltest/Pocket3CameraReadback.kt
[protocol-recording]: https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/docs/POCKET3_DUML_PROTOCOL.md#8-camera-recording-and-0280-state
[opc-commands]: https://openpocketcine.app/docs/protocol/commands/
