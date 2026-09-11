# Pocket 3 Controller — 當前待辦

更新：2026-09-11。完整目標仍是 `BUILD_PROPOSAL.md` 的 1.0 App＋MCP＋CLI，尚未完成。**Pocket 3 Controller 0.0.1 beta 2（build 24）已發布**；main 的 build25 已完成 USB 1080p30 與 BLE 唯讀狀態／九類設定基線。原生快速預設、點按對焦、ActiveTrack host control、設定寫入、完整格式與全範圍物理驗收仍未完成。各版本的證據分開記錄，不把舊版通過套用到新版。

## 相機關閉期間：軟體與 AI

- [x] 專案目錄統一為 `Pocket3-Controller`，Git linked worktrees 修復；保留依賴並重建含舊絕對路徑的編譯輸出，原簽署身分可用。
- [x] 雲台驗證 v5 原始碼採失敗即停止、共用寫入 permit、部分報告及嚴格型別／範圍／完整序列判定；16項離線驗證器測試通過，未做 v5 真機驗收。
- [x] [AI 深度研究](docs/AI_RESEARCH.md) 整理 macOS27、MLX／VLM／VLA、追蹤與產品架構；已找到權限導致不必要雙模型流程及自由文字座標契約問題。
- [x] 新增只讀匯入圖片 typed 計數／定位／存在性評测 API；8項純回歸通過，不提供相機動作。合計492項Release測試通過、3項opt-in跳過。
- [x] [公開資料評測](Evaluation/Grounding/README.md) 的6張照片／18題metadata、來源／授權／SHA與獨立評分器已可重現，照片不進repo或App。
- [x] build21完成同圖同題36次typed推論：Apple6/18、MLX14/18；這是小型契約／語意回歸集，非通用模型排名。[不含照片的結果](Evaluation/Grounding/results/build21-typed.json)
- [x] build21新路徑完整軟體gate通過：492項Release、59張UI、三語與7個Yun共用設計檔、搬移App後實際MLX/CoreAI推論、ZIP/DMG簽署和payload。[本輪封存](artifacts/offline-build21/final/verification-gate.json)
- [x] build22修正模型nil表示並完成相同36次重測：Apple12/18，MLX14/18；Apple六題不存在目標均回空位置。MLX仍有3次host拒絕，不能當成視覺幻覺；單圖pilot亦顯示輸出有變動，不能宣稱全面穩定。[結果](Evaluation/Grounding/results/build22-typed.json)
- [x] build22離線照片工作區：開啟／替換圖片、問答、計數、模型定位、OCR、取消／舊結果隔離與三語介面。真App流程通過，使用合成圖；相機仍0影格、session與access未變。[流程](artifacts/image-workspace/build22/result.json)
- [x] build23觀察／協助取景真機分流：全域為control時，MLX observe只用只讀文字工具，pan／tilt／zoom均未變；assistFraming才執行zoom status→set raw110，獨立讀回109符合±1 step，之後確認恢復100／manual／同session。Apple真機observe本次被系統安全護欄拒絕，cleanup通過；不把單次縮放當完整雲台驗收。[純觀察](artifacts/hardware-build23/mlx-observe-intent-summary.json)、[協助取景](artifacts/hardware-build23/mlx-assist-zoom-summary.json)
- [x] build22完整gate與安裝：503項執行通過、3項opt-in跳過；59張UI、3語、7個Yun共用設計檔、搬移後MLX/CoreAI推論、ZIP/DMG驗證通過。另6項照片workspace回歸包含真實RootView隱私／marker渲染；3張照片工作區公開UI已逐張看過，所有圖片內容與分析均隱去。[gate](artifacts/offline-workspace-build22/final/verification-gate.json)、[安裝](artifacts/offline-workspace-build22/installed.json)、[公開截圖manifest](docs/images/image-workspace-build22.json)
- [x] build23媒體工作區：本機影片時間點、實際PTS與方向、VFR／長hold／GOP邊界、ROI拖選裁切／標記映回、JSON／Markdown不可變結果匯出。真App以合成圖片與影片完成MLX ROI計數、Vision OCR、Apple影片影格回答、匯出、快速seek取消與三語隱私截圖；相機狀態在離線gate維持零影格不變。[流程](artifacts/media-workspace-gate-1789044947/result.json)
- [x] build23完整gate與安裝：534項執行通過、3項opt-in跳過；59張UI、三語、7個Yun共用設計檔、搬移App後MLX/CoreAI推論、ZIP/DMG與簽章通過。已安裝與gate相同的build23。[gate](artifacts/offline-media-build23/final/verification-gate.json)、[截圖manifest](docs/images/media-workspace-build23.json)、[安裝](artifacts/offline-media-build23/installed.json)
- [x] build25 唯讀硬體基線：`02/80` camera status、`02/DC` storage、九類 named properties、未知 raw 值、被動 tracking candidates、BLE identity 邊界與 UVC transient-read resilience 已實作；目前來源完整Release tests 648次零失敗，USB 1080p30、BLE pairing/status/settings 已實測。[支援矩陣](docs/POCKET3_SUPPORT_MATRIX.md)、[真機紀錄](docs/HARDWARE_ACCEPTANCE.md)
- [x] build25 metrics-only NV12 矩陣：10秒暖機後13個實際橫幅／直幅模式全部通過尺寸、FourCC、BGRA、新影格、freshness、session與FPS；不保存畫面，故內容方向與黑邊仍另待視覺驗收。[結果](artifacts/hardware-complete-2026-09-11/build25-nv12-matrix-warm/51a6c591-668e-4474-bf39-7a3edcfd9901/result.json)
- [ ] build25 UYVY 代表重測：1080p30與4K60均 `no_frame`，各種 sample count為0且無 runtime/interruption；沒有自動重試。需先補 negotiation 診斷或替代 transport，不能把 advertised `2vuy` 當支援。[結果](artifacts/hardware-complete-2026-09-11/build25-uyvy-representative/a7abb20c-e58e-4c64-9d3c-b961cc5fd999/result.json)
- [x] build25 scalar negotiation 診斷：2vuy 1080p30顯示active format正確、session/connection/device均active，但input port仍是420v且callback timeout/no sample；格式UI已分清host subtype與MJPEG/H.264 UVC路徑。[結果](artifacts/hardware-complete-2026-09-11/build25-uyvy-negotiation/6eae14d5-2d58-4077-a08b-be83852571b0/result.json)
- [ ] 依[direct UVC H.264規格](docs/DIRECT_UVC_H264_PLAN.md)逐階段實作公開API backend：純parser/control→VS ownership→同步1080p30 VT decode→直幅／4K→async preview與App整合；不得與AVFoundation／OBS爭用endpoint。
- [x] build25 ActiveTrack被動camera-event recorder：exact paired peer/session、Camera→App set02、20秒／512筆／128-byte payload、per-command sequence、SHA-256去重、取消／斷線與120秒IPC timeout均已實作；完全不送命令。
- [ ] ActiveTrack live事件差異：使用者已澄清自動追蹤在這些窗口一直關閉；舊候選為空只是一輪off-baseline。換新build時三次GATT subscribe timeout，候選仍有廣播，但不能把timeout歸因於追蹤。需在新版已arm window內，由使用者明確切換off/on並記錄時點後重測，不能把空候選當不支援。
- [x] 第一輪已arm的ActiveTrack窗口完成：148筆只有不變的`02/80`與`02/DC`，候選89/A5/A6及pose mode/limit均未變；使用者後續澄清當時追蹤一直關閉，因此它只構成off-baseline。recorder已擴到Camera＋Gimbal route並改為只保留payload變化，仍待新版受控off/on重測。[事件](artifacts/hardware-complete-2026-09-11/activetrack-window-1.json)
- [x] direct UVC H.264 stage1純資料層：26-byte UVC1.0 PROBE/COMMIT與descriptor catalog、UVC bulk header/FID/EOF/PTS/SCR assembler、Annex-B/AVCC normalizer及SPS/PPS/IDR readiness均已實作；不含I/O或decode成功宣稱。
- [x] build25 camera-side H.264／HEVC developer writer：`02/AB 0000/0100`、完整`cam_video_param_v2` baseline、單次送出、no-op零寫入、ACK＋matching readback與3秒窗口已實作；它是待驗證的DUML candidate，且不冒稱USB HEVC。
- [x] HEVC真機no-op驗證：新版App的USB 1080p30、BLE配對、完整property readback均成功；目前HEVC raw=1，結果為`noOp=true/localSubmitted=false/end=noOp`，未送設定寫入也未保存畫面。[結果](artifacts/hardware-complete-2026-09-11/hevc-noop-latest/71db2e95-04d1-4d97-9b27-c232deae7fa0/result.json)
- [x] H.264↔HEVC controlled round-trip驗證器：`Scripts/validate-video-compression-roundtrip.py`預設dry-run；唯有`--execute`才容許一次H.264切換和一次回復。每次寫入需ACK＋matching readback；切換後先以獨立唯讀query確認H.264才回復原始完整baseline。若切換提交後逾時，先唯讀確認，只有實際讀到H.264才作一次回復，絕不盲寫或重試。實機第一次HEVC→H.264提交後沒有ACK或matching readback，五筆後續值仍是HEVC，failure query亦為HEVC，故沒有回復寫入或重試；此writer尚不可用。[結果](artifacts/hardware-complete-2026-09-11/hevc-roundtrip-latest/d3459613-764c-4b04-b577-c553febf8d3a/result.json)
- [x] codec capability唯讀基礎：新增`camcap_video_codec`與`camcap_video_format`的opaque、bounded read-only query，未知欄位不會推論成codec或setter。實機`camcap_video_codec` query完整等候後無payload；後續新BLE session的`camcap_video_format`訂閱收到ACK但2秒內仍無payload。兩者都不是不支援結論，且未改變相機設定。
- [x] direct UVC VS descriptor foundation：純decoder可從configuration descriptors辨識VC/VS interface、alternate setting、bulk IN endpoint、MJPEG/H.264 format並拒絕malformed資料；不開interface或pipe。
- [x] direct UVC真機只讀inventory：IORegistry確認`Video Streaming@1`及既有AVFoundation/UVCAssistant client；ownership policy的停止AVF→acquire VS邊界已有硬體topology依據，尚未claim interface。
- [x] `uvc-stream-interfaces` CLI：真機確認VC0/VS1/alt0/endpoints，缺失location明確回空；僅IORegistry讀取，無UVC controller/interface/pipe操作。
- [x] direct UVC VS一般open診斷：`uvc-stream-open-diagnostic`只做一般open後立即close，絕不seize／改alt／送request／讀pipe。真機VS1回`busy`（`-536870203`），故無endpoint與stream取得；這是受控handoff待做的ownership evidence，不代表H.264不可用。
- [x] AVFoundation H.264 encoded-output fallback：`avc1` block buffer嚴格抽取SPS/PPS、4-byte AVCC與CM timing，再透過既有VideoToolbox decoder輸出BGRA；參數集／尺寸改變會重建decoder，stop會invalidate。合成avc1→BGRA roundtrip通過；真機1080p30 782 samples／28.45fps／零runtime error、pause後0 frames，不保存畫面。這是host output，不是direct VS或USB H.264 wire claim。
- [x] H.264 host-output 4K30：相同fallback真機取得283個`avc1` samples並輸出3840×2160 BGRA，29.11fps、零runtime error，後續pause。4K高幀率與直幅不由此宣稱已通過。
- [x] H.264 host-output產品選項：App與設定頁分開呈現USB輸入格式與預覽輸出，預設BGRA、可選實驗性H.264 host output並持久化；Service status回報requested/active policy。新版無環境變數實機透過明確`h264` policy取得169個decoded avc1 frames；公開UI擷取不含預覽內容且已檢視。
- [x] 背景／遠端 bridge：`--background-bridge`在已登入session隱藏Dock／主視窗但保留IPC/MCP與選單列；一般CLI新增explicit `connect`／`pause`，實機背景模式1080p30 NV12/BGRA達29.21fps，pause後0 frames。它不支援pre-login daemon、不改TCC、不加入Wi-Fi或提升control權限。
- [x] 背景 MCP capture：MCP stdio `initialize`／`tools/list`實測包含`camera_connect`與`camera_pause`；兩者走同一service capture contract，保留manual access且不提供Wi-Fi／native BLE控制。
- [x] 背景 MCP capture end-to-end：實際MCP JSON-RPC `camera_connect`在1080p30 NV12/BGRA取得128 frames／31.47fps，後續`camera_pause`回paused／0 frames；沒有透過CLI代理。
- [ ] H.264 host-output直幅性能：1080×1920為23.74fps；720×1280為14.00fps，雖有174個samples／零decode failure且平均decode僅4.38ms，瓶頸在AVFoundation encoded-output供給率，非同步decoder。直幅30fps維持NV12/BGRA；H.264 output不可標為30fps支援。
- [ ] 4K60 host capture：NV12未宣告；UYVY/H.264 input加host H.264 output仍0 sample／0 runtime error，不能以4K30標成4K60可用。需新的可合法交付callback的transport，decoder不在此輪資料路徑上。
- [x] HEVC/H.265 decode foundation：Annex-B／HVCC、VPS/SPS/PPS、IRAP16…23、loss/reset/parameter-change及有界cache已完成；共用VideoToolbox decoder只接受canonical H.264或HEVC parameter sets及4-byte length access unit，輸出BGRA並有generation fence。尚未以實際encoded frame完成decode驗收。
- [x] Pocket 3 AVFoundation HEVC host-output capability：1080p30 NV12實機列出`avc1`、`jpeg`，沒有`hvc1`；要求`hevc`會在開始取像前以`output_codec_unavailable`拒絕，沒有callback、影格、設定寫入或重試。隨後BGRA取得1 frame並privacy pause回0。這是此host輸出路徑的負能力證據，不否定機身目前HEVC錄影設定。[結果](artifacts/hardware-complete-2026-09-11/hevc-host-output-avfoundation-1080p30.json)
- [x] HEVC本機影片實際驗收：合成HEVC MP4經`ImportedVideoSource`實際seek、解碼為BGRA並核對像素內容；不使用Pocket 3、網路或持久素材。direct UVC HEVC仍不成立，因descriptor未宣告HEVC。
- [x] AVFoundation↔direct capture ownership policy：stop＋frame queue drain、direct exclusive acquire/release、AVF restart證據與generation permit已完成純狀態機及actor tests；尚未接真實VS transport。
- [x] H.264 VideoToolbox實際roundtrip：合成64×48 BGRA像素經本機VTCompressionSession壓成H.264，提取SPS/PPS與4-byte access unit後由新decoder同步解回BGRA，尺寸與generation通過；沒有Pocket 3、USB、檔案或網路。
- [x] HEVC/H.265 VideoToolbox實際roundtrip：相同合成BGRA經HEVC encoder壓縮，提取VPS/SPS/PPS與4-byte access unit後由新decoder同步解回BGRA；不依賴Pocket 3 USB descriptor。
- [ ] 構圖幾何、短期追蹤／場景事件時間軸、影片多影格比較；已新增privacy-preserving BGRA frame comparison並接入MCP `camera_compare_frames`（同session兩fresh frames、scalar差異、零像素持久化）及本機video workspace `Compare +1 s`（seek/replace/cancel revision fence）。實機frame10→11間隔44ms／51840 samples通過；合成影片 IPC gate 也通過0.25→1.25秒、38520 samples、mean absolute luma difference 16.99，且相機維持idle。本機影片已新增最多八個相鄰一秒、scalar-only scene timeline，synthetic IPC gate通過；尚待語義 scene event／連續影片理解。
- [ ] 同題集比較另一個模型家族與2B／9B成本品質；量冷／暖延遲、影像大小、App記憶體與卸載，不以模型卡分數代替本機結果。
- [x] CoreAI packaged Release perception baseline：同一合成 COCO fixture、每個 compute request 1 cold + 5 warm trials，CPU／GPU／Neural Engine request／automatic 的 warm median 分別為58.53／31.75／30.51／31.54 ms，物件清理輸出一致（2 cats、2 remotes、1 bed）。這是 request-level performance，不是 ANE execution proof；沒有相機輸入或影像保存。[結果](artifacts/evaluation/perception-release-20260912/results.json)
- [x] CoreAI execution trace recorder：`Scripts/record-coreai-trace.py`會 attach packaged App、執行離線 perception、輸出 Core AI trace schema與ANE/MPS/Metal row counts。此機 neuralEngine request 的12秒 trace成功但三種interval均0，結果明確為`inconclusive`，不據此聲稱ANE或fallback；沒有相機、BLE、網路或媒體。[結果](artifacts/evaluation/coreai-trace-20260912-neural/result.json)
- [ ] CoreAI Qwen3-VL recipe的小型數值一致性／前處理實驗，實測計算單元後才宣稱ANE；VLA示範資料與離線policy仍屬研究，不直接取代控制器。

## beta 1 發布與整理

- [x] beta 2 build24已發布：exact-source完整gate、beta1→candidate實際Sparkle更新安裝、annotated tag、GitHub prerelease四項資產、未登入公開下載hash、公開Ed25519 feed／ZIP驗簽及signed appcast均通過；beta1 tag與資產未移動。[Release](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.2)、[公開驗證摘要](docs/releases/0.0.1-beta.2-verification.json)

- [x] 使用者選定產品名稱 Pocket 3 Controller、GitHub 儲存庫名稱 `YuhuanStudio/Pocket3-Controller`；內部 bundle ID、簽署身分與設定沿用。
- [x] build 8 完整軟體 gate：397 項 Release 測試、59 張 UI、三語／Yun 共用設計、搬移後模型推論、更新簽章、ZIP／DMG 驗證通過。[本版 gate](artifacts/beta1-2026-09-09/software/artifacts/verification-gate.json)
- [x] build 8 真機基本流程：1920×1080 NV12 新影格、實際按鈕放開、pan 0→7920→−360（容差1080）、zoom 100→110目標（讀回109，容差1）→100、隱私暫停及新 session 重連通過，final Stop verified。[結果](artifacts/beta1-2026-09-09/hardware-smoke/result.json)。不涵蓋移動中 Zoom Stop、完整視角或原生預設。
- [x] 第一批已清理 155 個舊測試照片／截圖（31,326,669 bytes），保存原始 JSON、log、媒體 hash 及刪除清單；必要模型 fixtures 和當前 UI 複核截圖保留。[政策與 receipt](docs/TEST_ARTIFACTS.md)
- [x] 已對照 YunAudio 並落地純本機 Release 預備工具、資產白名單、checksums／notes／draft argv；9 項離線測試通過。[發布流程](docs/RELEASE.md)
- [x] 已取得發布授權，建立獨立 Sparkle Keychain account 與公開更新設定，保留私鑰於 Keychain。
- [x] 公開 build 9：乾淨來源 commit／tag、完整 gate、GitHub prerelease、四項資產公開下載、signed feed／ZIP 公鑰驗證已完成。[Release](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1)
- [x] 正式 Beta feed 已完成 Keychain 簽署與公開發布；重新取得的公開 feed／ZIP 經 CryptoKit 與本專案 Ed25519 公鑰驗證，`feedVerified=true`、`archiveVerified=true`。[公開簽章驗證](artifacts/public-beta1/public-signature-verification.json)。此項不包含跨版本安裝／重啟。
- [x] 三語 README／文件索引／使用指南與九張排除取景照片的 UI 圖已完成，圖片與公開下載版本分別標明。[公開呈現清單](docs/RELEASE_PRESENTATION_CHECKLIST.md)
- [x] beta 2 build 11 版面修正：AI卡等高與控制列齊、MCP長路徑、設定長標籤與更新列、權限圖示、診斷卡、音訊動態本地化；三語、兩種視窗尺寸已逐張視覺檢查，完整回歸測試另記。
- [x] beta1→beta2 已以隔離正式 App 副本完成真正 archive 下載、替換、重啟、新 PID／IPC、偏好保存與 cleanup；公開 feed／ZIP 另以公開金鑰驗證。Developer ID／公證仍未完成。[beta2驗證](docs/releases/0.0.1-beta.2-verification.json)

## 本輪真機 AI、設定與完整配對

- [x] **build16混合流程真機通過**：MLX執行4個模型工具／單次raw200，App另取一次較新的影格，Apple回答；38.039秒、11項檢查通過，`executionRoles`明示`mlx / apple / app`，之後恢復100及manual。這不代表Apple模型獨立完成控制。[結果](artifacts/live-ai-2026-09-09/hybrid-build16-c7cf0025-cc5e-4b3a-b4fa-c0b684493ecd/result.json)
- [x] 移除未可靠運作的Apple文字計畫實驗，保留取消／新影格／單一控制者檢查；UI顯示角色分工，縮放紀錄不再誤標成擷取圖片。build16共454項、build17共459項Release測試通過。[build16](artifacts/hybrid-ai-build16/release-tests.log)、[build17](artifacts/native-baseline-build17/release-tests.log)
- [x] build16的12張介面圖已逐張檢視，包含三語相機大／小視窗、引擎與外觀；九張公開圖更新，無感測器畫面或私人路徑。[視覺紀錄](artifacts/hybrid-ui-build16/visual-review.json)、[公開圖片manifest](docs/images/manifest.json)
- [x] build18完整配對下，新3秒基線取得窗口已實測：6筆／0.573秒穩定，FE08單次真正提交。Stop原1.5秒限制與基線品質門檻保持；原生功能是否生效另列下方。[本輪結果](artifacts/native-fullpair-build18/native-recenter.json)

- [x] **MLX真機觀察／縮放任務通過**：34.111秒，實際工具順序`capture_frame → camera_zoom_status → camera_set_zoom(raw200) → capture_frame`；只有一次縮放，回讀verified、動作後及最終影格來自真實裝置／同session。之後恢復raw100及manual，cleanup確認。[結果](artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/result.json)、[工具與影格](artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/observation.stdout.json)
- [x] 該次MLX卸載後cache為0、active為4036 bytes；只描述MLX配置器，不寫成記憶體完全歸零或App RSS歸零。[卸載後](artifacts/live-ai-2026-09-09/mlx-d5612d23-b713-489d-a189-acade9b63f66/after-model-unload.json)
- Apple原始流程及文字計畫的三份失敗保留：build13 `actions=[]`、build14錯拒合法raw200、build15錯拒raw150，均未縮放。後續改由MLX負責控制、Apple負責回答，通過範圍見上列混合流程。[build13](artifacts/live-ai-2026-09-09/apple-6a154bec-4fd6-410d-b486-25a41b7abb21/result.json)、[build14](artifacts/live-ai-2026-09-09/apple-plan-15eb7103-ea06-41b9-8672-a8ef120d59a3/result.json)、[build15](artifacts/live-ai-2026-09-09/apple-build15-explicit-7d730d99-86c1-40b4-a1df-3da430989fbc/result.json)
- [x] 三份獨立Apple計畫提取結果與來源／instructions hash已保存；此為模型提取診斷，不是額外硬體成功。[來源紀錄](artifacts/apple-plan-extraction-2026-09-09/source-provenance.json)、[自然語句](artifacts/apple-plan-extraction-2026-09-09/current-natural.json)、[明確raw150](artifacts/apple-plan-extraction-2026-09-09/current-raw150.json)、[另一schema對照](artifacts/apple-plan-extraction-2026-09-09/associated-raw150.json)
- [x] 完整配對已到`credentialsReady`，且`samePrimaryRoute=true`、沒有呼叫Mac Wi-Fi join；只記錄狀態，不輸出密碼。[配對](artifacts/full-pair-control-2026-09-09/paired.json)、[網路核對](artifacts/full-pair-control-2026-09-09/network-check.json)
- [ ] **WB writer仍未生效**：pairOnly/build14與完整配對/build15各只送一次5600K，分別7／6筆回報仍Auto、都無ACK及matching readback，`applied=false`。原Auto未變，沒有restore寫入，也沒有盲重試。[pairOnly](artifacts/camera-settings-live-2026-09-09/white-balance-129a5c24-0e92-4fd2-acce-9596ce96fb68/result.json)、[full pair](artifacts/full-pair-control-2026-09-09/white-balance-43db759b-752c-4983-be27-ebbd04da92ae/result.json)
- [x] 使用者開啟視窗後，UI檢查`animationVerified=true`，可見manual button放開流程通過，pan由0到11880；不把先前screenUnavailable下的offset timeout當控制功能成功。[解鎖UI](artifacts/full-pair-control-2026-09-09/ui-check-after-user-open.json)、[手動操作](artifacts/full-pair-control-2026-09-09/manual-button-release-unlocked.json)
- [ ] 完整配對下FE08仍未確認可用：build18單次提交後3秒、27筆姿態均未變，無ACK；USB pan−14040／tilt6120前後相同，cleanup verified。這次已排除「未取得基線所以沒送出」，不再以相同條件重播。FE09仍沒有獨立成功證據。[本輪結果](artifacts/native-fullpair-build18/native-recenter.json)

## 相機重新開啟後的新證據

- [x] 恢復1080×1920@30 NV12，Roll原始值0→1→0有精確穩定回讀、不同的新影格與恢復結果。[單步實測](artifacts/hardware-roll-2026-09-09/one-step/result.json)
- [ ] Roll移動中停止、物理方向／角度與獨立AI驗證仍未完成；`rollStopValidated`不由Pan/Tilt或靜止保持自動開啟。
- [x] Roll metrics-only raw baseline：0→1→0精確readback、兩次Stop verified、manual cleanup完成且零影像輸出。這證明setter/readback/restore，不解除moving-stop、物理方向或angle calibration gate。
- [x] 不改Mac網路，重新配對同一BLE peer，取得電池100%／未充電及新鮮姿態。[遙測](artifacts/hardware-roll-2026-09-09/live-telemetry.json)
- [x] BLE `00/99`只讀通道取得實際相機回覆：AF-C、WB Auto、曝光Auto／EV0。[三項查詢](artifacts/hardware-roll-2026-09-09/properties/result.json)
- [x] 一般面板的只讀設定／讀取按鈕及5秒過期處理已完成，build 7 軟體 gate 和三項實機讀值通過。
- [x] BLE lens 只讀連續觀察已取得基線31筆／12.009秒，以及兩輪機身操作期間的37／35筆候選座標；未發送相機設定寫入或保存照片。[基線](artifacts/focus-live-2026-09-09/baseline-summary.json)、[本輪紀錄](docs/HARDWARE_ACCEPTANCE.md#2026-09-09-ble-lens-連續讀回與機身操作)
- [ ] 完成機身實際點按順序與 lens 座標的關聯驗證。第一輪使用者回報只點左上／右下、但誤觸鏡頭轉向，屬 confounded，不能解讀中途返回中心的原因；第二輪35筆、USB pan／tilt span均0，但實際操作順序仍待使用者確認。這些讀回不表示完整座標校準、App tap AF或光學合焦已完成。[第一輪條件](artifacts/focus-live-2026-09-09/body-tap/context.json)、[第二輪摘要](artifacts/focus-live-2026-09-09/axis-taps-7a14c2a3-c7fa-4c8f-b70e-e7c21c8b7c60/summary.json)
- [x] build13開發用BLE點選序列、每步800ms ACK／傳送額度等待與取消已實作；429項Release回歸通過，7個共用設計檔及三語檢查通過。[測試](artifacts/tap-focus-build13/release-tests.log)、[設計契約](artifacts/tap-focus-build13/design-contract.json)
- [x] 傳送額度等待已在真機生效：Prepare後等待10.472ms，再各一次提交Point；未重送Prepare。build12原先只送第一步便中止的結果保留。[build13結果](artifacts/focus-live-2026-09-09/tap-write-c80067c8-c513-4025-9545-332ba1ea889e/summary.json)
- [ ] BLE Tap AF仍未確認生效：本次Point 800ms內無ACK，Hint／Commit未送；期間2筆及稍後獨立12秒的30筆座標仍約中心，AF-C／Auto EV0保持。一般GUI不據此開啟；不以相同條件盲重送，下一步需查明Camera命令路由或可用的其他傳輸。
- [x] 公開beta1的橫幅NV12補驗：720p30、1080p24、4K30均取得新影格；1080p30另有本版smoke。這是已完成的子矩陣，不覆蓋所有格式、方向／黑邊或後續candidate。[矩陣](artifacts/public-beta1/nv12-landscape-matrix/b765fe71-749f-4261-a966-126179c87fea/result.json)、[build9 smoke](artifacts/public-beta1/hardware-smoke/result.json)
- [x] 直幅 privacy-preserving edge metrics：1080×1920 NV12/BGRA不保存影像下，top/bottom dark fraction=1.0、left/right=0.683，量化出強烈黑邊訊號；相機卡的保守warning已以不含preview的實際UI render檢查。這不是內容方向、構圖或機身姿態正確性判定。
- [x] 最新 USB audio metrics：1080p30短期20.90秒、48kHz stereo／2 channels、約30fps、零failure；只保存scalar metrics。這不替代30分鐘影音acceptance或機內音訊設定控制。
- [x] 最新完整 USB audiovisual acceptance：1080p30＋48kHz stereo持續1,800.91秒、1,720 sample、零failure；最終29.97fps、frame age 0.0038s、resident 329.6MB，pause後0 frames。只保存scalar metrics，不替代機內audio setter或其他格式組合。

目前可用主路徑是 **USB 取像＋USB 按住／拖曳位置控制**。Mac 必須保留原有網路與網際網路連線；App 不要求加入相機 Wi-Fi，開發 join RPC 亦拒絕該操作。BLE 配對、電池與姿態有實測證據，原生馬達控制及快速預設仍未完成。速度拉條已移除；拖曳距離控制輸入幅度，UVC raw 速率不宣稱為校準物理速度。

## 歷史 build 5：電量提醒與只讀姿態

- [x] 已配對藍牙相機的低電量／持續下降提醒接入面板與原有 Yun 狀態膠囊。低量門檻20%；下降須多筆同peer/session有效資料，過期、斷線或重新選擇會清除，100%未充電不當故障。[規則與來源界線](docs/BLUETOOTH_TELEMETRY.md)
- [x] 普通配對面板顯示既有04/05回報的偏航、俯仰、翻滾；5秒有效期、序列去重與連線清理，不發新查詢、不覆蓋frame callback，也不當作USB座標校準或原生馬達成功證據。
- [x] 新增18項Core與1項App整合測試，本批總計351項Release測試（Intelligence21／Evaluation1／Core286／App43）。[日誌](artifacts/offline-telemetry-2026-09-09/final/test-gate.log)
- [x] 331個三語字串、7個未修改共用設計檔；41張UI＝29張一般介面＋12張明示遙測fixture。視覺檢查修正繼承自音訊App的Pitch譯名為「俯仰」。[UI](artifacts/offline-telemetry-2026-09-09/final/ui-gate.log)、[視覺核對](artifacts/offline-telemetry-2026-09-09/final/visual-review.json)
- [x] 更新簽章／偏好隔離、MCP／取消、搬移後MLX／Core AI推論與卸載、ZIP／DMG內版本及簽章再次通過。[產物](artifacts/offline-telemetry-2026-09-09/final/release-artifacts.json)、[包內核對](artifacts/offline-telemetry-2026-09-09/final/release-artifacts-verification.json)
- [ ] 真實低電量／持續下降提醒與失聯過期的完整UI場景仍待核對；重新配對後的電池／姿態及三項設定讀值已由上節實測補足，100%正常回報與fixture不能代替低量／下降告警驗收。

build 5 App SHA-256：`314f6cc8c769ce6640e36cbab6f989f71a4e192ce85c6947061b3904247751ac`。本批仍未驗實機影音／動作、公開更新／公證及鎖屏下popover動畫。

## build 4 離線驗證與交付基線

- [x] 本批 Release 332 項程式測試通過：Intelligence 21、Evaluation 1、Core 268、App 42；7 個共享設計檔、317 個三語字串及3組 C／ASan 檢查亦通過。[測試](artifacts/offline-2026-09-09/final/test-gate.log)、[設計／三語](artifacts/offline-2026-09-09/final/design-contract.json)
- [x] 四個更新 feed 簽章案例通過；本機測試 feed 不等於正式更新發布與安裝驗收。
- [x] 真實 Apple 模型＋**模擬相機**：zoom 狀態→單次 raw 200→新影格→明說模擬的回答通過。[result](artifacts/model-zoom-check/apple-E9E5E104-C10D-4534-A9AE-163763E477DE/result.json)、[log](artifacts/offline-2026-09-09/apple-zoom-model.log)
- [x] 已快取的真實 MLX 模型＋**模擬相機**：同一 zoom 流程通過，沒有下載模型。[result](artifacts/model-zoom-check/mlx-E203FD0E-3F39-4CF0-A3E3-5919636B82DD/result.json)、[log](artifacts/offline-2026-09-09/mlx-zoom-model-bundle.log)
- [x] **本批 build 4 完整 Release gate**：統一測試、MCP、29 張介面、搬移後 MLX／Core AI 推論與卸載，以及 ZIP／DMG 均通過。新視覺檢查發現並修正截圖語言未通知 footer 重繪；短／長提示列均30 pt、footer區38 pt，截圖不改已保存語言。[UI](artifacts/offline-2026-09-09/final/ui-gate.log)、[推論](artifacts/offline-2026-09-09/final/portable-inference.json)
- [x] signed-feed／loopback fixture 偏好隔離與清理通過：四個 feed 案例加上非測試 bundle 拒絕／零請求／偏好 sentinel 保留；空偏好域的清理誤判已修。[更新測試](artifacts/offline-2026-09-09/final/update-feed-verification/result.json)
- [x] 新 ZIP 解壓與 DMG 只讀掛載後的 App／CLI 簽章、版本與雜湊核對，以及卸載清理均通過。[產物](artifacts/offline-2026-09-09/final/release-artifacts.json)、[包內驗證](artifacts/offline-2026-09-09/final/release-artifacts-verification.json)

build 4 App SHA-256：`f6e3207c34510ae58ce808d20f3e7e58659fd431637bc34ffc8ac6428ff527d7`。該批桌面處於鎖定／休眠狀態，popover 動畫未重驗；離線版面與生命週期通過不等於該輪動畫通過。實機影音／動作、正式更新下載安裝及公證亦不在該 gate 的通過範圍。

兩份模型 result 均為 `simulation=true`、`physicalCameraAccess=false`，各只有一次模擬 raw 200 寫入；流程計時約 Apple 13.386 秒、MLX 37.832 秒。這證明真實模型的工具流程，**不是實體相機變焦、倍率或相機端動作證據**。另一份 MLX `ED86A580…` 只有 started／未 passed，不併入成功結果。

## 已落地的軟體能力

本節的勾選表示實作或相應離線基線已有證據；新增變更仍以本批 Release gate 驗證，硬體與公開發布條件另列。

- [x] 原生 App、MCP／CLI、同使用者 Unix socket、單一服務實例與統一 Pocket 3 Controller 名稱。
- [x] YunAudio／YunUI 共用設計、設定、選單列、圖標、三語、關於與更新介面；保持膠囊狀態列、原版提示列尺寸及手動控制美感。
- [x] 相機模式、橫直幅／幀率與 Auto／NV12／UYVY 選擇；宣告格式與實測可用性分開，拒絕不支援的組合，不靜默降級。
- [x] USB 連續目標、單一控制者、最新輸入合併、Stop／取消／連線生命週期 fence；一度步進保留為診斷工具。
- [x] Zoom 的 UVC raw 能力／有界寫入／回讀、App 滑桿、CLI／MCP 與內建 AI 工具；UI 百分比是行程位置，不標成校準倍率。
- [x] Zoom 待停止狀態跨 Task 取消保留，獨立 fresh hold、合併 pan／zoom 停止結果；新增步進容差與 UI 合併／取消／重連的離線測試。
- [x] 預覽 tap AF 的能力查詢、session 綁定與點按 UI 邊界已實作；當次 USB 能力不可用，不能據此勾選硬體功能完成。
- [x] Apple／MLX 圖片問答、Dynamic Profile、OCR／條碼、有限工具呼叫及動作後同 session 新影格綁定。
- [x] 固定模型 revision、下載／完整性校驗、取消／重試、部分下載清理、卸載與記憶體管理。
- [x] 音訊有界時間、PCM 格式／大小、單次測試與生命週期保護；完整串流驗證執行器已實作。
- [x] Core AI Float32 CPU／GPU 數值比對、Release 效能與 Vision 基線；保留 Float16 失敗，MPSGraph／GPU trace 不冒稱 ANE 使用證據。
- [x] 開發／保留題集、人工核對與 Apple Evaluations replay；保留模型計數及不實完成宣稱案例。
- [x] 預設診斷移除影像、裝置識別、活動及自由文字錯誤；獨立 Python 接入範例。
- [x] 集中錯誤呈現與有明確事件鍵的活動本地化；技術原文只限量保留於記憶體供進階診斷取用，不加進既有 Copy issue report／預設匯出。

## 已取得的實機基線

以下描述 2026-09-08 相機開啟時的驗收，不表示現在仍在取像／遙測，也不自動涵蓋後續新版本。

- [x] 三項韌體與 USB attachment／boot 已記錄：系統 `01.06.10.04`、相機 `10.00.50.51`、雲台 `01.00.15.81`。[韌體紀錄](artifacts/hardware-resumed/firmware.json)
- [x] 使用者確認機身拍攝方向後，五種直幅格式通過：720×1280@25／30、1080×1920@24／25／30。[矩陣](artifacts/hardware-resumed/portrait-matrix/47249823-ced5-4be7-954e-cce4aa2113d6/result.json)
- [x] 1080×1920 NV12／30 fps、雙聲道 48 kHz 的完整 30 分鐘影音與清理通過，1800.207 秒。[完整報告](artifacts/hardware-resumed/stream-final/EC740B6A-ECD5-4C48-89B1-8A797CF2D936/report.json)
- [x] 可見 AppKit 手動介面的按鈕放開、拖曳放開／失焦、服務端 Stop、App Stop 五組通過，USB 位置有變化。[按鈕](artifacts/hardware-resumed/manual-button-release.json)、[拖曳](artifacts/hardware-resumed/manual-drag-release.json)、[失焦](artifacts/hardware-resumed/manual-drag-focus.json)、[服務 Stop](artifacts/hardware-resumed/manual-button-remote.json)、[App Stop](artifacts/hardware-resumed/manual-button-stop.json)
- [x] 拖曳 near／far 的位移分別為 2160／8280 raw，約 3.83 倍；只證明輸入幅度改變回讀位移。[near](artifacts/hardware-resumed/manual-v2-near.json)、[far](artifacts/hardware-resumed/manual-v2-far.json)
- [x] 小角度 tilt 影像方向、名義 +5° 跨零及復位有回讀證據。[方向](artifacts/hardware-resumed/uvc-direction-images/result.json)、[跨零](artifacts/hardware-resumed/uvc-tilt-five-degrees/result.json)
- [x] USB 視角路徑研究取得正面→pan 648000→pan 0 往返與穩定回讀。[往](artifacts/hardware-resumed/manual-v3-flip-back.json)、[返](artifacts/hardware-resumed/manual-v3-flip-front.json)；慢速 approach 不等於機身原生快速預設。
- [x] **Zoom 100→200→100 已實機匹配成功**，沿用單次 SET 與較長只讀等待。[zoom-final](artifacts/hardware-resumed/zoom-final/result.json) 的 `set200`／`reset100` 均 verified；raw 100–400、step 1 不據此換算倍率。
- [x] BLE 發現／GATT／配對與 USB 預覽共存；註冊回覆修正後配對成功，再以 pairOnly 成功且不切換 Mac 網路。[註冊修正](artifacts/hardware-resumed/ble-pair-registration-fix.json)、[pairOnly](artifacts/hardware-resumed/ble-pair-only.json)
- [x] BLE 電池與姿態已有即時回報證據；電池百分比／充電狀態取自相機，不以 USB 500 mA 推算。[硬體紀錄](docs/HARDWARE_ACCEPTANCE.md)
- [x] 固定本機開發憑證、不同 App 二進位相同 DR／交叉驗證，且實際跨建置重連保留相機授權。[簽署與 TCC](artifacts/hardware-resumed/app-signing-retention.json)
- [x] 解鎖後 popover 動畫、視窗重開與當時版面尺寸通過；新 zoom／focus／錯誤本地化 UI 仍由本批 gate 回歸。[UI 基線](artifacts/hardware-resumed/ui-check.json)

## 相機重新開啟後的必要驗收

- [x] **build11 Zoom moving-stop 新規則實機讀回通過。** 從100請求400，讀到194、再200且仍moving時Stop；hold target／observed均200，內部11筆／0.847秒、其後8筆獨立讀回／0.899秒均穩定，原請求以CancellationError結束。之後明確恢復100亦verified。[Stop結果](artifacts/zoom-moving-stop-2026-09-09/7ec1044c-d59b-46fd-a823-23aaa20b8aea/result.json)、[恢復](artifacts/zoom-moving-stop-2026-09-09/7ec1044c-d59b-46fd-a823-23aaa20b8aea/restoration.json)。只驗本次有界途中停止，不涵蓋倍率、物理煞停延遲、完整UI拖曳／所有視角。
- [ ] Zoom 最新整合版的持續拖曳、取消／Stop、重連、gimbal 接管與新影格／視覺效果；校準倍率另行驗證。
- [ ] 使用者要求的機身搖桿 double／triple **原生快速回中與前後切換**。單次 FE08 已提交但3秒無回覆、30筆姿態無變化；FE09未由此得到成功證據，慢速 USB approach 不作產品替代。[FE08](artifacts/hardware-resumed/native-recenter-result.json)
- [ ] App 預覽 **tap AF** 的可用傳輸。使用者已確認 Pocket 3 **機身在 Webcam 模式可點按 AF**；當次 USB／AVFoundation 卻回報 point／auto／continuous 均 false。新版已提供唯讀 MCP／CLI `camera_focus_status`／`focus-status`，實機正常 MCP connect→read→pause 同 session再次回報三者皆false，沒有啟動BLE或送寫入。缺的是 host 控制路徑，不是機身 AF，也不能以 MF 拉條替代。[結果](artifacts/hardware-complete-2026-09-11/mcp-focus-status.json)
- [ ] 完整宣告視角範圍、各姿態、物理角度／速度、平滑度、停止延遲與尾移校準；不以一次大角度往返或穩定 USB 回讀宣稱全範圍／機械停止通過。
- [x] USB small absolute target baseline：metrics-only pan probe從raw0請求3600、穩定readback3960（tolerance內）；tilt probe target/readback均3600、pan−360；另5° nominal pan probe target/readback均17640／tilt3600。三者verified=true且之後pause。這只證明兩軸有界目標可到達，不校準機械角度或全範圍。
- [ ] 收緊後的完整控制報告：每軸至少20次往返、中途停止、競爭控制、快速拔插／喚醒及動作後新影格。v3錯誤通過標記已撤銷；v4曾24次保持通過但首個目標未到位，整份仍未接受。
- [x] 20-trial trajectory suite safety gate：新增metrics-only suite，首個right trial的24 samples實際顯示pan 0→7920、反向後回落至1440，單次USB writes約0.4–2.6ms；但final Stop target pan1440／readback0、`verified=false`，因此未發其餘19輪並完成manual/pause cleanup。這保留physical stop failure，不以單次service hold替代完整 acceptance。
- [x] metrics-only USB trajectory baseline：新驗證器不輸出照片；right、left、up各完成24個readback sample／verified Stop／manual cleanup＋pause。probe每次前600ms朝指定方向、後600ms反向後hold，因此最終raw position不作左右或物理角度判斷；這只驗服務scheduler reversal→hold流程，不驗尾移。
- [x] USB trajectory control-read recovery：down首輪第6 sample的`control_read_superseded`已定位為periodic status read搶占control feedback；motion active時status改用既有capability。修正後down完成24 samples／無failure／Stop verified／未存影像。四方向metrics lifecycle已通過，物理角度／尾移仍待驗收。
- [ ] 完成最新candidate的直幅方向／完整內容、黑邊、視窗縮放與切換重連，以及尚未覆蓋的格式組合。公開beta1的NV12橫幅子矩陣已通過；早期五種直幅的通過受當次機身方向限制，不涵蓋全部模式。新版唯讀 MCP `camera_format_inventory` 在未選相機但僅一台已接機身時列出16個宣告模式（5直幅、6個4K），保持idle／0 frame；這只改善選擇發現，不把宣告當串流通過。[結果](artifacts/hardware-complete-2026-09-11/mcp-format-inventory.json)
- [ ] UYVY 選項對應的 H.264 路徑與4K高幀率：多種 AVF output policy、延長20秒及解鎖環境仍無 sample callback；繼續核對 OBS 的實際影像及其他路徑，不能把選單宣告當可用。[解鎖對照](artifacts/hardware-resumed/uyvy-unlocked-20s.json)、[協議／格式證據](docs/HARDWARE_ACCEPTANCE.md)
- [x] build19明確AVVideoCodecKey=h264診斷已測：NV12 1080p30在6秒取得138個avc1 block buffers、零pixel buffer；UYVY 1080p30／4K30／4K60同窗口均零sample。這證明診斷輸出路徑工作，不代表UYVY／4K60或原生wire H264可用；沒有為此加入無助於零輸入問題的解碼器。已清除診斷環境並恢復4K30 NV12／BGRA。[結果](artifacts/h264-output-build19/result.json)、[恢復](artifacts/h264-output-build19/normal-restored-settled.json)
- [ ] BLE 原生持續馬達控制。有效時序的200 ms低速脈衝沒有位移；04/50 readiness 查詢無回覆。已配對／可讀姿態不等於可控制馬達。[脈衝](artifacts/hardware-resumed/ble-native-probe-2/result.json)、[readiness](artifacts/hardware-resumed/ble-readiness-result.json)
- [x] build17的外部packaged MCP完成真機縮放100→200→100，三張同session新影格與兩次精確回讀均通過；獨立manual模式的合法縮放請求回`access_denied`且原值不變。只保留圖片hash／大小，不保存照片。[縮放](artifacts/mcp-zoom-hardware/6c10d197-9e1e-4b4b-b518-348f56141472/result.json)、[拒絕](artifacts/mcp-zoom-hardware/cea79505-a683-4c99-9b54-f10aedd42c4e/result.json)
- [x] build19實際MCP縮放中取消通過：原目標400，兩筆moving讀回105／200後送notifications/cancelled，App自行保持200；獨立穩定1.087秒、helper仍可用、取消回覆被抑制、客戶端未發Stop。之後另外恢復100／manual。舊請求／replacement、failedhold阻擋及重複授權的5項Core回歸通過。[結果](artifacts/mcp-zoom-cancellation/59d10e7c-ccc3-4a09-9094-54486775c469/result.json)、[恢復](artifacts/mcp-zoom-cancellation/59d10e7c-ccc3-4a09-9094-54486775c469/explicit-restoration.json)
- [x] build20來源補上正常縮放逾時的相同保持流程；回覆仍保留原動作completed=false／verified=false。新增第6項Core測試實際等完逾時與保持窗口，確認只寫目標200和保持160、不重試200。完整Release 468項執行通過、3項opt-in跳過。build20實機MCP取消亦再次保持200、獨立穩定1.090秒且clientStopSent=false，另已恢復100／manual。[測試](artifacts/mcp-cancel-build20/release-tests.log)、[實機](artifacts/mcp-zoom-cancellation/522db46d-a71a-4358-8f3f-75ee0023e89e/result.json)
- [ ] 完成真實相機下模型與外部MCP的取消、重連、錯誤恢復及移動後新影格完整流程。MLX與MLX控制／Apple回答的單次真機任務已有上節證據；外部MCP縮放與拒絕已補足，但不代表所有語句／全視角已驗收。
- [ ] Mac Studio遠端桌面／無實體螢幕驗收：區分顯示器關閉、GUI鎖定、使用者登出及整機睡眠；涵蓋預覽、MCP、手動拖曳／放開及遠端斷線。核心控制無螢幕亮起門檻；AppKit合成事件／popover動畫的不可用不能等同相機服務失效。本次MCP操作前displayAsleep=false；最新版背景 bridge 也以正常 CLI 在無主視窗狀態取得70 frames／33.09fps、pause後0 frames、manual/no-motion，但仍**尚非關螢幕或實際遠端驗收**。[環境](artifacts/mcp-zoom-hardware/build17-context.json)
- [x] build18來源加入隨取像生命週期管理的ProcessInfo活動：防止閒置系統睡眠及App Nap，允許螢幕休眠，Stop／失敗／實際session停止或斷線時釋放，舊generation通知不得釋放新活動。460項Release測試執行通過、3項opt-in跳過；另8個MCP離線流程含磁碟失敗清理通過。實際App已確認取像時一份防閒置系統睡眠保護、暫停後零份、重連後一份，沒有display-sleep保護；最終4K30新影格及manual恢復。[測試](artifacts/capture-activity-build18/release-tests.log)、[實機生命週期](artifacts/capture-activity-build18/live-activity-lifecycle.json)
- [ ] USB 供電／未知充電提示的最新 UI 與實機回歸；不把配置電力當實際充電功率或電池回報。

## 其他本輪功能與外部發布條件

- [x] DUML CRC／fragment／ACK／session 邊界、BLE 配對及原生 UDP codec 已實作；Wi-Fi join／datalink 保留研究，不是主流程或可用控制的前提。
- [ ] 曝光、白平衡、色彩、機內拍攝、音訊等機身設定逐項接入並驗證；首批協議整理不代表全部設定可寫。[路線圖](docs/DEVICE_CAPABILITY_ROADMAP.md)、[設定協議](docs/CAMERA_SETTINGS_PROTOCOL.md)
- [ ] 追蹤、素材、配件與其他機身選項依可靠協議證據擴充。
- [x] 本專案正式appcast／公鑰／archive位置及公開下載／簽章核對已完成，見上節Beta發布紀錄；不再列為待配置。
- [ ] 以已發布beta1實際更新至下一個可發布版本，驗證安裝／替換／重啟與偏好、相機／IPC清理；signed feed有效及公開下載成功不代替這一步。
- [x] 隔離的beta1 build9→candidate17副本已實際透過Sparkle下載／安裝／重啟，完整副本bytes／簽署、偏好、新PID與IPC、測試清理均通過。使用獨立bundle ID及測試feed，沒有取像；正式App更新UI／正式feed與取像中的更新仍屬上一項未完成範圍。[結果](artifacts/update-install/build9-to17-complete-20260909/result.json)、[流程](docs/RELEASE.md)
- [ ] Developer ID／公證及公開分發驗收。本機版已有固定開發簽署，不再稱無有效本機身分；公開發布條件尚未完成，也不阻止可離線完成的工作。

## 歷史證據與已被取代的狀態

- 歷史 Release gate `dea96ce0-836f-482b-bdbc-c956ed0400f5`、`0603c8a1-9d0f-4ed9-ba6f-afff1b550c80`、`70f2eff4-39f3-4030-b8c9-e22802359302` 與 App／CLI、ZIP／DMG、搬移 App 隱藏 `.build` 後的 MLX／Core AI 推論保留為**各自批次**證據；不替代本批 build 4。[驗收歷史](docs/ACCEPTANCE_AUDIT.md)
- 較早的2026-09-09 Debug 批次記錄 Core 268／App 41 等測試通過；先前 Core 236／App 26 亦只描述當時批次，不再稱為最新。[Debug 日誌](artifacts/offline-2026-09-09/debug-tests.log)、[較早整合日誌](artifacts/hardware-resumed/zoom-focus-native-tests.log)
- 2026-09-08 的軌跡批次另有重建／打包摘要，也不代表後續 zoom、focus、原生預設或語言修正的新包通過。[摘要](artifacts/hardware-resumed/github-trajectory-summary.json)
- 早期「尚缺完整長測執行器／只有模擬 timeline」與首輪音訊配置停流的紀錄保留；後續已補執行器並取得上列指定模式1800秒通過，不再寫成現在仍完全沒有30分鐘影音證據。
- 早期「桌面鎖定／首次藍牙授權未決定／新簽署 App 尚未授權」均是當時限制；後續解鎖、藍牙配對與跨建置相機權限保留已有證據。
- 早期「DUML 電池只用 fixture／尚未接入即時遙測」及「相機關機待恢復」已由重新配對／即時回報補足；每次仍以當前session與有效期判定，不能把歷史電量當目前狀態。
- Zoom 舊短窗口停在164／返回停在128的未確認結果保留，後續100→200→100已匹配。舊`zoom-final`整體`passed=false`不改寫；本次新Stop規則通過見上節。另一輪100→200太快到位，未捕捉途中Stop，`not_confirmed/passed=false`亦保留，不能借靜止Stop算通過。[舊窗口](artifacts/hardware-resumed/zoom-live/result.json)、[舊Stop判定](artifacts/hardware-resumed/zoom-final/result.json)、[未捕捉中途停止](artifacts/zoom-moving-stop-2026-09-09/36fbbb32-110d-4f0d-88bc-2d6fd01a15f1/result.json)
- 直接單次180°未到位、BLE脈衝／FE08未觀察到作用、H.264無回呼及未完成的MLX嘗試均不刪除、不改成通過。

## 1.0 後、尚未提升為首發需求

- [x] App Intents preview connect／privacy pause：macOS 26+ `Pocket3ConnectPreviewIntent`與`Pocket3PrivacyPauseIntent`共享AppModel/CameraService，不新增控制transport；兩者`openAppWhenRun=true`，Shortcuts在App未執行時會先啟動同一登入session。Connect只採用已存的選擇／格式、保留manual access，Pause釋放session。`Pocket3AppShortcuts`提供兩個Shortcuts/Spotlight phrase、短標題與圖示；Release build通過。Shortcuts CLI只列使用者建立捷徑，不能作系統discovery verifier，安裝App後的Shortcuts實際執行仍待驗收。
- [ ] 按鍵收音與 SpeechAnalyzer。
- [ ] 指定觀察區域、look_at、同視角比較。
- [ ] 遠端 HTTP／headless host 依具體部署需求決定。BLE／機身設定已屬本輪擴充，不能再一概延後；切換 Mac Wi-Fi 則不符合使用者限制。
