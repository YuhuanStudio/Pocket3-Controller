# Beta 1 公開呈現核對

2026-09-09 的只讀審查；`[x]` 僅表示已核對所述證據，`[ ]` 表示待完成／重新核對。這是目前 beta 的文件與下載體驗清單，不把完整1.0、所有機身控制或額外發行通路當作本輪門檻。

參考 YunAudio 的 [README](https://github.com/YuhuanStudio/YunAudio/blob/main/README.md)、[文件索引](https://github.com/YuhuanStudio/YunAudio/blob/main/docs/README.md)、[RELEASING](https://github.com/YuhuanStudio/YunAudio/blob/main/RELEASING.md) 與 [package.sh](https://github.com/YuhuanStudio/YunAudio/blob/main/package.sh)：借用清楚的產品定位、三語導航、實際介面、安裝流程、驗證範圍與已知限制。不要搬入音訊driver、Homebrew通路、舊macOS下限、Apache專案授權badge或過時CI敘述。

## 版本、下載與頁面

- [x] [公開 Release](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1) 可讀、標為pre-release，版本`0.0.1-beta.1`／build9，tag來源`21778c0e6ddec9ec9da017683f74c62177443985`。目前main已是beta2開發線，不能把build11或lens-series讀回列成beta1功能。
- [x] 既有無登入公開下載報告確認ZIP／DMG／checksums／release-notes的hash及size；報告時間`2026-09-09T05:37:13Z`，本輪未重新下載二進位。[維護者本機證據](../artifacts/public-beta1/public-downloads/result.json)
- [x] 三份README、Release頁、其`release-notes.md`附件、[beta交付清單](BETA_1_RELEASE.md)、[發布流程](RELEASE.md)與TODO同步「beta1已發布、簽署feed已上線、跨版本更新安裝仍待驗」的狀態；附件與頁面不可長期各說一版。公開文件與圖片仍待最終核對，不因本清單預先勾選。
- [x] 所有語言顯示同一下載版本、Apple Silicon／macOS27需求與beta限制；首頁直接給[DMG](https://github.com/YuhuanStudio/Pocket3-Controller/releases/download/v0.0.1-beta.1/Pocket3Controller-0.0.1-beta.1.dmg)、[ZIP](https://github.com/YuhuanStudio/Pocket3-Controller/releases/download/v0.0.1-beta.1/Pocket3Controller-0.0.1-beta.1.zip)、[checksums](https://github.com/YuhuanStudio/Pocket3-Controller/releases/download/v0.0.1-beta.1/checksums-0.0.1-beta.1.txt)，不用僅指向泛用Releases頁。
- [x] 三語Release body審閱後發布，並以未登入頁面確認語言導航、圖片與下載連結。草稿：[本機三語body](../artifacts/public-beta1/release-body-trilingual.md)。主分支raw圖片連結發布後還需HTTP及實際render核對。

## 九張公開介面圖

| 畫面 | English | 繁體中文 | 简体中文 |
|---|---|---|---|
| 主視窗 | `docs/images/window.png` | `window-zh-Hant.png` | `window-zh-Hans.png` |
| 引擎／接入 | `docs/images/engines.png` | `engines-zh-Hant.png` | `engines-zh-Hans.png` |
| 外觀 | `docs/images/appearance.png` | `appearance-zh-Hant.png` | `appearance-zh-Hans.png` |

- [x] 圖片為明示的 beta 2 開發介面 build 11；公開 beta 1 下載仍為 build 9。已保存實際 App hash、語言、尺寸、預覽排除標記與 PNG hash：[圖片 manifest](images/manifest.json)。不是 beta 1 功能完成的證據。
- [ ] 擷取前後均為idle／frames0；只展示真實空預覽與介面，不包含相機照片、室內場景、姓名、序號、UUID、Wi-Fi資訊、私有路徑或診斷流量。沒有影像可用時不做假預覽／假合焦／假綠色驗收畫面。
- [x] 逐張看完整視窗：三語標題、按鈕、狀態列和footer同語言，沒有文字截斷、異常上下空白或寬度，Yun原有形狀與間距不因宣傳圖更改。PNG存在或UI gate通過不等於視覺已驗收。
- [ ] 同畫面三語採一致尺寸／比例／外觀；每張alt text使用對應語言。確認raw URLs是公開介面圖，不誤連`artifacts/`內相機snapshot；不把未檢閱的59張gate圖直接當公開圖集。

## 安裝、首次使用與模型

- [ ] 三語完整寫明：下載DMG／ZIP→放入Applications→開啟App→USB接Pocket3→機身選Webcam→App選取／連接。說明固定開發簽署、未公證與系統「隱私權與安全性」允許開啟路徑；不聲稱Developer ID／Apple公證已完成。[Apple首次開啟說明](https://support.apple.com/en-us/102445)
- [ ] 首次從網路下載到另一台Mac的隔離／權限體驗，與本機build或無認證hash下載驗證分開記錄；尚未實驗就保持待驗，並不因此將已公開beta描述為未發布。
- [x] 相機、Bluetooth、麥克風按相應功能請求；USB手動控制不要求BLE配對或Mac加入相機SSID。AI觀察／控制要在App允許；關窗留在選單列、隱私暫停釋放影音、退出結束服務三者分清楚。
- [x] 原始碼的MLX預設為`mlx-community/Qwen3.5-4B-4bit`固定revision，UI說明約3.1GB；下載與載入分開，下載完成後可離線推論。[模型實作](../Sources/Pocket3Intelligence/LocalModel.swift)、[權重歸屬](../ThirdParty/ModelWeights/NOTICE.md)
- [x] 三語補齊模型前置說明：MLX首次需網路下載，不隨約39MB App包內附完整權重；Apple引擎依系統模型可用性；手動預覽／控制無需先下載MLX。不要將「本機推論」誤寫成整個App從首次啟動完全不需網路，也不要捏造最低RAM／ANE效能數字。
- [x] MCP／CLI教學使用安裝後helper路徑與App內複製設定，明示App需運行／授權；不把開發用`--hardware-validation`當一般使用者啟動要求。[接入例子](../Examples/README.md)

## 文件、授權與支援

- [x] 核對既有三語文件的公開導航：三份[主README](../README.md)、[繁中README](../README.zh-Hant.md)、[簡中README](../README.zh-Hans.md)，三份[文件索引](README.md)、[繁中索引](zh-Hant/README.md)、[簡中索引](zh-Hans/README.md)，以及三份[指南](guide.md)、[繁中指南](zh-Hant/guide.md)、[簡中指南](zh-Hans/guide.md)均已存在本機；尚不等同公開HTTP／render檢查完成。確認能到[支援矩陣](SUPPORT_MATRIX.md)、[已知驗收界線](PENDING_VALIDATION.md)、[發布流程](RELEASE.md)與[NOTICE](../NOTICE.md)，不強迫本輪翻譯所有研究筆記。
- [x] 檢查公開相對連結：`artifacts/`及`research/`未隨source發布；對一般讀者提供公開結論／限制，不把只存在維護者電腦的檔案當可開啟證據。三語README、Release與docs索引需做連結巡檢。
- [x] [NOTICE](../NOTICE.md)已明示本專案自有source未另指定開源授權，第三方各依原授權；不能套用YunAudio的Apache專案badge。App內依賴licences與model attribution的打包路徑已有文檔。[第三方清單](../ThirdParty/README.md)
- [x] 首頁／Release連到[Issues](https://github.com/YuhuanStudio/Pocket3-Controller/issues)，回報要求App版本/build、macOS版本、使用功能／transport及重現步驟；相片、序號和完整diagnostics不是必填。最小contribution／support入口可後補，但不能照抄YunAudio私人聯絡方式或聲稱本repo已開啟未核對的private vulnerability reporting。
- [x] [LOCAL_SIGNING](LOCAL_SIGNING.md)仍有舊App名稱與「-local命名不變」字句，應同步公開包現名；只調文件，不更換既有簽署身分或權限資料。不得把公有source等同整體功能、法定商標或跨機安裝均已驗證。

## 更新服務的實際狀態

- [x] 公開設定已填本repo獨立feedURL與公鑰；不是YunAudio的更新通道。[ReleaseSettings](../Resources/ReleaseSettings.json)
- [x] 發布端授權與`generate_appcast`已完成，[正式beta feed URL](https://raw.githubusercontent.com/YuhuanStudio/Pocket3-Controller/main/updates/beta-appcast.xml)已公開HTTP200，下載內容與本機簽署bytes一致。無登入下載驗證時間`2026-09-09T06:16:36Z`，5181 bytes，SHA-256 `dd335e510cbb571cc1e3ccf332a576e10634f8b5a8539dcd60a5dcdc127265f4`。[公開feed下載結果](../artifacts/public-beta1/public-feed-download.json)
- [x] CryptoKit使用公開Ed25519 key驗證公開feed及GitHub下載ZIP，`feedVerified=true`、`archiveVerified=true`，驗證過程沒有讀取私鑰。[公開簽章驗證](../artifacts/public-beta1/public-signature-verification.json)
- [ ] 真實舊版→新版下載／安裝／重啟及偏好保留，仍需另外完整驗收；公開feed／ZIP驗簽與隔離signed-feed fixture不能代替這一步。三語說明可以寫更新來源已上線，但不能寫跨版本更新安裝已通過。

本清單以小範圍公開呈現為界；不新增Homebrew、商店、公證、遙控協定或更多模型作為本輪必做事項。

## 本批實際版面覆核

已逐張檢查 42 張設定頁（三語 × 7 頁 × 2 種尺寸），6 張引擎頁及 6 張診斷頁，另檢查連線後的主視窗。AI 卡片等高且能力／操作列齊線；長標籤、更新列、權限圖示與短診斷卡已修正。音訊動態狀態與時間格式的語言問題亦已修正，補做相關截圖與測試。維護者紀錄位於本機 `artifacts/layout-build11/`。

公開核對已完成：三語 README／指南／索引及九張圖片的無登入 HTTP bytes 與本機一致；三語 README 的 GitHub rendered HTML 和 Release 公開 HTML 均已核對。瀏覽器介面未提供，因此沒有宣稱做過瀏覽器像素截圖。版面修正後 Release 配置的程式測試共 413 項通過。
