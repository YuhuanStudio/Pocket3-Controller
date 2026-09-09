# Pocket 3 實機驗收

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

2026-09-08 使用者已恢復 Pocket 3，實機驗收正在進行。韌體由使用者在機身確認：主韌體 `01.06.10.04`、相機 `10.00.50.51`、雲台 `01.00.15.81`。

**2026-09-09更新：** 公開beta1為build9；後續build11新增Zoom途中Stop讀回成功及BLE lens連續觀察，詳細條件見本文件末段。第一輪機身點按有轉向干擾，第二輪操作順序仍待確認，兩者均不當作完整AF或座標校準。下方較早日期的失敗、測試範圍與限制保留，不是目前功能清單。

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
