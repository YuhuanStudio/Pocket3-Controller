# Pocket 3 實機驗收

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

2026-09-08 使用者已恢復 Pocket 3，實機驗收正在進行。韌體由使用者在機身確認：主韌體 `01.06.10.04`、相機 `10.00.50.51`、雲台 `01.00.15.81`。

**2026-09-09更新：** 公開beta1為build9；後續build11新增Zoom途中Stop讀回成功及BLE lens連續觀察，詳細條件見本文件末段。第一輪機身點按有轉向干擾，第二輪操作順序仍待確認，兩者均不當作完整AF或座標校準。下方較早日期的失敗、測試範圍與限制保留，不是目前功能清單。

**本輪build13–15補記：** MLX已完成一條真機縮放／新影格任務；Apple的三次任務未完成所要求調整，WB在pair-only及完整配對下仍未生效。完整配對／保留Mac網路及解鎖後手動USB操作已有證據；最新FE08因基線不足而沒有送出。本段記錄時installed build15、candidate build16編譯／測試中；新的混合AI流程與native-preset heartbeat修正尚無實機通過結果。

公開Beta feed已完成Keychain簽署與發布，公開下載的feed／ZIP經本專案Ed25519公鑰驗證通過；真正跨版本更新安裝及重啟仍待驗收。[公開簽章結果](../artifacts/public-beta1/public-signature-verification.json)。此為發布證據，不是相機控制證據。

## 30 分鐘影音

先由操作者啟動開發工作階段，接上相機並在 App 連接：

```sh
open 'dist/Pocket 3 Controller.app' --args --hardware-validation
python3 Scripts/validate-stream.py --seconds 1800 --audio
```

執行器不會自行連接或選擇相機。`--audio` 會啟用所選 Pocket 3 的音訊並可能要求麥克風權限。App 顯示串流驗證中，普通動作會被拒絕；「停止操作」、隱私暫停或退出會取消驗證。

每秒記錄實際 frame count、近期 FPS、影格年齡、尺寸、音訊 frame count／格式與程序 RSS。檢查來源 session 不变、尺寸不变、影格小於一秒、暖機後近期 FPS 不低於 24、影音持續前進，以及音訊為雙聲道 48 kHz。結束後關閉測試音訊；未確認清理也會記為失敗。

只記錄數值，不保存影音。結果寫入指定輸出目錄與 App 專用資料夾。短測即使通過也不能當作完整 30 分鐘影音驗收；RSS 增長與系統中斷必須另行檢視，通過串流數值條件不等於整體產品已驗收。

## 控制與恢復

在 App 診斷頁執行控制驗證，檢查版本 4 報告與當次 USB attachment／開機身分。每軸 20 次小幅往返、中途保持、最終還原都必須通過。

另外重測：1080p30／4K30、先前的方向／黑邊問題、視窗縮放、停止競爭、拔插、隱私暫停、睡眠／喚醒，最後用真實相機跑 App AI 和 MCP「先看→動作→新影格→回答」。實際韌體版本與所有失敗也要記錄。

## 2026-09-08 本輪發現

- 1080p30／4K30 原始 JPEG 尺寸與方向正常；4K 15 秒短測最低近期 FPS 28.69。不是 30 分鐘驗收。
- 12 秒音訊短測取得 stereo 48 kHz PCM；目前音訊設定改為 commit 完成、實際影音 buffer 到達後才回報成功。報告另列 `configurationSeconds`，啟動時間不能算進 30 分鐘。
- 第一筆長測 `AFC796F6-A9C9-48ED-A77F-53325290C922` 啟用音訊後曾停住約 82 秒，判為失敗並取消；證據保留，不覆盖為成功。
- 原 v3 的 80 個位置目標成功，但停止曾有 residual 1800，原本「每軸至少一筆通過」會掩蓋該失敗，故整份不接受。發現 upstream parser 將 GET_RES=3600 套用到原始保持位置；修正後待 v4 實測。
- v4 必須 80 個位置、24 筆保持及每次還原均穩定；每軸三組都要有朝目標前進且在該軸目標前中斷的證據。保持容差仍為 1080，不放寬。
- UVCConnection 綁定當次 attachment／boot；每次寫入前在 C 邊界再確認 registry ID，避免同埠快速重插沿用旧權限。普通手動方向也需控制驗證。
- 解鎖桌面的 UI 動畫、視窗／popover 生命週期及既有版面尺寸檢查已通過。

如果機身回讀超出 USB 宣告範圍，先由使用者將雲台回中，再取新基準；不從範圍外位置發送還原命令。DJI 說明的回中方式為按兩下 5D 搖桿：[官方說明](https://repair.dji.com/help/content?customId=01700006553&lang=en&paperDocType=ARTICLE&re=US&spaceId=17)。

## 真實直幅已確認

使用者將機身切為直拍後，1080×1920 影格不再有上下黑邊。五種直幅模式均已實測並逐張查看 JPEG：720×1280@25/30、1080×1920@24/25/30，穩態中位 FPS 分別25.005／29.972／23.976／24.990／29.959。證據 `artifacts/hardware-resumed/portrait-matrix/47249823-ced5-4be7-954e-cce4aa2113d6/result.json`。

第一輪全格式矩陣只暖機4秒，而 FPS 視窗最多保留150影格，仍混入啟動時序，造成多項過早判失敗；改為10秒暖機後直幅均正常。第一輪判定與黑邊影格保留，不能用它把原本可用模式列為不支援。機身保持橫拍、App 選直幅時的完整尺寸仍可能包含黑邊，因此格式尺寸與影像內容必須分別驗證。App 已加入機身方向需匹配格式的指引。

## 控制與輸入格式的後續隔離

- 固定憑證後再次重建，連接在0.134秒內回到authorized/ready，沒有為該次重連再要求使用者授權。簽署DR跨不同binary也已交叉驗證。
- UVC interface取得/借用狀態的原始程式有所有權判斷反向與未依文件自動關閉問題，已修正並以14項fake-interface/ASan測試驗證；未因此宣稱已解決所有實機控制問題。
- 活躍1080×1920@30 NV12下，App及獨立C單次+3600 tilt都被忽略；負方向-3600及返回0可成功。正在釐清機身姿態/模式及實際範圍，不以傳輸成功當作動作成功。
- NV12與UYVY已分開為使用者可選輸入格式。實際USB descriptor列的是MJPEG與H.264，沒有未壓縮NV12/UYVY wire format。GET_CUR COMMIT已確認NV12直幅30fps實際選format1/frame4/MJPEG；第二組查詢已確認 UYVY 直幅 30 fps 對應 format2/frame4/H.264（見下方）。4K高幀率宣告來自H.264，不能用未壓縮頻寬排除。
- OBS使用期間曾使App影格停止；App現加入stalled狀態與幀率歸零，並禁止以過期畫面發動新的移動。已請使用者停用OBS來源作隔離測試，使用者回覆已關閉。


## 2026-09-08：直幅 30 分鐘影音長測完成

報告 `artifacts/hardware-resumed/stream-final/EC740B6A-ECD5-4C48-89B1-8A797CF2D936/report.json`：1080×1920、NV12、30 fps，雙聲道 48 kHz，實際 1800.207 秒、1766 個樣本，無失敗條件。中位 FPS 29.9717，最低 29.7459，最大影格年齡 0.3285 秒，最大取樣間隔 1.0677 秒。音訊共 86,415,872 sample frames。長測未保存影像或聲音。

RSS 起點 256.61 MiB、終點 147.17 MiB，暖機後淨減 66.91 MiB，本次軌跡未見持續增長；這是本次長測結果，不是任何工作負載都沒有洩漏的證明。結束後仍有新影格，音訊計數停止增加，已完成關閉音訊清理。此證據限目前韌體、直幅 NV12 30 fps 與當次 USB 連接，不延伸宣稱 4K／UYVY、原生無線或雲台驗收完成。


## UYVY／H.264 輸出隔離實驗

`artifacts/hardware-resumed/uyvy-diagnostics.json` 在明確選擇 1080×1920@30 UYVY 時，以純 GET_CUR 讀到 COMMIT formatIndex=2、frameIndex=4、interval=333333，即 H.264。預設 BGRA 輸出下，AVFoundation 的 video sample、pixel buffer、非影像 sample／block buffer 四種計數均為 0，沒有 runtime error 或 interruption 通知。

依 SDK 對 `AVCaptureVideoDataOutput.videoSettings` 的說明，限定開發啟動環境改用空 dictionary 的 native output 做第二次對照；`artifacts/hardware-resumed/uyvy-native-output.json` 仍然四種回呼計數皆為 0。選定 activeFormat 後列出的可用輸出包含 2vuy、yuvs、420v、420f、ARGB、BGRA，codec 包含 avc1、jpeg。因此不能把失敗直接歸因於 BGRA 不在輸出清單，也沒有證據說我們丟棄了已送到 App 的 H.264 sample；本輪不加入無依據的 VideoToolbox 解碼器。

測試後已退出實驗 process，解除 native-output 環境重新啟動，再回到 NV12／BGRA；影格正常、outputPolicy=bgra。結論僅涵蓋當次 4 秒啟動觀察窗口、目前韌體及當次模式，未宣稱其他尺寸或所有 UYVY 不可用。還需要核對 OBS 是否真正收到該格式的畫面，而非只有選单列出格式，以及較長啟動時間／機身方向對此路徑的影響。

最新 AppKit 畫面看到直幅影格內含上下黑邊；原始影像未被裁切。這次機身拍攝方向尚未重新確認，不能把之前五種直幅的內容驗收延伸為本次已核對。

2026-09-11新增不保存像素的edge metrics後，1080×1920 NV12/BGRA的top/bottom dark fraction均為1.0、left/right為0.683（每邊1,080個抽樣像素），因此黑邊訊號已可量化。這只描述邊緣亮度，不能判定內容方向、場景、構圖或機身姿態是否正確。

2026-09-08 延長啟動測試：`artifacts/hardware-resumed/uyvy-startup-20s.json` 中，1080×1920@30 UYVY／BGRA 等待 20.289 秒仍零影格回呼，無 runtime error／interruption；COMMIT 仍是 format2/frame4/H.264，測後 NV12 恢復。此結果排除了只依原本 4 秒觀察窗口作結論，但未證明所有模式的 H.264 都不支援。固定 OBS 來源 cb9b4f119ab4464f87f35a0f30b5f92887a40f86 的 legacy path 使用 `videoSettings=nil` 的系統預設未壓縮輸出，與空 dictionary 的 native output 不同，下一組有界對照將分別記錄。

系統預設輸出對照也已完成：`artifacts/hardware-resumed/uyvy-system-output-20s.json` 中使用 videoSettings=nil 的 system_default policy，20.202 秒仍零影格回呼；COMMIT 為 H.264，無 runtime error／interruption。測試時用 CoreGraphics 狀態確認 Mac 的 screenLocked=true、displayAsleep=true，故仍需解鎖環境及 OBS 實際畫面交叉核對。測後已解除實驗環境並恢复 NV12／BGRA。


## 原生 BLE 配對與第一次固定搖桿 probe

使用者允許藍牙並解鎖 Mac 後，发现 選定的 OsmoPocket3（裝置識別已省略），FFF4 properties=58／FFF5=54，兩者通知可用。第一次配對因漏回覆來源0x48的00/81 APP註冊而未取得SSID；修正只涵蓋該精確header後，配對與SSID／密碼查詢成功，來源資料未寫入日誌（`ble-pair-registration-fix.json`）。使用者隨後明確要求Mac保留原網路，因此主流程撤下Wi-Fi連接；再次以pairOnly配對成功，未發送53/10或憑證查詢（`ble-pair-only.json`）。

第一次BLE原生probe `artifacts/hardware-resumed/ble-native-probe-1/result.json`：基線7筆／0.539秒穩定；在0、52.272、103.356ms送出3筆低速命令，第四slot遲到超過20ms而中止。177.109ms時本機提交neutral，之後3筆新回報跨0.305秒保持穩定，yaw未變。此回合為**timing-aborted**；無位移下的穩定回報不能當作移動中的停止驗收，亦不能判定BLE不支援馬達控制。修正使用userInitiated／零容忍睡眠計時，並在有界probe中暫停MainActor上的格式／模型UI輪詢，判準與命令幅度未放寬。

第二次 BLE probe 已完成完整時序（`artifacts/hardware-resumed/ble-native-probe-2/result.json`）：四筆低速命令在0、50.427、101.075、151.222ms提交，201.287ms提交neutral。基線7筆／0.575秒，neutral後4筆／0.270秒穩定；yaw／pitch／roll的最大變化均0。前後JPEG也已查看，未見可辨識構圖位移。這是當次低速200ms profile沒有觀察到馬達作用，不升格為所有BLE組合皆不可控；下一步僅查一次04/50回覆路由，不提高速度或混入03/DA。

配對後的實際藍牙電池回報已解碼：source05/destination02的0D/02，2026-09-08T12:16:46Z回報100%、notCharging。此為相機端回報，不以USB500mA推算；不將100%未充電自動當作故障。

後續單次 `04/50` BLE 查詢約 1.01 秒逾時：`localSubmitted=true`、`responseReceived=false`、`motorPermissionConfirmed=false`，沒有 payload 可解析。這只證明本地提交，沒有確認相機回覆或馬達控制權。[查詢結果](../artifacts/hardware-resumed/ble-readiness-result.json)。

## USB tilt 小角度方向與跨零往返

在當次姿態下，UVC tilt 從 −9360 增至 −5760（名義 +1°），pan 保持360；目標與復位至 −9360 均通過 `stable_uvc_readback_with_tolerance`。已查看 `before.jpg`／`up.jpg`：螢幕邊框與固定圖形在畫面內下移，符合鏡頭上仰的構圖變化。此為目前姿態下 tilt 正方向的影像佐證，尚未驗證 pan、翻轉後映射或絕對物理角度。[結果與復位](../artifacts/hardware-resumed/uvc-direction-images/result.json)；舊影格依[媒體清理政策](TEST_ARTIFACTS.md)移除，保留觀察與實測報告。

接著 tilt 從 −9360（UVC −2.6°）跨零到8640（UVC +2.4°），名義位移 +5°／18000單位，pan 全程維持360。目標回讀8640，復位後回讀 −9360；兩次操作均 `completed=true`、`verified=true`，使用同一穩定回讀判準。前後 JPEG 可見較明顯的上仰構圖變化，修正了先前「正向可能一律被忽略」的過早推論；先前失敗記錄保留。[跨零與復位結果](../artifacts/hardware-resumed/uvc-tilt-five-degrees/result.json)；舊影格依[媒體清理政策](TEST_ARTIFACTS.md)移除，保留觀察與實測報告。

這兩組僅驗證小角度絕對目標、當次方向與返回原點。UVC 名義度數仍未完成物理校準，且不是全範圍、每軸20次往返、原生速度、連續按住／拖曳或移動中停止的完整驗收；對應待辦保持未完成。

## USB 小範圍雙軸正反向軌跡

2026-09-08 開發模式下完成 tilt／pan 各一組固定24 tick、約1.2秒的軌跡：前12 tick正向，後12 tick反向，最後獨立執行保持與穩定 GET_CUR 檢查。兩份結果均 `completedUSBReadbackExperiment=true`，`stop.completed=true`、`stop.verified=true`；`physicalMotionVerified` 仍為 `false`。

| Probe | 最後 tick 時刻 | 實際 GET_CUR 範圍（raw UVC） | 單筆 write 耗時 | Stop 的 target／observed |
|---|---:|---|---|---|
| [up-1](../artifacts/hardware-resumed/usb-trajectory-up-1/result.json) | 1.202595秒 | tilt −360…7200；pan維持0 | 0.447…1.102ms | pan0、tilt0 |
| [right-1](../artifacts/hardware-resumed/usb-trajectory-right-1/result.json) | 1.202934秒 | pan0…7560；tilt維持0 | 0.489…1.338ms | pan1440、tilt0 |

Stop 判準為 `hold_current_target_and_stable_uvc_readback`，只確認送出保持目標後 USB 回讀穩定；停止點並非各自原點，不記成復位完成。兩次結束後 App 都仍為 ready，1080×1920 NV12 預覽有新影格。單筆 write 耗時不代表機械反應時間、整體停止延遲或物理速度。

此批為 development-only 小範圍正反向與保持回讀證據。`before.jpg`／`after.jpg` 只保存 probe 前及停止後的視角，沒有運動中影片，不能據此宣稱動作平滑、物理速度已校準、全範圍或正式 GUI 已驗收；每軸20次往返、放開／失焦／競爭控制及真正尾移仍待驗證。新安裝包的建置／驗證結果另行記錄。

## 手動 USB UI 與拖曳距離實測

後續手動 USB 控制已在日常 UI 啟用。最近完成 Core219項、App21項離線測試（[usb-manual-tests.log](../artifacts/hardware-resumed/usb-manual-tests.log)）。以下五組實機操作經 `NSWindow.sendEvent` 注入**可見的 AppKit 輸入介面**，不是直接呼叫手勢 reducer，也不是作業系統全域滑鼠合成；均記錄 `surfaceEnabled=true`、`beganHolding=true`、`passed=true`，前後USB位置均有變化。

| 操作與證據 | USB位置變化（Δpan, Δtilt raw） | 結束事件到軟體清理完成 |
|---|---:|---:|
| [方向按鈕→放開](../artifacts/hardware-resumed/manual-button-release.json) | +5400, 0 | 0.330秒 |
| [拖曳→放開](../artifacts/hardware-resumed/manual-drag-release.json) | +1800, +1080 | 0.443秒 |
| [拖曳→失焦](../artifacts/hardware-resumed/manual-drag-focus.json) | +1800, +1080 | 0.432秒 |
| [方向按鈕→服務端Stop](../artifacts/hardware-resumed/manual-button-remote.json) | +5400, 0 | 0.318秒 |
| [方向按鈕→App Stop](../artifacts/hardware-resumed/manual-button-stop.json) | +5760, 0 | 0.619秒 |

五組 stop 都 `matchedLease=true`、`neutralSent=true`；此處USB後端的neutral是保持新鮮回讀位置，不是DJI原生搖桿封包。`remote` case呼叫的是服務端 `CameraService.stop()`，不能僅憑這份結果宣稱完整外部MCP傳輸已測完。時間欄是清理完成時間，五份報告均明列 `physicalStopLatencyVerified=false`，不作物理煞停時間或尾移證明。

新版移除獨立速度拉條、固定speed=1，以拖曳離中心距離改變輸入幅度。兩個相近按住窗口的對照：

- [near](../artifacts/hardware-resumed/manual-v2-near.json)：x=0.1951219512、y=0，pan由0到2160，位移2160 raw；放開清理0.335秒，passed。
- [far](../artifacts/hardware-resumed/manual-v2-far.json)：x=0.9756097561、y=0，pan由−360到7920，位移8280 raw；放開清理0.437秒，passed。

far的此次位移約為near的3.83倍，支持拖曳距離已影響實際USB回讀結果；不代表線性倍率、校準物理速度或全範圍皆已驗證。此前24tick開發probe的前後JPEG也仍僅是靜態視角，不能補足運動中平滑度影片。

回中預設已在本機取得target／observed同為pan0、tilt0，`completed=true`、`verified=true`，判準為 `stable_uvc_readback_with_tolerance`。[回中結果](../artifacts/hardware-resumed/manual-center-verified.json)。直接指定180°背面目標的試驗則回報 `motion_timeout` 並請求停止；保存的一筆後續觀察為ready、motion inactive、pan0／tilt0，沒有到達背面的成功證據。[翻轉失敗](../artifacts/hardware-resumed/manual-flip-back-error.json)、[後續觀察](../artifacts/hardware-resumed/manual-flip-observations.json)。

當時嘗試將遠距目標改用持續 `USBTargetApproach`；後續取得的USB路徑往返見下一段。使用者已明確表示慢速軌跡不符合兩個原生快速預設的目標，不能以此標成產品預設完成。完整宣告範圍、各姿態、物理角度與速度、運動平滑度、停止尾移、重連與多用戶端競爭仍須各自驗收；先前失敗紀錄保留。

## USB 遠距視角路徑證據：不作原生快速預設驗收

`USBTargetApproach` 持續更新遠距絕對目標後，透過手動USB UI共用的service API取得本次回到中心附近、正面→背面→正面的路徑回讀；不依賴BLE馬達控制。三份結果均 `accepted=true`、`completed=true`、`verified=true`，**這些欄位只表示相應USB操作的回讀判準通過，不表示使用者要求的機身double／triple快速預設已完成**：

| 操作與證據 | target（pan, tilt raw） | observed（pan, tilt raw） | 驗證 |
|---|---:|---:|---|
| [v3回中](../artifacts/hardware-resumed/manual-v3-center.json) | 0, 0 | −720, 0 | stable_uvc_readback_with_tolerance |
| [v3背面](../artifacts/hardware-resumed/manual-v3-flip-back.json) | 648000, 0 | 648000, 0 | continuous_usb_approach_and_stable_readback |
| [v3正面](../artifacts/hardware-resumed/manual-v3-flip-front.json) | 0, 0 | 0, 0 | continuous_usb_approach_and_stable_readback |

回中採容差判定，因此不把v3回中回讀−720寫成精確0。背面觀察記錄顯示pan由已開始取樣時的450360繼續增加至648000，最終ready／active=false；正面觀察記錄由207360繼續降至0，最終同為ready／active=false。這兩組觀察只覆蓋記錄中的區間，不能把第一筆當整段起點或據此估算總移動時間。[背面觀察](../artifacts/hardware-resumed/manual-v3-flip-back-observations.json)、[正面觀察](../artifacts/hardware-resumed/manual-v3-flip-front-observations.json)。

兩端均取得相機snapshot；主驗證程序已目視確認背面影像轉向另一側，正面snapshot在本段記錄時仍待目視核對。[背面影格metadata](../artifacts/hardware-resumed/manual-v3-back-frame.json)、[正面影格metadata](../artifacts/hardware-resumed/manual-v3-front-frame.json)。

此結果提供目前韌體／連接與本次起始姿態的USB視角路徑證據：持續接近可到達先前直接180°單次目標未確認到達的位置；舊失敗不刪除。pan648000是UVC名義180°目標，並非已校準的物理角度，也不是DJI原生 `04/4C FE09`。**產品的兩個預設仍須實現機身搖桿double／triple對應的原生快速回中與朝向切換；此慢速替代不符合需求，保持未完成。** 本次往返亦不代表完整宣告範圍、機械極限、所有姿態、物理速度或平滑度已驗收。安裝包結果另記，未以舊包代替。

## 原生 FE08、點按 AF 能力與變焦等待窗口

此批最近完成 Core236項、App26項離線測試，見 [zoom-focus-native-tests.log](../artifacts/hardware-resumed/zoom-focus-native-tests.log)。下列是相互獨立的實機結果，不能以離線測試或其中一項成功推定其他能力完成。

**原生BLE回中：** 單次 `04/4C FE08` 之前取得7筆／0.543秒穩定基線；`localSubmitted=true`，完整3秒窗口收到30筆新姿態，但pitch／roll／yaw最大變化皆0，`responseReceived=false`、`timedOut=true`、`movementObserved=false`。USB前後同為pan3960／tilt−720。最後USB保持清理`completed=true`、`verified=true`，只代表既有USB回讀穩定，不能當FE08有效的證據。`nativeCapabilityConfirmed=false`保留；本次無取消、無換連線。這是當次配對與連線條件下FE08未觀察到作用，不延伸為FE09已測過或所有BLE組合均不可行。[完整FE08結果](../artifacts/hardware-resumed/native-recenter-result.json)。原生快速回中／翻轉仍未完成，不恢復慢速USB軌跡作產品替代。

**點按自動對焦：** 當次AVFoundation session回報`currentMode=locked`，`supportsPoint=false`、`supportsAuto=false`、`supportsContinuous=false`。[能力結果](../artifacts/hardware-resumed/focus-capabilities.json)。這些值只描述目前USB／AVFoundation連線所提供的host API能力，不代表Pocket3機身沒有自動對焦，也不是對所有傳輸／模式的結論。使用者要求預覽tap AF，手動焦距（MF）拉條不是等價實作；此項保持未完成。

**USB變焦：** 當次宣告範圍100…400、step1、writable=true。100→200只送一次SET，舊約0.64秒讀回窗口結束時observed=164，故`completed=false`、`verified=false`並保留未確認結果，沒有自動重送。[首輪結果](../artifacts/hardware-resumed/zoom-live/result.json)。後續只讀取得current=200，主驗證程序目視before／zoom200影像確有放大。[稍後到位回讀](../artifacts/hardware-resumed/zoom-live/settled.json)。這是延遲到位證據，不把最初未確認覆寫成即時成功，也不據raw數值宣稱校準倍率或光學變焦。

返回100的舊窗口同樣只到128，仍記為未確認。[舊返回結果](../artifacts/hardware-resumed/zoom-live/restore-old-window.json)。後續settling改為最少2秒、最多6秒的只讀等待、不重送SET，100→200→100已取得匹配回讀；當時`zoom-final`的整體Stop判定仍為`passed=false`，不改寫為通過。[後續往返與舊Stop結果](../artifacts/hardware-resumed/zoom-final/result.json)。本次新Stop規則的獨立實機結果見下節。

## 2026-09-09 BLE lens 連續讀回與機身操作

本批使用既有`00/99 cam_lens_state`單次訂閱，觀察最多12秒的命名property回報；`cameraSettingsWritten=false`、`imagesSaved=false`。只解讀原始值前9 bytes的Float32候選x/y，保存每筆接收時間，不把property ACK或候選座標當作App對焦寫入成功。

- **基線：** 31筆有效樣本、0筆無效、12.009秒，均約`(0.499992, 0.499992)`，名義接收間隔約0.405秒。這證明連續回報可用，不是座標校準。[基線摘要](../artifacts/focus-live-2026-09-09/baseline-summary.json)
- **第一輪 body-tap：** 37筆／12.019秒，候選點分為中心6筆、約`(0.098894, 0.160204)`13筆、中心7筆、約`(0.908202, 0.762798)`11筆。使用者後續明確說只點左上／右下，但誤觸鏡頭轉向；context已記`confound=native_direction_change`、`calibrationConfirmed=false`。因此整輪屬有干擾觀察，**不能把中途回中心解釋成AF自動返回、模式規則或點位映射**。[序列](../artifacts/focus-live-2026-09-09/body-tap/series.json)、[分組](../artifacts/focus-live-2026-09-09/body-tap/groups.json)、[使用者補充與條件](../artifacts/focus-live-2026-09-09/body-tap/context.json)
- **第二輪 axis-taps：** 35筆／12.006秒，前2筆約`(0.230198, 0.387793)`、後33筆約`(0.519707, 0.317296)`，USB位置樣本的pan／tilt span均為0。指示為左中、再上中，但**實際操作順序仍待使用者確認**；沒有USB位置變化不會自動證明點按順序、座標軸或完整映射。兩筆／三十三筆分組及時序均保留。[摘要](../artifacts/focus-live-2026-09-09/axis-taps-7a14c2a3-c7fa-4c8f-b70e-e7c21c8b7c60/summary.json)、[完整序列](../artifacts/focus-live-2026-09-09/axis-taps-7a14c2a3-c7fa-4c8f-b70e-e7c21c8b7c60/series.json)、[操作指示](../artifacts/focus-live-2026-09-09/axis-taps-7a14c2a3-c7fa-4c8f-b70e-e7c21c8b7c60/context.json)

上述觀察沒有發送tap AF、WB或曝光setter，也沒有改變Mac網路。下一步仍需確認機身操作與時間／座標對照、可用的host寫入路徑及其實際結果；原生快速preset、完整方向／鏡像校準及光學合焦都不據此勾選完成。

## 2026-09-09 build11 Zoom 途中停止與恢復

新規則已在一次有界真機操作通過：原始值100，單次請求目標400；客戶端讀到194、再200，且請求仍為`moving`，此時發出全域Stop。保持目標／回讀均200；Stop內部摘要為11筆、穩定0.847秒、`toleranceRaw=1`，其後8筆獨立只讀樣本亦全為200、跨0.899秒。`stop.verified=true`、`zoomStop.verified=true`，整體`passed=true/status=complete`；原400請求以CancellationError結束，沒有到400再把靜止Stop當途中停止。[完整結果](../artifacts/zoom-moving-stop-2026-09-09/7ec1044c-d59b-46fd-a823-23aaa20b8aea/result.json)

該驗證器按政策停留在已確認的200，不自動恢復。其後明確恢復100，得到target／observed同為100、13筆回讀、穩定0.251秒及`completed=true/verified=true`。[獨立恢復結果](../artifacts/zoom-moving-stop-2026-09-09/7ec1044c-d59b-46fd-a823-23aaa20b8aea/restoration.json)

前一輪100→200過快完成，沒有捕捉到moving Stop，保留`status=not_confirmed/passed=false`；雖然當時目標回讀及後續靜止保持成功，也不能當途中Stop驗收。[前輪未確認](../artifacts/zoom-moving-stop-2026-09-09/36fbbb32-110d-4f0d-88bc-2d6fd01a15f1/result.json)。更早hold147後晚一筆146的`zoom-final`失敗紀錄同樣保留。

本次通過只確認該session的原始縮放途中保持及後續穩定讀回。報告明列內部Stop逐筆樣本未匯出、全域Stop端點沒有原子expected-session參數（客戶端在請求前後檢查身分），不能擴張成所有競爭／重連情況已驗收。沒有拍照；不宣稱校準倍率、物理煞停延遲、完整UI拖曳、Roll停止或全部視角完成。

## 2026-09-09 build12 BLE 點選對焦：傳送端中止

開發入口與424項Release回歸通過後，使用同一台Pocket3重新建立USB 4K NV12及BLE配對，讀取新鮮AF-C、Auto／EV0基準，請求候選點`(0.3, 0.3)`。這是四步序列的第一輪本機提交，最多各送一次，沒有自動重試或拍照。

實際只提交第一步`02→01 / 02/22 / payload02`（prepareAE）；緊接的Point在傳送端被`bluetooth_focus_write_blocked`擋下，`submittedCount=1`、`partialSequence=true`。Point／Hint／Commit均未送出，因此結果不能判定Pocket3的BLE對焦命令支援與否，也沒有相機NACK或光學合焦證據。[完整結果](../artifacts/focus-live-2026-09-09/tap-write-a4667799-97d3-475b-828b-708fc569592f/probe.stdout.json)

當時程式要求Prepare和Point連續同步寫入，缺少暫時無CoreBluetooth傳送額度時等待下一個**未送步驟**的排程。後續修正須保留每步僅提交一次、獨立有時限的額度等待、ACK時限與最終連線／取消檢查，不能重播已送出的Prepare來掩蓋問題。

中止後重新只讀，AF-C與Auto／EV0維持，lens候選座標前後均約`(0.499992, 0.499992)`；沒有已解碼的完整spot-AE狀態，故不宣稱所有測光副作用均已排除，也未猜測恢復命令。[前後對照](../artifacts/focus-live-2026-09-09/tap-write-a4667799-97d3-475b-828b-708fc569592f/summary.json)

## 2026-09-09 build13 BLE 點選對焦：額度恢復、Point未確認

修正後429項Release回歸通過（Core352／App55／Intelligence21／Evaluation1），另有9項縮放驗證器離線案例；共用Yun設計檔7個未改、357個三語字串檢查通過。App由乾淨來源`8036129`打包，保留原本本機簽署身分，重新連接同一台Pocket3的USB與BLE。[測試](../artifacts/tap-focus-build13/release-tests.log)、[建置身分](../artifacts/tap-focus-build13/build-metadata.json)

新實驗仍請求`(0.3, 0.3)`，先取得當次session的AF-C／Auto EV0。Prepare提交後，確實出現CoreBluetooth傳送額度不足；等待`0.010471958`秒恢復，再單次提交Point，證明上一輪的傳送排程問題已解決。但Point在800ms內沒有相符ACK，`end=ackTimeout/failure=point`；兩個已提交步驟均未收到ACK，Hint及Commit均未送出。這不是相機回NACK，也不是Point已確認生效。[原始結果](../artifacts/focus-live-2026-09-09/tap-write-c80067c8-c513-4025-9545-332ba1ea889e/probe.stdout.json)

請求期間2筆lens回報仍約中心。其後另開單次只讀觀察：從Point提交後約37.656秒開始，持續12.031秒，30筆均約`(0.499992, 0.499992)`、無無效候選值。**兩個窗口之間並非連續觀察**，不據此聲稱中間每一刻都未改變。最後AF-C、曝光Auto／EV0保持，USB 4K預覽約29.96fps、pan／tilt讀回0、服務ready且無動作。[摘要](../artifacts/focus-live-2026-09-09/tap-write-c80067c8-c513-4025-9545-332ba1ea889e/summary.json)、[後續完整序列](../artifacts/focus-live-2026-09-09/tap-write-c80067c8-c513-4025-9545-332ba1ea889e/post-lens-series.json)

本輪無照片、無Mac網路切換、無自動重試或猜測恢復。一般預覽Tap AF維持未確認；後續需取得Camera寫入路由／傳輸證據，不能只延長等待、改opcode或重新播放同一序列來宣稱完成。

## 2026-09-09 build13–15：真機 Apple／MLX 觀察任務

本批要求實際相機縮放後再取得新影格，不使用模擬相機，也不保存照片。各次結果獨立判定，不能把有回答、model API返回或相機仍連線當成要求已完成。

| 引擎／版本 | 實際結果 | 證據 |
|---|---|---|
| Apple／build13 | 4.610秒返回回答，但工具列表及`actions`為空，要求raw200未執行、相機仍100，`passed=false` | [result](../artifacts/live-ai-2026-09-09/apple-6a154bec-4fd6-410d-b486-25a41b7abb21/result.json) |
| MLX／build13 | harness總時間34.111秒；`capture_frame → camera_zoom_status → camera_set_zoom → capture_frame`，僅一次raw200、verified readback，真實裝置／同session的動作後及最終新影格，`passed=true` | [result](../artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/result.json)、[工具／影格紀錄](../artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/observation.stdout.json) |
| Apple plan／build14 | 計畫錯把合法raw200判為超出100–400，`request_not_fulfilled`，未執行縮放、仍100，`passed=false` | [result](../artifacts/live-ai-2026-09-09/apple-plan-15eb7103-ea06-41b9-8672-a8ef120d59a3/result.json) |
| Apple explicit／build15 | 明確要求raw150仍被以缺少目標拒絕，`request_not_fulfilled`，未執行縮放、仍100，`passed=false` | [result](../artifacts/live-ai-2026-09-09/apple-build15-explicit-7d730d99-86c1-40b4-a1df-3da430989fbc/result.json) |

MLX結果中的八項檢查均通過，包含實際工具順序、單次raw200、回讀、新的post-zoom及final frame。它是既有MLX模型工具流程的真機成功，不是Apple文字計畫由App代執行，也不擴成外部MCP客戶端或全部運動情況已驗收。之後明確恢復raw100及manual、cleanup確認；[恢復縮放](../artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/restore-zoom.stdout.json)、[最終相機](../artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/final-camera.stdout.json)。卸載後MLX `cacheMemoryBytes=0`、`activeMemoryBytes=4036`；不是App RSS或全部記憶體歸零。[卸載後紀錄](../artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/after-model-unload.json)

Apple的獨立文字計畫提取已保存三份JSON及來源／instructions hash：[current-natural](../artifacts/apple-plan-extraction-2026-09-09/current-natural.json)、[current-raw150](../artifacts/apple-plan-extraction-2026-09-09/current-raw150.json)、[associated-raw150](../artifacts/apple-plan-extraction-2026-09-09/associated-raw150.json)、[source-provenance](../artifacts/apple-plan-extraction-2026-09-09/source-provenance.json)。這些是診斷模型提取行為的資料，不是另外三次硬體成功。build16正準備新的混合流程／roles修正，尚未實測，不以程式已變更或編譯中標記問題已解決。

## 2026-09-09：WB 單次寫入的 pair-only／full-pair 對照

兩輪均以機身讀回的Auto為基線，請求5600K；各自只有一次SET，完整觀察窗口結束，沒有ACK、沒有匹配5600K，`localSubmitted=true`但`acknowledged=false/stateMatched=false/applied=false`。這不是明確NACK，也不是已證實支援的WB writer。

| 條件 | 回報及結果 | 證據 |
|---|---|---|
| pairOnly／build14 | 7筆觀察仍Auto，`end=readbackTimeout`，原Auto狀態未變，無restore或retry | [result](../artifacts/camera-settings-live-2026-09-09/white-balance-129a5c24-0e92-4fd2-acce-9596ce96fb68/result.json)、[writer](../artifacts/camera-settings-live-2026-09-09/white-balance-129a5c24-0e92-4fd2-acce-9596ce96fb68/write.stdout.json) |
| full pair／build15 | 6筆觀察仍Auto，同為`readbackTimeout`；原Auto仍在，沒有為「恢復」再寫一次 | [result](../artifacts/full-pair-control-2026-09-09/white-balance-43db759b-752c-4983-be27-ebbd04da92ae/result.json)、[writer](../artifacts/full-pair-control-2026-09-09/white-balance-43db759b-752c-4983-be27-ebbd04da92ae/write.stdout.json) |

完整配對已到`credentialsReady`、`credentialsAvailable=true`，Mac的`samePrimaryRoute=true`，沒有呼叫相機Wi-Fi join。[配對狀態](../artifacts/full-pair-control-2026-09-09/paired.json)、[網路比較](../artifacts/full-pair-control-2026-09-09/network-check.json)。文件只記這些非敏感狀態，不列出SSID或密碼。完整配對補足了與pair-only不同的連線條件，但沒有令本次WB設定生效；不可推成其他AF／EV設定均已測過，亦不表示需要改Mac網路或猜測新opcode。

## 2026-09-09：完整配對、解鎖與未提交的原生回中

首次native-recenter前置USB offset在`screenUnavailable=true`環境遇到`motion_timeout`，原生命令被保留未送；最後pan／tilt為0、motion inactive，沒有額外還原寫入。[前置失敗](../artifacts/full-pair-control-2026-09-09/native-recenter-faa6cbbb-c2d1-42a5-a7d5-284bc00329fe/result.json)、[當時UI條件](../artifacts/full-pair-control-2026-09-09/ui-check.json)。這是前置未成立，不能記為FE08被相機拒絕。

使用者開啟視窗後，`ui-check-after-user-open`通過、`animationVerified=true/screenUnavailable=false`。接著可見manual button放開流程`passed=true`，pan由0到11880、tilt保持0。[UI](../artifacts/full-pair-control-2026-09-09/ui-check-after-user-open.json)、[手動按鈕](../artifacts/full-pair-control-2026-09-09/manual-button-release-unlocked.json)。不將兩個不同環境的結果覆寫成同一次成功，也不據此宣稱物理速度或停止延遲已校準。

解鎖後的另一輪native-recenter，基線只收到2筆，間隔1.4174705秒；超過既有0.35秒新鮮間隔限制，穩定窗口重設，`baselineDurationSeconds=0/baselineStable=false`，以`bluetooth_recenter_baseline`中止，`localSubmitted=false`。**這一輪沒有發FE08，不能寫成FE08再次發送後無效。** 當時USB前後及cleanup target／observed均pan12240、tilt0，cleanup verified只代表USB保持。[結果](../artifacts/full-pair-control-2026-09-09/native-recenter-unlocked-5427968d-0030-4be5-bfaf-544fe80c2071/native-recenter.stdout.json)、[當次後續相機狀態](../artifacts/full-pair-control-2026-09-09/native-recenter-unlocked-5427968d-0030-4be5-bfaf-544fe80c2071/after-camera.stdout.json)

主驗證程序稍後另查到pan0，期間未追加restore；原因未知，不能歸因到未送出的FE08，也不能將上述12240的原始snapshot改寫成0。程式審查確認native preset活動期間原本會關閉keepalive及`drainWrites`；root已修正讓只讀基線／觀察階段保留會話維持流量，原有0.5秒穩定基線及其他門檻不變。此修正尚未在新code實測，不能先認定基線問題或原生回中已解決。

## 2026-09-09 build16–17：混合AI與介面更新

build16的實際模型分工為MLX執行相機工具、App更新影格、Apple回答。一次真機任務耗時38.039秒，模型工具依序為capture／zoom status／單次raw200／capture，縮放回讀確認；之後App取得同裝置、同session且較新的影格才交給Apple。`executionRoles`明示`controllerEngine=mlx`、`answerEngine=apple`、`finalFrameRefresh=app`；host取像沒有冒充第五個模型工具呼叫。11項檢查通過，恢復raw100與manual亦確認。[完整結果](../artifacts/live-ai-2026-09-09/hybrid-build16-c7cf0025-cc5e-4b3a-b4fa-c0b684493ecd/result.json)、[角色與工具](../artifacts/live-ai-2026-09-09/hybrid-build16-c7cf0025-cc5e-4b3a-b4fa-c0b684493ecd/observation.stdout.json)

這證明該混合流程可完成這次請求，不代表Apple獨立控制、所有自然語句、外部MCP或完整視角均已驗收。失敗的Apple文字計畫實驗已從產品移除；純Apple觀察仍不需要MLX，選MLX時維持其完整工具／回答流程。沒有自動下載模型，未保存相機照片。

build16通過454項Release測試；新增角色文字與縮放紀錄顯示後，12張介面截圖已逐張檢視，九張更新到公開文件。三語卡片／控制列／狀態條保持對齊，所有圖均遮蔽感測器畫面，沒有私人`/Users`路徑；最小視窗左欄仍可滾動。[視覺記錄](../artifacts/hybrid-ui-build16/visual-review.json)、[公開圖片](images/manifest.json)

## 2026-09-09 原生基線等待：取得資料與發送命令分開

build16保留session housekeeping後，一次原生回中前的基線有5筆、穩定0.474秒，未達0.5秒；另一個只讀暖機窗口取得15筆並觀察到合格半秒穩定區段，但後續probe重新收集的基線仍不足。兩輪`localSubmitted=false`，沒有FE08的裝置反應可供判斷；不把它們當作命令已發送後失敗。[第一輪](../artifacts/native-heartbeat-build16/summary.json)、[只讀暖機](../artifacts/native-heartbeat-build16/warm-telemetry.json)、[後續未提交](../artifacts/native-heartbeat-build16/native-recenter-warm.json)

之後用USB恢復pan目標0，回讀−360在既有容差內確認，tilt0；BLE在恢復前的yawRaw23與當時UVC pan8280分別記錄，不宣稱已完成跨座標校準。[恢復前](../artifacts/native-heartbeat-build16/before-restore-camera.json)、[USB恢復](../artifacts/native-heartbeat-build16/restore-usb.stdout.json)

build17將**命令前取得基線的等待上限**設為3秒；半秒穩定、至少3筆、最大樣本間隔0.35秒及角度span0.25°不變。用途在型別上分開，所有既有Stop呼叫仍使用1.5秒；命令後觀察仍為3秒、單次提交而不重送。459項Release測試通過。安裝後新輪次回報螢幕不可用，manual offset未開始，pan／tilt保持0，因此FE08沒有送出。新基線實測與原生快速預設仍待完成。[測試](../artifacts/native-baseline-build17/release-tests.log)、[本輪未執行結果](../artifacts/native-baseline-build17/result.json)、[建置](../artifacts/native-baseline-build17/build-metadata.json)

## 2026-09-09 build17：外部 MCP 縮放與權限拒絕

使用安裝包內的`pocket3 mcp`啟動獨立stdio客戶端，握手MCP 2025-11-25並核對六個公開工具。相機／capture session／USB attachment／boot在客戶端檢查，兩次zoom RPC另外帶`expectedSessionID`。正常流程約2.968秒：讀取真實影格、查詢raw100及能力、單次SET200、確認穩定回讀200、取得新影格，之後單次恢復100及另一張新影格。三張影格的ID、host timestamp及PTS均前進，動作後影格晚於已確認的zoom回覆；兩次SET皆`accepted/completed/verified=true`。[結果](../artifacts/mcp-zoom-hardware/6c10d197-9e1e-4b4b-b518-348f56141472/result.json)

獨立manual run使用合法raw200要求，確認MCP回`isError=true/access_denied`，前後raw100未變；沒有呼叫capture或發送恢復動作。[拒絕結果](../artifacts/mcp-zoom-hardware/cea79505-a683-4c99-9b54-f10aedd42c4e/result.json)。完成後root恢復manual、確認motion inactive及原capture session。JPEG僅於記憶體檢查格式、記錄hash與大小，沒有照片檔案。

這次是真實外部MCP工具路徑，不含LLM回答、雲台移動、MCP取消／重連競爭或倍率校準。Global Stop沒有原子expected-session參數，失敗清理的限制保留在執行器；不能據單次成功擴大成所有競爭情況通過。

使用者提出Mac Studio遠端桌面情境後，另檢查螢幕判定的用途：`screenUnavailable`只出現在popover介面驗證；相機服務沒有實體螢幕亮起的許可條件。早先螢幕不可用時取像仍更新，但這次操作前11:25:16Z的獨立讀值已為`displayAsleep=false/displayActive=true`，因此**不列為關螢幕／headless／遠端桌面成功**。顯示器關閉、登入工作階段鎖定和整台Mac睡眠須分開驗收；現有`willSleep`處理會停止操作並suspend相機。[版本與環境](../artifacts/mcp-zoom-hardware/build17-context.json)

## 2026-09-09 build18：背景取像的活動保護

新增`CaptureActivityLease`，在AVFoundation成功啟動並通過格式／generation檢查後持有`.userInitiated`活動。依本機SDK定義，它包含`idleSystemSleepDisabled`而不包含`idleDisplaySleepDisabled`；普通停止、失敗或實際session停止／裝置斷線時釋放。延遲通知先記錄generation，再於capture queue檢查當前session／裝置，不能因舊stop事件釋放新活動。明確系統睡眠仍走既有best-effort Stop／suspend流程，不宣稱OS保證等待機械停止。

完整Release suite共有463項，其中460項執行通過、3項opt-in跳過（兩個模型任務與一個recorded evaluation）；新增4項activity生命週期測試通過。另一個SDK平台差異的首次編譯失敗已保留，修正後才記錄通過。7個共用Yun設計檔未改、366個三語字串檢查通過。[Release log](../artifacts/capture-activity-build18/release-tests.log)

由乾淨來源`f54b37499c96420f55615e275d89317a76370f93`打包並安裝build18，App SHA-256為`a98ab3614ed120fa25f5e1b70261864ff88d8e9a85dea5fa49f57f38c89e5220`。[建置身分](../artifacts/capture-activity-build18/build-metadata.json)

實機透過`pmset -g assertions`確認：取像時App PID持有一份名為`Pocket 3 active camera capture`的`PreventUserIdleSystemSleep`；`validation-pause`後App活動為空，重新連接同相機後恰有一份新活動。各窗口均沒有App的`PreventUserIdleDisplaySleep`。capture session確實更新，最終4K30 NV12約29.999fps、新影格age約0.00143秒、manual且motion inactive，縮放讀回100。[實機生命週期](../artifacts/capture-activity-build18/live-activity-lifecycle.json)、[最終取像](../artifacts/capture-activity-build18/final-status.json)

2026-09-11最新完整影音驗收以1080p30 NV12與48kHz雙聲道執行1,800.91秒：1,720個scalar sample、零failure，最終29.97fps、影格age 0.0038秒、resident 329.6MB；完成後明確pause，frames歸零。驗證器不保存相機影像或音訊內容，僅保留大小、時間、格式、記憶體與數量指標。[報告](../artifacts/hardware-complete-2026-09-11/stream-audio-full/)

本輪沒有拍照、修改系統睡眠偏好、要求螢幕亮起或切換Mac網路。這是活動建立／釋放及新連線的實測；**未實際讓顯示器關閉或整機睡眠，也未進行Mac Studio遠端桌面手勢／斷線驗收**。App仍是登入後的使用者服務，不是登入前daemon。

## 2026-09-09 build18：完整配對後真正提交 FE08

以現有USB偏移pan−14040／tilt6120開始，沒有先模擬手勢或另發offset命令。重新建立BLE完整配對至`credentialsReady`，註冊確認已提交，Mac未加入相機網路。新3秒取得窗口收到6筆、0.572594秒穩定基線後，真正單次提交`02→04 / 04/4C / FE08`。後續完整3秒收到27筆姿態，yaw−3.9°／pitch178.3°／roll0°均未改變，沒有匹配ACK；`localSubmitted=true/responseReceived=false/movementObserved=false`。[配對](../artifacts/native-fullpair-build18/paired.json)、[命令與回報](../artifacts/native-fullpair-build18/native-recenter.json)

USB前後位置亦相同，cleanup target／observed保持−14040／6120且verified，最終ready／manual。這一輪補足了先前「基線不足所以未提交」的缺失；結果仍不支持BLE FE08已可用。沒有推定FE09相同行為、恢復到猜測原點或將慢速USB預設當原生成功。這些BLE角度只是相機遙測座標，不宣稱已和USB或物理鏡頭角度完成校準。

## 2026-09-09：完整 Webcam USB 介面查核

既有`usb-video-descriptors.json`只列class14（Video）的介面，所以單靠該filtered輸出不能排除其他控制介面。本次另讀一次完整configuration descriptor：741 bytes完整解析、5個介面、無解析錯誤，VID`2ca3`／PID`0023`及USB attachment與本次相機一致。[完整原始資料](../artifacts/usb-all-descriptors-2026-09-09.json)

| Interface | 類型 | Endpoint |
|---|---|---|
| 0 | VideoControl | 81 interrupt IN |
| 1 | VideoStreaming | 82 bulk IN |
| 2 | AudioControl | 無 |
| 3 | AudioStreaming，alt1 | 01 isochronous OUT |
| 4 | AudioStreaming，alt1 | 83 isochronous IN |

這份目前Webcam配置沒有vendor-specific、CDC或額外bulk OUT介面。唯一UVC Extension Unit仍為unit6、兩個未知controls；既有GET_LEN為16 bytes，不足以把它識別為DUML、對焦或原生雲台命令。未對它猜測SET，也未使用seize、切換USB configuration／alternate setting或卸載驅動。未公開EP0／其他機身模式的可能性不由此排除。

## 2026-09-09 build19：MCP 取消確實保持縮放

原有MCP SDK→IPC的取消已能送到service，但`zoom`的catch只記錄錯誤、清除動作狀態，沒有處理裝置仍朝目標slew的情況。修正後同一motion ID／generation、capture session與連線的失敗取消會等待既有獨立Stop；重新授予相同control權限不會錯誤地阻擋此清理。真正換連線或新動作仍受身分限制。未確認的zoom hold會阻擋後續zoom及pan／tilt，而不是覆蓋待停止目標。

新增5項Core回歸涵蓋真IPC＋假UVC取消後保持、failed hold禁止新寫入、replacement零舊清理、重複control授權及Stop去重。完整Release suite為470項：467項執行通過、3項opt-in跳過；另有8個Python取消驗證器測試、11個純假情境，包含磁碟／關閉失敗不能誤報成功。[Release](../artifacts/mcp-cancel-build19/release-tests.log)

乾淨來源`72ab388d2c40ebf9e5c8ea5cbfae70e68e0d1208`的build19已安裝，App SHA-256為`cb3cd2400826e1cbe1b17f85d294bbd98e41983359e4689e7687e23a674237c2`。[建置身分](../artifacts/mcp-cancel-build19/build-metadata.json)

實際外部stdio MCP先提交raw400，觀察到相機仍moving且兩個不同讀回105／200，再送一次`notifications/cancelled`。服務進入stopping並撤回AI動作權限，之後ready／observe，raw200的獨立回讀穩定1.086686秒；未到原目標400。**客戶端沒有送Stop**，取消請求沒有完成回覆，隨後tools/list仍回覆完整六個工具。該測試不拍照、不自行復位。[完整結果](../artifacts/mcp-zoom-cancellation/59d10e7c-ccc3-4a09-9094-54486775c469/result.json)

檢視結果並再次確認同連線／raw200後，另以manual明確恢復100，`completed/verified=true`。[獨立恢復](../artifacts/mcp-zoom-cancellation/59d10e7c-ccc3-4a09-9094-54486775c469/explicit-restoration.json)。這只驗一個已開始動作後的MCP取消，不包括早於SDK request登記的取消、EOF、所有重連競爭、物理煞停延遲或完整倍率校準。

## 硬體重新接回的唯讀 inventory

`Scripts/hardware-resume-inventory.py --wait-seconds 60` 只會等待一台已列舉的 Pocket 3，讀取 App `status` 與 `formats`，再寫出 device、power、format counts 與 advertised input path 的 JSON。它不會 connect preview、啟動 Bluetooth、改 Wi-Fi、送任何 UVC/DUML 寫入、讀音訊或保存影像。輸出的 format 仍是 `advertised_only`，不能替代新影格或實體控制驗收。

## 2026-09-09 build19：明確 H.264 輸出的有界測試

開發限定`POCKET3_CAPTURE_OUTPUT=h264`與`--hardware-validation`現在使用Apple明列的`AVVideoCodecKey`，在activeFormat配置後檢查`availableVideoCodecTypes`包含avc1，才指定H.264及要求尺寸。普通啟動仍為BGRA。這是[AVFoundation輸出設定](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/availablevideocodectypes)，不保證裝置原生直通，可能由主機重新編碼。

| 輸入 | 6秒啟動窗口中的實際回呼 | 結果 |
|---|---|---|
| NV12 1920×1080@30 | 138 samples，全為avc1 CMBlockBuffer，零pixel buffer | 壓縮輸出資料路徑成立；沒有解碼，所以普通preview啟動未通過 |
| UYVY 1920×1080@30 | 零sample | 仍無輸入回呼 |
| UYVY 3840×2160@30 | 零sample | 仍無輸入回呼 |
| UYVY 3840×2160@60 | 零sample | 仍無輸入回呼 |

四項均使用capture-only隔離（skipUVC）、有界6秒窗口，無runtime error或interruption回報，也沒有保存影像。NV12正向對照證明新設定確實可產生壓縮資料；另外三項仍沒有可交給解碼器的sample，不能把它們列為H.264／4K60已可用。[結果](../artifacts/h264-output-build19/result.json)

測完清除App的診斷環境、正常重啟並恢復3840×2160@30 NV12→BGRA與USB控制。暖機後約29.983fps、影格age約0.0223秒，raw100、manual、motion inactive；早期重連後1秒的22.93fps讀值保留，不將它改寫成已穩定30fps。[恢復](../artifacts/h264-output-build19/normal-restored.json)、[暖機後](../artifacts/h264-output-build19/normal-restored-settled.json)

## 2026-09-09 build20：逾時保持與取消回歸

正常settling deadline耗盡也會呼叫與取消相同的`stopCurrentZoom`，僅處理仍由原motion owner持有的連線。先保留原未完成縮放的snapshot，再等待獨立Stop，回覆仍是`completed=false/verified=false`；停止成功不會把原目標算成已達成。新增第6項Core回歸實際等完settling及hold窗口（3.325秒），假UVC恰有`[200,160]`兩次寫入，沒有重試200或自行恢復100，AI動作權限撤回。完整Release suite為471項，468執行通過、3項opt-in跳過。[回歸](../artifacts/mcp-cancel-build20/release-tests.log)

乾淨來源`27b6119ca6ffef6d3538403aeb19b5341b389dab`的build20已安裝，App SHA-256為`643395599dd4ae38c361fc54df47427cdf1aa7ba410846c119157a64c7e408b9`。[建置](../artifacts/mcp-cancel-build20/build-metadata.json)

新版本再次進行實際MCP縮放中取消：原目標400，取消後保持200，獨立穩定窗口1.089544秒、clientStopSent=false、helper仍可用、取消回覆被抑制。這驗證共用清理重構沒有破壞已開始請求的真機取消；正常逾時路徑仍是上面的假UVC回歸，沒有製造或宣稱真機逾時成功。[實機取消](../artifacts/mcp-zoom-cancellation/522db46d-a71a-4358-8f3f-75ee0023e89e/result.json)

其後明確恢復100並確認verified。最終4K30 NV12→BGRA約29.989fps、新影格age約0.00374秒、manual且motion inactive。[恢復](../artifacts/mcp-zoom-cancellation/522db46d-a71a-4358-8f3f-75ee0023e89e/explicit-restoration.json)、[最終狀態](../artifacts/mcp-cancel-build20/final-status.json)。本輪無照片或網路切換；原生preset、UYVY／4K60、早到取消、EOF及實際遠端桌面仍不據此宣稱完成。
# Build 25：USB／BLE 唯讀相機狀態與設定（2026-09-11）

build 25 的開發 App 以 `--hardware-validation` 啟動，USB 使用 `1920x1080@30`／NV12。兩秒後取像為 62 frames、30.04 fps、1920×1080、BGRA output，UVC 宣告 pan/tilt、zoom、roll，沒有送出雲台、縮放、對焦、設定或錄影命令。USB power registry 回報 500 mA／480 Mb/s；`chargingState` 仍是 `unknown`，不可由 USB allocation 推論正在充電。

BLE 候選 `OsmoPocket3-7CF5` 完成 protocol pairing；身份仍為 `unverified_candidate`，沒有把 BLE peer 與 USB serial 關聯。App 沒有讀取 Wi-Fi credentials，也沒有加入相機網路。配對後的 `02/80`／`02/DC` 唯讀資料一致回報：未錄影、SD total 488,015 MiB、free 176,047 MiB、remaining 36,633 s、elapsed 0 s。Webcam 狀態的 shooting mode raw 是 `0x23`，目前 enum 沒有 capture-confirmed 名稱，因此保留 raw、不猜為 Video。

九個 allowlisted named properties 依序查詢。AF、image effect、exposure 可直接收到 property push；其餘六個單獨 query 在各自兩秒 window 逾時。隨後 Wireless UI 的完整循序讀取收到全部九類 observation：1080p／30 fps／HEVC、landscape、Normal、AF-C、Auto WB、Auto EV 0，以及 photo/lapse/motionlapse/panorama raw/typed fields。未知 photo／panorama code 保留 `0x00`／`0x02`，沒有映射成未證實設定。所有單獨 query 都沒有 matching ACK，`propertyReceived` 與 ACK 分開記錄，不能稱 setter 或 subscription 已確認。

被動 tracking candidate allowlist `02/89`、`02/A5`、`02/A6` 在本次基線為空；沒有送 tracking command，也不能由空集合推論 Pocket 3 不支援機身 ActiveTrack。UI 擷取排除 camera preview 與 private observation content。完整機器可讀摘要在 `artifacts/hardware-complete-2026-09-11/build25-hardware-summary.json`；各 property query、USB/BLE status 與無 preview 的 Wireless UI capture 位於同一目錄。

收緊 readback 後的最終 build25 session `F6545D2B-764B-4CEA-9525-4B6AB73D7CAD` 再次完成 pairing。電池保留 `chargingStateRaw=0`；姿態額外保留未命名的 `modeStatusRaw=128`、`limitStatusRaw=0`，兩者只供診斷，不作模式或機械限位判斷。Lens decoder 現在只接受 capture-confirmed `0xB1/0xB2`，writer payload `0x01/0x02` 維持 unknown；非 video-like `02/80` 不再輸出 elapsed recording time。

## Build 25：NV12 橫幅／直幅 metrics-only 矩陣（2026-09-11）

`Scripts/validate-formats.py` 已改為只記錄串流 metrics，不再呼叫 snapshot 或保存相機畫面；每次 trial 綁定 exact device/session/mode/pixel format，核對新影格、freshness、尺寸、輸入 FourCC、BGRA output、rotation metadata 與 FPS，最後一定 `validation-pause`。第一次 4秒暖機只通過2/13，其他 trial 的形狀與影格正常但 session-lifetime `recentFPS` 尚未收斂；該次失敗保留，不解讀成格式不支援。

以10秒暖機重跑後，以下13個實際 NV12／`420v` 模式全部通過：`1280x720@25/30`、`1920x1080@24/25/30`、`3840x2160@24/25/30`、`720x1280@25/30`、`1080x1920@24/25/30`。median FPS 分別落在23.975–25.028或29.949–29.970的對應目標附近；所有 frame 尺寸精確匹配、age <1秒、rotation metadata為0。結果目錄沒有JPEG，最後 phase為paused、frames歸零、access manual。[結果](../artifacts/hardware-complete-2026-09-11/build25-nv12-matrix-warm/51a6c591-668e-4474-bf39-7a3edcfd9901/result.json)

這份矩陣證明 AVFoundation 串流協商、metadata和速率；因為刻意不保存／檢視感測器畫面，它**不證明**直幅內容方向、上下黑邊、鏡像或場景品質。這些需要另外明確授權的隱私安全視覺核對。

同一 build25 metrics-only harness 隨後只測兩個 UYVY 代表模式：`1920x1080@30` 與僅宣告 UYVY 的 `3840x2160@60`。兩者均在 startup window 內回 `no_frame`，`videoSampleCount=0`、`pixelBufferCount=0`、`nonImageVideoSampleCount=0`、runtime/interruption均0；AVFoundation 仍列出 `2vuy` output 與 `avc1/jpeg` codec。最後已 pause，沒有影像檔、BLE、控制或機身設定寫入。[結果](../artifacts/hardware-complete-2026-09-11/build25-uyvy-representative/a7abb20c-e58e-4c64-9d3c-b961cc5fd999/result.json)、[失敗後診斷](../artifacts/hardware-complete-2026-09-11/build25-after-uyvy.json)

這與先前 UYVY 零 callback 證據一致；本次沒有重播同模式。下一步需改善 active-format／output negotiation 診斷或找到不同 host transport，不能因裝置列出 `2vuy` 就在 UI 宣稱可用。

build25 隨後加入 scalar-only negotiation snapshot，並以新診斷只重測一次 `1920x1080@30` 的2vuy host path。結果清楚顯示：selected active format為`2vuy`／1920×1080／30fps，active min/max duration均0.0333333秒，session preset為1080p、session running、device connected、video connection enabled且active；BGRA output settings只有Width/Height/PixelFormatType的型別名稱。然而 input port仍回`420v`，callback timeout一次且`noVideoSample=true`。這定位為 AVFoundation active-format與input-port negotiation不一致，仍沒有可交給VideoToolbox的sample。[新診斷](../artifacts/hardware-complete-2026-09-11/build25-uyvy-negotiation/6eae14d5-2d58-4077-a08b-be83852571b0/result.json)

介面中的格式名稱因此改為`420v host path (MJPEG UVC)`與`2vuy host path (H.264 UVC)`，避免把AVFoundation host subtype冒充USB wire格式。真正支援H.264高幀率需要可恢復的encoded-UVC backend／NAL組裝／VideoToolbox解碼，不能把decoder接到目前為零的AVFoundation callback。

## Build 25：ActiveTrack 被動事件錄製準備（2026-09-11）

新增 developer-only `validation-wireless-camera-events`：只在明確 session/peripheral 已配對時，被動接收 CRC-valid `Camera01→App02`、flags0、set02 frame；每個 command ID 獨立做sequence/replay admission，payload上限128 bytes、20秒／512筆，內部只保存frame SHA-256去重。它沒有BLE write、subscription、pairing、Wi-Fi、USB control或tracking-success解讀。初版20秒窗口撞上IPC預設20秒receive timeout，client得到`ipc_disconnected`但App仍存活；現已把此明確operation列入120秒long-operation並補測試。

使用者其後澄清：這一輪自動追蹤一直是關閉的。因此舊paired session只有一般`02/80`等header、既有`02/89/A5/A6`候選為空，只能作為tracking-off基線，不能代表tracking-active結果。換入新recorder build後，BLE候選仍持續廣播（RSSI約−45至−50），但三次有間隔的GATT subscribe均以`bluetooth_gatt_timeout`結束；這是連線相容性觀察，不能把它歸因於ActiveTrack。下一步是在新版已arm的20秒window內，由使用者明確切換off/on並記錄時點，再取得可比較事件全集。

下一次GATT連接與protocol pairing成功，session為`3B039472-FC64-4E49-8BF1-6E432DE4C25B`。recorder已arm的20秒window正常結束，收到148筆camera-domain frame：`02/80` 119筆、`02/DC` 29筆，兩種payload在窗口內各只有一個值，`89/A5/A6`仍未出現；前後`04/05` pose mode/limit raw也都是128/0。依使用者後續澄清，此窗口的自動追蹤也是關閉，因此它只證明已測Camera set02候選的off-baseline未變，不能證明機內追蹤未運作或沒有其他domain事件。[完整事件](../artifacts/hardware-complete-2026-09-11/activetrack-window-1.json)、[窗口後狀態](../artifacts/hardware-complete-2026-09-11/activetrack-window-1-after.json)

recorder後續已擴充為只接受Camera01/set02與Gimbal04/set04的**payload變更**：每個route獨立sequence admission，route+payload SHA-256排除重複高頻telemetry，相同值另計`unchangedFrameCount`，A→B→A仍保留三個狀態。需在新版App、由使用者明確標記的tracking off/on下一輪窗口取得實機差異。

## Build 25：AVFoundation HEVC host-output capability（2026-09-11）

在這台 Pocket 3 的 USB 1920×1080@30、NV12 active format，以明確 `hevc` host-output policy 檢查 `AVCaptureVideoDataOutput.availableVideoCodecTypes`。它只回報 `avc1`、`jpeg`，沒有 `hvc1`，所以服務在建立 callback 前以 `output_codec_unavailable` 拒絕；沒有 video sample、影格、設定寫入或自動重試。隨後同一裝置回到 BGRA 正向對照取得一張影格，再 privacy pause 回到零影格。這只界定 macOS AVFoundation host-output transport，不能否定機身目前的 HEVC 錄影設定，也不能冒稱 USB HEVC 已支援。[metrics-only 結果](../artifacts/hardware-complete-2026-09-11/hevc-host-output-avfoundation-1080p30.json)

## Build 25：HEVC 機內錄影唯讀基準（2026-09-11）

在既有paired session只讀訂閱`cam_video_param_v2`，單次subscription已送出、property push成功、沒有matching ACK；回覆value長度10，解碼為4K（`0x10`）、30 fps（`0x03`）、HEVC（`compression=0x01`）。這確認機身目前的HEVC baseline，沒有送`02/AB`或任何設定寫入。後續developer writer的HEVC no-op必須以完整fresh raw baseline作零寫入驗證；H.264→HEVC→H.264的受控測試仍等追蹤關閉與新版App重啟。[唯讀結果](../artifacts/hardware-complete-2026-09-11/hevc-current-readonly-property.json)

## 2026-09-12：USB 接回後的 BLE 充電狀態正向驗證

使用者將同一台 Pocket 3 開機並接回 USB 後，IORegistry 唯讀確認 `DJIPocket3@01100000`、VID/PID `2ca3:0023`、480 Mb/s。既有 build25 背景 App 重新掃描並連接 BLE peer `OsmoPocket3-7CF5`，完成 protocol pairing；session `7118E395-9991-4ADA-81C2-E57A4A3CB9CD` 的新鮮 `0D/02` 相機遙測回報電量 95%、`chargingState=charging`、`chargingStateRaw=1`。同時相機為未錄影、SD total 488,015 MiB／free 176,032 MiB。

這是相機端 BLE 充電旗標的正向證據，與先前 `raw=0/notCharging` 明確不同；結論不是由 USB 500 mA allocation 推算。此輪沒有啟動預覽、保存畫面、送雲台／設定／錄影命令，也沒有讀取 Wi-Fi credentials 或切換 Mac 網路。

2026-09-12 再以最新 build 25 連接同一台 Pocket 3。BLE session `AC72778D-3F32-40E3-A2A7-7E194BB15629` 完成 pairing，機身回報電量 100%、`chargingStateRaw=0`／`notCharging`；同時 IORegistry 唯讀確認 `DJIPocket3@01100000`、`UsbPowerSinkAllocation=500`、480 Mb/s。啟動 UVC 後擷取維持 1920×1080／約 30 fps，USB power status 為 present。這組證據應分類為 `full_not_charging`：USB 外部供電存在，而滿電機身目前沒有充入；不得顯示為供電失敗，也不得把 500 mA 當成實測充電電流。沒有保存影像或送出相機控制命令。

## Build 25：direct UVC VS interface read-only inventory（2026-09-11）

以IORegistry只讀檢查目前USB topology，確認同一Pocket 3 location下存在`Video Streaming@1` interface；其下已有系統AVFoundation/UVCAssistant framework client。這是目前真正的VS ownership狀態，不是descriptor猜測。direct backend因此必須先完成AVFoundation stop、delegate解除與frame queue drain，才可嘗試一般owned VS access；不得與現有client並行、不得seize interface。本檢查沒有開interface、pipe或control request，也沒有中斷取像。

新增`pocket3 uvc-stream-interfaces 0x01100000`只讀CLI已在真機回傳VC interface 0與VS interface 1，兩者alternate setting為0、各宣告一個endpoint；不存在的location回傳`deviceFound=false`與空interface清單。它只呼叫IORegistry property/child traversal，不建立UVCController或interface plugin，也沒有中斷取像。[真機inventory](../artifacts/hardware-complete-2026-09-11/uvc-stream-interfaces-live.json)、[不存在位置反例](../artifacts/hardware-complete-2026-09-11/uvc-stream-interfaces-missing.json)
