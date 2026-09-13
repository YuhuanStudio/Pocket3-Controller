# DJI Pocket 3／4 開源參考專案與實作路線深度研究

## 研究結論

Pocket 3 的 USB 硬體並非只提供 4K30。本專案已保存的 configuration descriptor 明確包含一個 `H264`、`FORMAT_FRAME_BASED`、3840×2160 profile，離散 frame interval 為 `166666 / 200000 / 208333 / 333333 / 400000 / 416666`（100 ns 單位），對應約 60／50／48／30／25／24 fps。[本機 descriptor 證據](../../artifacts/usb-video-descriptors.json) 與 BELABOX、Orange Pi HDMI 專案及新近的 OBS direct-UVC plugin 相互吻合。此前把 4K50/60 長期描述成 Pocket 3 能力不確定，判斷過於保守；正確分類是 **frame-based H.264 profile 已由 descriptor 證明存在，但目前 macOS direct-UVC ownership 與 streaming backend 尚未完成**。[^1][^2][^3]

Orange Pi 專案能取得 4K50，因為它沒有走一般 webcam framework。其實際 pipeline 是 `libuvch264src → libuvc → H.264 elementary stream → h264parse → Rockchip MPP decode → KMS`；source 會枚舉 frame-based H.264/H.265 descriptor、呼叫 `uvc_get_stream_ctrl_format_size` 完成 UVC PROBE/COMMIT，再用 `uvc_start_streaming` 讀 endpoint。這與本專案目前主要使用 `AVCaptureVideoDataOutput` 的路徑不同。後者成功交付 Pocket 3 的 4K30 H.264 callback，但 4K50/60 profile沒有被穩定交付給 App。[^1][^2]

這項發現也證明先前的外部專案研究並不完整。Kaze-for-DJI 固定版本曾提供主要控制協議基線，但沒有完整覆蓋後來公開的 OpenPocketCine Pocket 3 實機調查、OBS direct-UVC 4K60 plugin、BELABOX 最新 H.265 fork、Pocket3Direct 系列、Osmosis 的媒體協議，以及 2026 年新增的多個 Pocket 4／4 Pro 專案。接下來不應再以「已看過 Kaze 與一個 Python 專案」代表完整 ecosystem research。

產品應採三條清楚分離的資料路徑：

1. **日常 USB 路徑**：AVFoundation 預覽與 UVC pan／tilt／zoom／roll，無需改 Mac 網路，維持目前可靠主流程。
2. **高幀率 direct-UVC 路徑**：專門取得 frame-based H.264 4K50/60；必須先解決 macOS 對整台 composite USB device 的 ownership，並具備完整 PROBE/COMMIT、bulk reader、NAL/AU assembler、VideoToolbox decode、audio/driver 恢復與 crash cleanup。
3. **完整 DJI 原生控制路徑**：BLE 只負責發現、pairing、唯讀 telemetry 與 Wi-Fi handoff；實機成功的雲台、tap focus、ActiveTrack、機身 writers 與媒體控制多數發生在 TCP 7001＋UDP 9004 的 command-ready session。首選不是讓 Mac 離開目前網路，而是以 OpenPocketCine 已在 Pocket 3 實測的 station-mode 流程，讓相機加入 Mac 現有 LAN；第二網路介面或 camera SoftAP 只作其他拓撲。[^4][^5][^6]

## 為何 Orange Pi 可用 4K50

### 它要求的不是官方一般 UVC 模式

DJI 官方 2024 年韌體說明只承諾 UVC 4K 25/30。這是一般 webcam application 可見、官方支援的範圍；它不否定裝置 descriptor 裡另有 frame-based H.264 50/60 profile。[^7] Orange Pi 專案的 README 也把輸入明確描述為 proprietary UVC H.264 mode，而非一般 MJPEG/YUV webcam output。[^1]

實際啟動指令只有一條，但關鍵在 source element：

```text
libuvch264src index=0
! video/x-h264,width=3840,height=2160,framerate=50/1
! h264parse
! mppvideodec
! kmssink
```

`libuvch264src` 並非 `v4l2src`。它內嵌 libuvc，直接打開 DJI VID/PID、枚舉 format descriptors、選擇 H.264 frame descriptor、取得 stream control 並開始 streaming。Orange Pi 端的 Rockchip MPP 只負責解碼與輸出，不是讓相機突然多出 4K50 的原因。[^1][^2]

### 本專案的 descriptor 已經證明同一 profile

本機 Pocket 3（VID `2CA3`、PID `0023`）的 interface 1 descriptor 包含：

| 欄位 | 本機值 |
| --- | --- |
| VideoStreaming interface | 1 |
| endpoint | bulk IN `0x82`, 512 bytes |
| format index | 2 |
| descriptor subtype | `FORMAT_FRAME_BASED` |
| FourCC/GUID | `H264` / `34363248-0000-0010-8000-00aa00389b71` |
| 4K frame index | 5 |
| dimensions | 3840×2160 |
| intervals | 166666, 200000, 208333, 333333, 400000, 416666 |
| advertised bitrate bounds | 111,974,400–223,948,800 bit/s |

因此 4K60 不是 UI 猜測，也不是從其他相機外推；它是這台實機的 USB descriptor fact。尚未證明的是 macOS process 能安全擁有 endpoint 並穩定交付、解碼 50/60 fps。

### Linux 與 macOS ownership 不同

Orange Pi 安裝流程加入 `usbcore.quirks=2ca3:0023:i`；Linux 文件定義 `i` 為 `USB_QUIRK_DEVICE_QUALIFIER`，只表示裝置不能正確處理 device-qualifier request，不是高幀率開關。[^8] Linux userspace 可在合適權限與 driver release 後由 libusb claim interface。

macOS 的 libusb FAQ 說明，若 kernel/system driver 已占有裝置，detach 更棘手，而且 macOS capture API 作用於**整台裝置而非單一 interface**。[^9] macOS 27 SDK 的 `IOUSBHostObjectInitOptionsDeviceCapture` header 也明載：需要 root，或 `com.apple.vm.device-access` entitlement 加 `IOServiceAuthorize()`；使用後會終止該 `IOUSBHostDevice` 及相關 interface 的所有其他 clients/drivers。銷毀 capture object 後裝置會 reset 並重新匹配 drivers。這意味著 direct 4K60 可能暫時中斷系統 webcam、audio、UVC control 與其他 App，不能在一般 Connect 中悄悄執行。

libusb Darwin backend也不是無成本捷徑：device open使用seize，kernel-driver detach落到whole-device capture/re-enumeration，restore/reclaim仍有已報告的resource/state問題。macOS正常產品路徑應先維持普通`USBInterfaceOpen` negative/positive gate；長期若需要與系統camera ownership正式協調，研究Apple的DriverKit＋CoreMediaIO UVC override／camera extension，而不是讓主App以root capture整台composite device。[^29][^30][^31]

## 四個最重要的參考實作

### `daijertech/obs-dji-uvc`

這是目前對本專案 4K60 最直接的參考。它針對 Pocket 3／4／4P，枚舉 frame-based H.264/H.265 descriptor，呼叫 libuvc PROBE/COMMIT 與 streaming callback，再做 Annex-B NAL/access-unit 組裝、bounded decode queue、等待 keyframe、FFmpeg hardware decode 與 NV12 output。README 宣稱 H.264 到 4K60，但同時誠實標示 linked plugin 仍需 Windows hardware bring-up；目前不應把其所有平台聲明視為已驗收。[^3]

可直接學習的設計：

- descriptor 必須以 `UVC_VS_FORMAT_FRAME_BASED` 加 GUID FourCC 辨識，不能把 host alias `2vuy` 當 direct wire format；
- device identity 優先用 serial，bus/address 只作 fallback；
- requested mode 必須在實際 descriptor 中精確匹配；
- NAL scanner 支援 start code 跨 callback 邊界；
- 在第一個 IDR 前丟棄非 key access unit；
- backpressure 落後時 flush 並等下一個 IDR，而不是無界堆積；
- capture、AU assembly、decode 與 presentation 分執行緒／queue；
- 4K60 的瓶頸更可能是 decode 與 memory movement，不是 encoded USB bandwidth。

不能直接複製的部分：repo 宣告 GPL-2.0-or-later 且是 Windows/OBS 導向；本專案需獨立實作 BSD libuvc-compatible transport ideas，並沿用現有 VideoToolbox decoder，避免把 GPL plugin source 納入目前產品授權。

### `BELABOX/gstlibuvch264src`

這是 Orange Pi pipeline 的真正 capture 核心。其 fork 在 libuvc format table 加入 H.264/H.265 GUID，GStreamer negotiation 會逐一枚舉 resolution/frame interval，接著呼叫 `uvc_get_stream_ctrl_format_size` 與 `uvc_start_streaming`。它也處理 SPS/PPS（H.265 再含 VPS）、IDR 前等待、timestamp jitter、平均 interval 與小幅 PTS stretch。[^2]

值得移植的是演算法與故障模型：

- UVC callback timestamps 不能直接當平滑 presentation clock；
- SPS/PPS/VPS 應在 parameter change 與第一個 IDR 前建立 decoder configuration；
- frame interval 要以實測緩慢校正，避免播放器大量 skip/duplicate；
- Pocket 3 4K60 曾觀察到約 75 ms offset，需 bounded resync；
- stop 必須停止 streaming、關 handle、unref device 與 exit context。

風險包括 GStreamer 1.24/1.26 compatibility、fork provenance、平台特定 patch，以及 repo 對 macOS whole-device capture 沒有產品解法。

### `OpenPocketCine`

OpenPocketCine 已成為目前控制面最完整、證據紀律最好的參考之一。它以 Apache-2.0 發布，shared Swift core 包含 BLE、SoftAP、DUML transport、HEVC/AVC live-view、camera controls、gimbal、tracking、media、session recovery、scopes 與跨 iOS/Android parity。其 2026-09-11 Pocket 3 survey 使用與本機相同的 firmware `01.06.10.04`，並區分 UI、accepted ACK、status、file 與 unverified evidence。[^4][^10]

對目前缺口最有價值的 capture-confirmed／hardware-correlated內容：

- `02/18` normal-video resolution/FPS，含橫幅、1:1、9:16 及 24/25/30/48/50/60；
- `02/24` AF-S=`01`、AF-C=`02`，並以 `cam_lens_state` B1/B2 corroborate；
- tap focus 四步 `02/22 → 02/30 → 02/68 → 02/32`，而 `02/32` 單獨會 timeout；
- `02/A6` tracking box／clear 與 `02/A5` state poll；
- `04/4C FE08` recenter、`FE09` front/selfie toggle；
- `04/01` stick notify，center 1024、約 ±550、10-byte payload；
- `04/14` timed absolute target 與 relative stop；
- `02/B8` zoom absolute、slew 與 stop；
- WB、EV、ISO、shutter、color、audio、Product Showcase、Glamour、photo/panorama/timelapse/motionlapse/hyperlapse 的 request/readback；
- media index、range download、playback、LUT、scope 與 reconnect patterns。

最重要的限制是：這些成功控制建立在完整 BLE→Wi-Fi→TCP/UDP command-ready session，不能直接證明相同 packet 在本專案 BLE-only writer 上會生效。它也明載目前 live view 主要實測 Pocket 4／4 Pro，Pocket 3 支援仍有分層狀態。因此應移植其 evidence 和 coordinator patterns，而不是把所有功能一次標成 verified。

### `Kaze-for-DJI`

Kaze（MIT）仍是重要參考，尤其是 Pocket 3 的 BLE→Wi-Fi handoff、TCP 7001 bootstrap、UDP 9004 transport header、sequence/ACK windows、pktType media、gimbal session、camera settings、iOS/Android parity 與 exact fixtures。其文件明確區分 physically confirmed、capture confirmed、source confirmed、corroborated、observed 與 unverified。[^5]

本專案目前只固定引用 Kaze commit `341a35de…` 的協議證據與 license，沒有 vendoring 完整 source tree。此前多數 typed command 已依該版本建立，但「有 encoder」不等於「本機 BLE 路徑成功」。OpenPocketCine 更新的 Pocket 3 survey 現在補上許多 Kaze 文件之後的 isolated ACK/status/file evidence，兩者需要一起對照。

## 其他高價值專案 inventory

| 專案 | 已檢查範圍 | 可學習內容 | 限制／採用判斷 |
| --- | --- | --- | --- |
| `stephanebhiri/DJI_OSMOPOCKET3_TO_HDMI_4K_60P_50P` | README、install、working config、pipeline | Pocket 3 4K50 實機結果、BELABOX dependency、Rockchip/KMS latency | Orange Pi/Linux 專用；capture 核心在 BELABOX，不應只抄 shell script。[^1] |
| `brianmerchant/Pocket3Direct-iOS` | README、session/control/video structure | Pocket 3 TCP7001＋UDP9004、H.264 live preview、record、gimbal、external display | 需要 iOS 加入 camera Wi-Fi；是 reference app，不是 macOS/USB 解法。[^11] |
| `brianmerchant/Pocket3Direct-Android` | README、transport/gimbal scope | 04/01 continuous stick、±550、FE08、explicit neutral、ACK window | 同樣需要 camera Wi-Fi；適合驗證控制 pump 與 stop semantics。[^12] |
| `KonradIT/osmosis` | README、media protocol、model matrix | Pocket 3/4/4P 媒體 index、range、resume、favorite/delete、DNG、GPS | Android/Wi-Fi media client；不能用於 USB high-fps。[^13] |
| `yigitkonur/lib-osmo-ble` | README、protocol | FFF4/FFF5、pairing、CRC、telemetry、五類 gimbal packet | 作者也觀察到 BLE-only motor command 被 Pocket 3 忽略；支持本專案目前結論。[^14] |
| `triwav/dji-osmo-ble-protocol` | protocol reference | macOS BLE pairing/RTMP flow、writeWithoutResponse、session bugs | RTMP 導向；部分說法與較新项目重疊，需追到 capture/provenance。[^15] |
| `sniffingpickles/DJI-Wifi-Connect` | README、Python module map | macOS UDP9004、720p60 live view、PTZ、web UI | 會用 `networksetup` 切 Mac Wi-Fi，直接違反本產品網路要求；只取協議，不取 join 策略。[^6] |
| `Evan931001/Pocket-3-PTZ` | README、Windows UVC tools | 單 USB 的 UVC pan/tilt/zoom、OBS coexistence、remembered home | Windows DirectShow；已確認 BLE motor control不可用。與本專案 USB 主路徑一致。[^16] |
| `Blablablar/Pocket3HeadTrack` | README、Swift files | AirPods head pose→UDP 04/01、dead zone/expo/neutral | 需要 iPhone Wi-Fi session；BLE wake仍標實驗。[^17] |
| `ElectronicPaper/OsmoDesk` | README、driver/tests | browser operator、motion planning、repeatability、separate camera/LAN interfaces | 開發機為 Pocket 4P，Pocket 3 未測；原創 code 尚無 blanket license。不能直接納入。[^18] |
| `ElectronicPaper/OsmoPalm` | README、contracts | standalone controller、saved paths、emergency stop、easing | Pocket 3 未測；private R&D snapshot，license 不清楚。[^19] |
| `xaionaro-go/djictl` / `reverse-engineering-dji` | README、Go command surface | BLE/RTMP、DUML dissector與原始逆向 lineage | 多個 command 在 README 明示尚不可用；只採用已驗 fixtures。[^20] |
| `intermittech/OsmoOffload` | README、scripts、lineage | Windows 桌面媒體下載、resume、hash verification、Ethernet保留internet | Pocket 4 Pro實測，Pocket 3只是協議相容候選；適合產品級offload UX，不是控制／影像transport證據。[^23] |
| `Kimsec/belabox-pocket4-rtmp-hevc` | README、FLV patch、install/rollback tests | Pocket 4 RTMP HEVC legacy codec-id 12、可回滾旁載GStreamer plugin | 實測只有1080p30 HEVC Main 8-bit；與Pocket 3 USB H.264是不同路徑。[^24] |
| `dji-sdk/Osmo-GPS-Controller-Demo` | 官方README、protocol/data layers | DJI官方R SDK framing、BLE command type、status/GPS push、descriptor-driven parser | 官方硬體列表是Action/360，不含Pocket；可學框架，不能把命令相容性外推到Pocket 3。[^25] |
| `Yjsmall/OpenPocketCine` macOS shell | README、macOS package/source layout | 原生macOS operator shell、沿用OpenPocketCine shared core | personal fork commit較舊，須逐項與upstream main比較；不能取代本專案UI/網路限制。[^26] |
| `datagutt/node-osmo` / `dimadesu/dji-remote` | lineage/reference | BLE framing、camera remote payloads | 存在歷史 byte order、buffer offset、wrong characteristic 等 bug；需使用後續修正版。 |
| `intermittech/OsmoOffload` | discovery inventory | Windows desktop media offload | 待深入 source/license；只列候選，不作能力依據。 |
| `Yjsmall/OpenPocketCine` macOS shell | discovery inventory | 原生 macOS operator shell 的可能 UI/transport做法 | 尚未 source audit，不可直接採用。 |
| `daijertech/obs-dji-uvc` | source-level | encoded UVC 4K60 | 本輪最高優先 transport reference。[^3] |

GitHub 搜尋也出現多個 2026 年新 repo（Pocket 4 RTMP HEVC、OsmoDesk/Palm、OsmoOffload、Pocket3HeadTrack、macOS OpenPocketCine shell）。它們的星數與 README 不是可信度代理；後續只在 source、license、hardware identity、firmware、raw evidence 和 negative cases 同時可核對時提升證據等級。

補充 source audit 後，`node-osmo@cec92ae` 仍把 FFF3 當 command write characteristic，且 README 對 BLE 穩定性保留限制；Pocket 3 現行實測應使用 FFF5 write-without-response與FFF4 notify，因此它只能作歷史RTMP/DUML候選。`dji-remote@c2012be` 的硬體確認範圍是 Action 4；Pocket 3/4 model enum與Pocket 4 HEVC JSON只屬source/packet candidate。兩者都是MIT，但不能用來提升本機writer或Pocket 4 capability。[^27][^28]

OsmoDesk／OsmoPalm 的安全架構（single UDP owner、stale telemetry、neutral/STOP、abort與部署rollback）值得學習；其開發相機是Pocket 4 Pro，Pocket 3／4未測，且兩個repo的原創碼沒有清楚的blanket license，故不可直接複製camera常數或實作。Pocket3Direct iOS/Android雖提供清楚的04/01、neutral、FE08與TCP7001/UDP9004程式，但公開provenance主要是simulator/offline tests，應視為協議實作參考，不代替本專案真機驗收。

## 與目前實作的差距

### USB encoded UVC

已具備：

- 完整 configuration descriptor parser；
- frame-based H.264 4K60/50/48/30/25/24 的本機證據；
- AVFoundation H.264 callback 與 async VideoToolbox 4K30 decode；
- Annex-B／AVCC／HVCC、H.264／HEVC parameter-set 與 bounded decoder；
- direct interface inventory、normal-open ownership觀測與 AVFoundation↔direct lifecycle policy。

仍缺：

- 可取得 VS interface 的產品級 macOS ownership方法；
- direct UVC stream-control block parser/serializer與 GET_CUR/MIN/MAX／SET_CUR PROBE/COMMIT；
- bulk `0x82` async transfer ring；
- UVC payload header/FID/EOF/error parsing；
- Annex-B payload→access-unit與 loss→wait-IDR 串接；
- direct encoded frame clock與 fps/drop/backpressure metrics；
- VideoToolbox decode→FrameStore／SwiftUI preview；
- composite audio/control restore、拔插、睡眠與 crash recovery；
- 明確 UI 告知 direct mode 會暫時獨占整台相機。

### HEVC 主機輸出

現況有兩條被錯誤混名的路：

- UI `CaptureOutputPolicy.hevc` 要求 AVFoundation 直接交付 HEVC；Pocket 3 該 host path 未 advertise `hvc1`，所以使用者無法連線。
- developer `HostHEVCProductOutputService` 從 BGRA/NV12 經 VideoToolbox 產生 hvc1，已驗證 samples/hash/cleanup，但 sink 尚未成為檔案、虛擬攝影機或 streaming consumer。

正確修正是讓 UI 選 HEVC 時仍建立可靠 BGRA/NV12 capture，再顯式啟動 VideoToolbox HEVC lifecycle；status 必須用 product service phase/sample/fps/error，而不是 AVFoundation advertised codec。若暫時只做編碼工作階段，UI 必須如此命名，不能宣稱已能錄製或串流。

### 原生完整控制

本專案已建立大量 typed encoder/coordinator，但 hardware writer 結果落後於 OpenPocketCine/Kaze，主因是 transport：BLE pairing 與 telemetry 成功不等於 UDP command-ready。下列能力應改以「相機與Mac之間有已驗證、身份綁定且不破壞default internet route的LAN路徑」為執行前提：

- 04/01 continuous gimbal stick、04/14 target、FE08/FE09；
- tap focus 四步；
- A5/A6 ActiveTrack set/clear；
- WB、focus、color、exposure、format、record、audio、timelapse等 writers；
- media index/range/playback。

如果 Mac 只有一張正在上網的 Wi-Fi radio，產品不應自動加入 Pocket SoftAP。OpenPocketCine 2026-09-09後的 station-mode 實驗提供更好的首選：

1. BLE pairing後送 `07/39 00` 查work mode；Pocket 3已實測回`E0`，因此只能走嚴格的model-specific missing-getter分支；
2. 送 `07/48 01` 切STA；Pocket 3實測回`00`；
3. 等候有界settle後送`07/47`加長度前綴的現有LAN SSID/password；Pocket 3實測回`00 00`；
4. BLE可斷開，Mac保持原Wi-Fi；在LAN上發現相機DHCP地址，TCP7001＋UDP9004握手；
5. 用LAN `07/07`回覆精確比對先前BLE identity，不能只憑IP或join ACK認相機；
6. 離開時送`07/48 00`恢復camera AP，失敗則保存cleanup debt並在下次重試。

OsmoOffload另記錄Pocket 3在BLE Wi-Fi wake `53/10`回`E0`時可繼續流程；這只能成為Pocket 3 model-specific non-fatal diagnostic，不能泛化成所有錯誤都忽略。其FFF4 arm、FFF5 no-response與約100 ms pacing可作BLE transport參考。[^23]

OpenPocketCine後續三相機iPhone實測同時取得Pocket 4 Pro、Pocket 3與Nano預覽並確認錄影start/stop；Pocket 3 app-switch recovery曾需完整rejoin約一分鐘。這證明station控制路徑存在，不等於長時間穩定或AP restore已完整驗收。產品可接受拓撲依序是：

1. **相機加入現有LAN（首選）**：Mac完全不換網路；需一次明確輸入/授權LAN密碼及可靠AP restoration。
2. Ethernet/Thunderbolt 保持default internet route，Wi-Fi專供Pocket SoftAP。
3. 額外USB Wi-Fi adapter綁camera subnet。
4. 另一台iPhone／Pi作camera-side bridge，再由LAN連Mac。
5. 所有安全拓撲都不成立時，只保留USB UVC控制。

## 實作優先順序

### P0：修正錯誤能力宣告

- 將 4K60 從「UYVY profile」改為 `H264 FORMAT_FRAME_BASED direct-UVC candidate`。
- 將 HEVC UI 分成 `AVFoundation device output` 與 `VideoToolbox host encode session`；不再用後者的 digest 測試宣稱前者可用。
- Capability graph 分開 descriptor-present、owner-acquired、probe-committed、payload-received、AU-assembled、decoded、presented。

### P1：direct-UVC macOS spike

- 先做完全唯讀的 descriptor→mode selection與 34-byte UVC 1.0 stream-control codec。
- 在不 capture device 的條件下保留 normal-open negative test。
- 只有普通normal-open持續無法取得ownership時，才另建隔離的privileged research helper；使用IOUSBHost DeviceCapture前必須顯示「會中止所有相機clients/audio」，且不得成為一般Connect的隱藏行為。
- UVC 1.0候選使用26-byte stream control，下一個獨立gate依序為`GET_MAX PROBE (a1/83/0100/0001/26) → SET_CUR PROBE (21/01/0100/0001/26) → GET_CUR PROBE (a1/81/0100/0001/26) → SET_CUR COMMIT (21/01/0200/0001/26)`；每步精確核對format=2、frame=5、interval，不把ACK當stream ready。
- bulk reader使用少量有界async buffers、generation/cancel/completion-drain；解析UVC header/FID/EOF/PTS/SCR，再交給既有Annex-B/AU/IDR-gated VideoToolbox pipeline。queue落後時丟到下一個keyframe。
- 先以 1080p30 direct H.264 驗證 header/AU/decode，再升 4K30、4K50、4K60；每階段保存 scalar/hash，不保存畫面。
- 若 DeviceCapture 無法在可發布簽署／權限模型下可靠恢復，將 4K50/60標成 macOS system limitation，提供 Linux/Orange Pi companion選項，而非反覆盲試。
- 長期產品化評估DriverKit＋CoreMediaIO extension override，讓安裝、簽章、system camera ownership與恢復由正式extension生命週期承擔。

### P1：route-safe native session

- 優先實作Pocket 3 station provisioning：`07/39(E0 narrow fallback) → 07/48 01 → bounded settle → 07/47`，只接受已捕捉的reply shapes。
- 增加 network topology UI：primary internet interface、station camera address、identity match、default-route preservation與AP restoration debt。
- Station discovery後必須用LAN `07/07`精確比對BLE identity，再開TCP7001/UDP9004；未知LAN peer不得取得writer。
- SoftAP/第二介面模式的每個 socket仍用 `IP_BOUND_IF` 綁 camera interface。
- 依 OpenPocketCine/Kaze session spine完成 TCP7001、UDP9004 registration/keepalive/ACK windows。
- 先重驗 FE08/FE09、04/01 neutral、focus 02/24，再逐步開 tap focus、settings與ActiveTrack。

### P2：控制與媒體完整性

- 依相同 firmware 的 OpenPocketCine survey補齊 normal／Low-Light／SlowMo／portrait／square格式矩陣。
- 每個 writer都要 baseline→single write→ACK→matching status/readback→restore；accepted ACK不等於物理效果。
- ActiveTrack以 A5 locked/idle、A89 box及 A6 target readback驗證，不用事件頻率當狀態。
- 媒體採 Osmosis/OpenPocketCine 的 bounded page/range/resume patterns，delete/favorite另設更高權限。

### P3：AI 主線

當 P0 與 P1 的 transport 結論凍結後，AI 可主要建立在兩個穩定輸入：日常 AVFoundation 最高 4K30，以及可行時的 direct H.264 4K50/60。AI director、VLM、tracking與 framing不應等待每個冷門機身 menu writer；只需 camera frame、可靠 stop、session fence、zoom/pan/tilt與可選 native ActiveTrack達到既定 acceptance。

## 完成判準

「Pocket 3 支援完成，可以把主要人力轉向 AI」不等於所有 private opcode 都破解。需要以下可核對狀態：

- 每個官方主要功能都有 `verified / protocol-known-but-transport-blocked / unsupported-no-protocol / out-of-scope` 之一；沒有模糊的「可能可用」。
- USB 取像主流程覆蓋橫／直、H.264、BGRA/NV12、stop/reconnect；4K50/60 direct path得到成功或明確macOS ownership終局。
- pan/tilt/zoom/roll完成壓力、停止、恢復、拔插與遠端無螢幕驗收。
- FE08/FE09、tap focus、ActiveTrack與主要 settings 在 command-ready UDP session驗證，或證明無第二介面時不可用。
- 所有 UI capability 文字與實際 backend一致；developer digest、descriptor或 ACK 不再冒稱產品可用。
- 外部專案 inventory保留 commit、license、hardware/firmware與採用判斷，季度更新。

## Sources

[^1]: Stéphane Bhiri, “[DJI Osmo Pocket 3 → HDMI 4K Streaming](https://github.com/stephanebhiri/DJI_OSMOPOCKET3_TO_HDMI_4K_60P_50P/tree/ad95e289eb0b2be49b340009b103a0a6c2dbbdac),” commit `ad95e289`, 2026.
[^2]: BELABOX, “[gstlibuvch264src](https://github.com/BELABOX/gstlibuvch264src/tree/1644b6d1876ffb4e0da60f1410db9f4d54c80307),” commit `1644b6d`, accessed 2026-09-13.
[^3]: daijertech, “[obs-dji-uvc](https://github.com/daijertech/obs-dji-uvc/tree/504452d84d5cc33e2542753cb474982d9919a9ca),” commit `504452d`, 2026.
[^4]: Erik Sutton et al., “[OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine/tree/9b30b93572797c94db5ad9236fb746410f8d761f),” commit `9b30b93`, 2026.
[^5]: Brian Merchant, “[Kaze-for-DJI](https://github.com/brianmerchant/Kaze-for-DJI/tree/341a35de18493ff61f97c93b8b10161a7512aa36),” commit `341a35d`, 2026.
[^6]: sniffingpickles, “[DJI-Wifi-Connect](https://github.com/sniffingpickles/DJI-Wifi-Connect),” accessed 2026-09-13.
[^7]: DJI, “[Osmo Pocket 3 Release Notes — v01.04.08.02](https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20241126/DJI_Osmo_Pocket_3_Release_Notes_en.pdf),” 2024-05-15.
[^8]: Linux Kernel, “[The kernel’s command-line parameters — usbcore.quirks](https://docs.kernel.org/admin-guide/kernel-parameters.html),” accessed 2026-09-13.
[^9]: libusb project, “[FAQ — running libusb under macOS with an existing kernel driver](https://github.com/libusb/libusb/wiki/FAQ),” accessed 2026-09-13.
[^10]: OpenPocketCine, “[Pocket 3 reference](https://openpocketcine.app/docs/protocol/pocket3/),” 2026-09-11 survey, accessed 2026-09-13.
[^11]: Brian Merchant, “[Pocket3Direct-iOS](https://github.com/brianmerchant/Pocket3Direct-iOS/tree/da51f53d98c0c3723dc60371e10bfc9042071532),” commit `da51f53`, 2026.
[^12]: Brian Merchant, “[Pocket3Direct-Android](https://github.com/brianmerchant/Pocket3Direct-Android/tree/f30c3642c8d8e430cd9d19cf182aa064929c6b1b),” commit `f30c364`, 2026.
[^13]: Konrad Iturbe, “[Osmosis](https://github.com/KonradIT/osmosis/tree/2fcdbc97e6dbefc875d425368be67cf32b50bb06),” commit `2fcdbc9`, 2026.
[^14]: yigitkonur, “[lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble),” accessed 2026-09-13.
[^15]: triwav, “[dji-osmo-ble-protocol](https://github.com/triwav/dji-osmo-ble-protocol),” accessed 2026-09-13.
[^16]: Evan931001, “[Pocket-3-PTZ](https://github.com/Evan931001/Pocket-3-PTZ/tree/0ac7295b616844356d9566d5c411bdfe930adeb7),” commit `0ac7295`, 2026.
[^17]: Blablablar, “[Pocket3HeadTrack](https://github.com/Blablablar/Pocket3HeadTrack/tree/73ecee5f598f04806e62f32e0f9fc5d8ba7c0806),” commit `73ecee5`, 2026.
[^18]: ElectronicPaper, “[OsmoDesk](https://github.com/ElectronicPaper/OsmoDesk/tree/2a8c4e0da622daad14ba916008b6bedf39e26dac),” commit `2a8c4e0`, 2026.
[^19]: ElectronicPaper, “[OsmoPalm](https://github.com/ElectronicPaper/OsmoPalm/tree/f37b7da625dd196090b54fe24a8edbbd98df37d9),” commit `f37b7da`, 2026.
[^20]: xaionaro-go, “[djictl](https://github.com/xaionaro-go/djictl/tree/ddeced5422fe3a27075602d41b49e61ca60c99d8),” commit `ddeced5`, 2026.
[^21]: DJI, “[Osmo Pocket 3 specifications](https://www.dji.com/osmo-pocket-3/specs),” accessed 2026-09-13.
[^22]: libusb project, “[Is it possible to claim interfaces on macOS while using kernel extensions for other interfaces?](https://github.com/libusb/libusb/issues/920),” 2021.
[^23]: intermittech, “[OsmoOffload](https://github.com/intermittech/OsmoOffload/tree/9c5bad9cadcc3fecd402a4bddef7a52d8b2ad54f),” commit `9c5bad9`, 2026.
[^24]: Kimsec, “[belabox-pocket4-rtmp-hevc](https://github.com/Kimsec/belabox-pocket4-rtmp-hevc/tree/2c99a0760b8f3124a294b9b98a6dca974b0baf26),” commit `2c99a07`, 2026.
[^25]: DJI SDK, “[Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo/tree/92fe23e5a749f189593f980a26a105c3bb66aa1c),” commit `92fe23e`, 2025.
[^26]: Yjsmall, “[OpenPocketCine macOS operator shell](https://github.com/Yjsmall/OpenPocketCine/tree/2bb7e0f4ae8b3dd9289f6c606f97c6d6b0e52a34),” commit `2bb7e0f`, 2026.
[^27]: datagutt, “[node-osmo](https://github.com/datagutt/node-osmo/tree/cec92aec9304a5cc3dae7f7de541eef38ebb680e),” commit `cec92ae`, 2026.
[^28]: dimadesu, “[dji-remote](https://github.com/dimadesu/dji-remote/tree/c2012be6aca67d4882774cf5d9746f420a03e11f),” commit `c2012be`, 2026.
[^29]: libusb project, “[Darwin backend — claim, capture and restore](https://github.com/libusb/libusb/blob/a45bb163a603ac5ae3499806b151509848b0065c/libusb/os/darwin_usb.c),” commit `a45bb16`, accessed 2026-09-13.
[^30]: libuvc project, “[stream control and bulk transfer lifecycle](https://github.com/libuvc/libuvc/blob/4e9fc773914377ec0bcf2f31621f56da5a0fa09f/src/stream.c),” commit `4e9fc77`, accessed 2026-09-13.
[^31]: Apple, “[Overriding the default USB Video Class extension](https://developer.apple.com/documentation/coremediaio/overriding-the-default-usb-video-class-extension),” accessed 2026-09-13.
