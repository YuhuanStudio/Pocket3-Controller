# Pocket 3 direct UVC H.264 backend

更新：2026-09-11。這是 `2vuy host path` 零 callback 之後的實作規格，不是已完成支援。只使用公開 macOS API；不連結 `UVCFamily` 等 private framework，不使用 seize/device-capture，也不與 AVFoundation／OBS 同時讀取 VideoStreaming endpoint。

## 已確認的裝置拓撲

Pocket 3 `0x2ca3:0x0023` 為 UVC 1.00：VideoControl interface 0、VideoStreaming interface 1，bulk IN endpoint `0x82`、max packet 512 bytes，沒有 VS isoch alternate settings。format 2 是 frame-based H.264：1920×1080與1080×1920支援24/25/30 fps；3840×2160支援24/25/30/48/50/60 fps。完整固定描述見 `artifacts/usb-all-descriptors-2026-09-09.json`。

現有 `Pocket3UVC` 只開啟 VC interface 0並做EP0相機控制，沒有VS interface、pipe讀取、PROBE/COMMIT、payload組裝或解碼。build25 scalar診斷已證明：AVFoundation選到active `2vuy`，session/device/connection均active，但input port仍為`420v`且零sample。因此VideoToolbox不能直接接在既有callback後面。

## Ownership與生命週期

direct backend啟動前必須停止AVFoundation、移除delegate／graph並排空frame queue，再以一般owned open取得VS interface 1。`kIOReturnExclusiveAccess`一律回明確busy；不把borrowed interface當stream可用，不呼叫`USBInterfaceOpenSeize`。direct reader完整釋放pipe/interface/object後，才能重啟AVFoundation。

首選macOS 27公開`IOUSBHostInterface`／`IOUSBHostPipe`，使用一般init options、serial queue、alt 0與多個有界async bulk requests；Legacy `IOUSBLib`只作隔離fallback。App目前沒有USB entitlement，不虛構未文件化 entitlement；sandbox、hardened runtime與實際distribution signing需獨立驗證。

## UVC 1.0 negotiation

只使用26-byte VS control block：`bmHint(2), format(1), frame(1), interval(4), key rate(2), P rate(2), quality(2), window(2), delay(2), max frame size(4), max payload size(4)`。interface固定1：

1. `GET_MAX PROBE`：`a1/83/0100/0001/26`
2. `SET_CUR PROBE`：`21/01/0100/0001/26`
3. `GET_CUR PROBE`：`a1/81/0100/0001/26`
4. `SET_CUR COMMIT`：`21/01/0200/0001/26`

回覆的format/frame/interval必須與固定descriptor entry一致，所有size有獨立上限；不送UVC 1.1/1.5的34/48-byte block。

## Payload、NAL與VideoToolbox

每次bulk completion視為一個UVC payload。header byte0是長度、byte1是flags；依旗標解析PTS 4 bytes與SCR 6 bytes。ERR、header錯誤、detach或accumulator overflow會丟棄access unit。EOF完成frame；FID翻轉時，即使前一frame缺EOF，也只發布非空且有效的前一單元。不在H.264 payload任意搜尋第二個UVC header。

組裝器接受嚴格Annex B或validated AVCC，正規化為4-byte big-endian length-prefixed NAL。快取SPS type7、PPS type8；loss或parameter-set變更後等待IDR type5。以`CMVideoFormatDescriptionCreateFromH264ParameterSets`、`CMSampleBufferCreateReady`與`VTDecompressionSession`輸出BGRA。第一階段同步解1080p30；後續才增加有界async queue。停止時wait async frames、invalidate並釋放。

decoded buffer沿用`FrameStore`與`CaptureCallbackFence`，generation不符就丟棄；metadata另記wire FourCC `H264`與direct timestamp source。既有`AVCaptureVideoPreviewLayer`不能顯示direct buffer，需獨立pixel-buffer preview adapter。direct mode下tap AF保持不可用，直到控制路徑另有證據。

## 實作與驗收階段

目前進度：第1階段的純資料模組已完成，包含26-byte negotiation codec／固定mode catalog、UVC payload與access-unit assembler、H.264 Annex-B／AVCC normalizer及parameter-set／IDR readiness。另已加入HEVC Annex-B／HVCC、VPS/SPS/PPS＋IRAP readiness，及H.264/HEVC共用的同步VideoToolbox decoder foundation。AVFoundation↔direct ownership reducer亦已完成，要求AVF stop＋queue drain後才能取得direct owner，且direct pipe/interface/object全釋放後才能重啟AVF。本機合成HEVC MP4已經實際經App影片import seek解成BGRA；合成BGRA亦已經分別完成VTCompressionSession H.264與HEVC encode→新decoder BGRA roundtrip。

第一個真實VS lifecycle診斷已加入：`uvc-stream-open-diagnostic`僅以一般`USBInterfaceOpen`嘗試VS interface 1，成功就立刻close，不會seize、改alternate setting、發UVC request或讀pipe。2026-09-11在沒有本App AVFoundation capture時，Pocket 3回`busy`（open `-536870203`），因此沒有取得endpoint或開始stream。這是現有macOS UVC client ownership的明確邊界；下一步是以App的AVFoundation stop/drain evidence觸發一次受控handoff，不能在busy狀態繼續嘗試或使用seize。

macOS SDK查核後已撤回「App首選IOUSBHostInterface」的假設：該類別是kernel/DriverKit function-driver API，不能作為一般App的user-space替代。可行的立即路徑是`AVCaptureVideoDataOutput`的H.264 encoded-output：build25以`POCKET3_CAPTURE_OUTPUT=h264`實測1080p30，782個`avc1` block-buffer samples經`AVC1SampleAdapter`複製SPS/PPS/AVCC access unit，再由既有VideoToolbox decoder交回1920×1080 BGRA FrameStore，10秒後28.45fps、零runtime error；pause後frames歸零。這是host轉碼輸出，不宣稱input `420v`或USB wire為H.264，也不等同direct VS ownership。

同一路徑已實測4K30：283個`avc1` block-buffer samples交回3840×2160 BGRA，29.11fps、零runtime error，之後明確pause。這是第一個可用的4K H.264 host-output preview path；4K48/50/60、直幅與長時間記憶體／停止恢復仍須各自驗收。

直幅1080×1920@30同樣可交回正確尺寸BGRA，231個`avc1` samples、零runtime error，但即時速率僅23.74fps；因此它目前只證明H.264 decoder與直幅尺寸路徑，**不**通過30fps性能門檻。需分析VideoToolbox同步decode背壓後，才能提升為直幅30fps支援。

後續720×1280@30測得174個H.264 samples、約14.00fps；decode平均4.38ms、最大76.78ms、零decode failure。平均decode成本遠低於33ms，所以這輪瓶頸是AVFoundation H.264 encoded-output供給率而非同步decoder。H.264 fallback維持可用，但直幅30fps仍應採既有NV12/BGRA preview；診斷會分開呈現sample rate與decode耗時，不能用async queue假裝補足遺失輸入。

4K60實測仍不成立：裝置不宣告NV12 input；以其宣告的UYVY/H.264 input加上H.264 host-output policy嘗試15秒後仍是0 sample、0 runtime error、0 decode。這表示callback未到達decoder，不以4K30成果外推至4K60。

1. 純資料：descriptor selection、26-byte control、UVC payload、FID/EOF/loss、Annex B/AVCC與SPS/PPS/IDR測試。
2. raw transport：只取得VS ownership與scalar diagnostics；busy、拔除、timeout、取消、cleanup必須通過。
3. 同步1080p30 VideoToolbox→FrameStore；不保存畫面，先驗尺寸/FPS/freshness/memory bounds。
4. 1080×1920與4K30，再驗方向／內容；最後才是4K48/50/60。
5. async decode、direct preview、App source選擇、MCP read-only整合與AVFoundation往返恢復。

任何階段都不能以descriptor、PROBE ACK、NAL bytes或單張decoded frame替代完整串流、ownership、取消、恢復與封裝驗收。

目前descriptor selection已落地為純UVC configuration decoder：可辨識interface class 14/subclass 1 VC、subclass 2 VS、alternate setting、endpoint address／direction／transfer type／max packet，以及MJPEG/H.264 class-specific format subtype。這層只處理bytes，不讀IORegistry、更不開interface或pipe。

第17批新增公開API邊界內的Direct UVC session foundation：由descriptor inventory選出VC／VS與bulk-IN endpoint，固定建立四步26-byteH.264 PROBE／COMMIT交易，並以generation-safe coordinator要求AVFoundation stop＋queue drain後才能單次acquire；取消、失敗與release均歸還ownership。transport與handle仍為injectable，`bulkReadReady=false`，所以這只證明planner／negotiation／ownership生命週期，尚未取得真實VS interface、pipe bytes或decoded frame。下一硬體gate仍是normal open、不seize的單次VS handoff。
