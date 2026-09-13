# Pocket 3 機身 writer 證據矩陣

更新：2026-09-13。這份矩陣描述目前 source tree 能證明的 packet shape、readback
和產品 admission。它不把開源 builder、BLE transport ACK 或 API 存在誤寫成
機身 writer 已生效。相同資料可由 developer-only
`validation-wireless-writer-support-report --hardware-validation` 輸出 JSON；
該 route 是純資料查詢，不建立 BLE／Wi-Fi 連線，也不送任何 packet。

## 判讀規則

`protocolStatus=exact` 表示命令 envelope、payload shape 與本地 encoder 都有
獨立依據；`partial` 表示 envelope 已知但 blob 或欄位仍是 composite／variable。
`availability.write` 只有在同一 session 的 ACK、提交後 matching readback，及
需要時的機身結果都成立後才會是 `true`。`candidateOnly` 只代表可以規劃下一個
有界驗收；`blockedNoVerifiedWrite` 表示目前產品 writer 被擋住。每筆 raw
readback 都要完整保留，不能以 target 或上游 enum 補未知值。

OpenPocketCine 的 Pocket 3 physical survey（commit
`9b30b93572797c94db5ad9236fb746410f8d761f`）確實記錄了多項 accepted/status
與 matching readback；其 handbook 與 caller 走 camera Wi-Fi datalink。報告中的
`upstreamAccepted`、`upstreamObserved` 和 `upstreamTransport=wifi_datalink`
只標示這個外部證據，絕不改變本案 `bluetooth_datalink` 的 admission。尤其 WB
上游 accepted 不抵銷本案兩次 BLE 5600 K 無 ACK 的結果。

| candidate | exact packet evidence | readback evidence | current admission | 最小下一個真機驗收 |
|---|---|---|---|---|
| `white_balance` | BLE DUML `02/2C`, `source=02 destination=01 flags=40`；Auto=`00 00 00 00 00`，custom=`06 kelvin/100 00 00 00`；上游 survey `upstreamAccepted=true`（Wi-Fi） | `00/99/06` `cam_image_effect`，至少 6 bytes；color[2]、WB mode[4]、Kelvin/100[5]，raw 保留；上游也有 matching readback | `blocked_no_verified_write`；兩次 5600 K BLE 嘗試都沒有 ACK 或 matching readback，read-only Auto 曾成功 | exact paired session 下 Auto↔custom 一次往返，ACK 後 matching image-effect，再只恢復已讀到的 baseline |
| `focus_mode` | BLE DUML `02/24`；一 byte `01=S-AF` 或 `02=C-AF`；上游 accepted/status 走 Wi-Fi | `00/99/06` `cam_lens_state`，至少 1 byte；只把 raw B1/B2 解為 focus mode；上游亦有 B1/B2 corroboration | `candidate_only`；Phase29 dry-run gate，沒有 BLE mode SET 成功證據 | fresh B1/B2 baseline→一次 02/24→matching ACK 與 post-submit lens readback→恢復 baseline |
| `color_profile` | BLE DUML `02/42`；一 byte `00=Normal`、`3C=HLG`、`3D=D-Log M`；上游 accepted 走 Wi-Fi | `00/99/06` `cam_image_effect`，color[2]，完整 raw 保留；上游有 independent image-effect status | `candidate_only`；有 typed readback，沒有 local color SET ACK/readback | 只切換一個 profile，確認 matching image-effect 與相機畫面／模式結果，再恢復 |
| `exposure` | `02/1E` mode=`01/04 00`；`02/2E` EV=`07…19`；`02/2A` ISO selector=`00/02…09`；OpenPocketCine Pocket 3 Low-Light survey additionally accepted sparse `10=9600` and `11=16000` (不可線性外推)；`02/28` 7-byte shutter；ISO limit 為 `02/8E` PID `000F` keyed SET `01 01 0F 00 01 selector`；上游 mode/EV/ISO/shutter accepted 走 Wi-Fi | `00/99/06` `cam_expo_param` 至少 20 bytes：EV[6]、mode[7]、effective ISO u32LE[16…19]；ISO limit另用嚴格 `02/8E` PID/length envelope | `candidate_only`；Auto/EV/effective ISO 有 local readback，沒有 BLE exposure write matching evidence | 先做 Auto 或單一 EV step；成功後才做 Manual mode→ISO→shutter atomic sequence；每步 ACK/readback/restore |
| `body_recording` | Format `02/18`=`[resolution fps 00 slowMotion 00]`；lifecycle `02/02` start=`01`／stop=`00`；上游 format/start/stop accepted 走 Wi-Fi | `00/99/06` `cam_video_param_v2` 至少 9 bytes；`camcap_video_format` legal table；`02/80` status 需看到新鮮 terminal state；上游有 settled status | `candidate_only`；current body format/status 可讀，沒有本案 format 或 start/stop write verified | 選一個 fresh legal pair 或 lifecycle transition，確認 matching state、SD／錄影結果與 stop/restore |
| `audio_dsp` | GET `02/A0` empty payload；SET `02/9F` 帶同一 A0 variable blob，只 patch 已確認 byte 2，未知 bytes 全保留；上游 accepted 走 Wi-Fi 且 Pocket 3 blob 為 27 bytes | `02/A0` response `status=00 + variable blob`；byte 2 可標 wind/directional candidate，其餘 raw 保留；上游有 27-byte readback | `blocked_no_verified_write`、`protocolStatus=partial`；本地尚無 A0 baseline/readback，composite field semantics 未完全獨立驗證 | 同一 session GET 一次，改一個確認 selector，correlate 9F ACK＋matching A0，再以原 blob restore |

## Provenance

- Kaze fixed revision：`341a35de18493ff61f97c93b8b10161a7512aa36`，核對
  `Pocket3CameraSettings.swift` 的 `02/2C`、`02/24`、`02/42`、曝光與 keyed
  command，以及 `Pocket3CameraReadback.swift` 的 named-property readback。
- OpenPocketCine Pocket 3 physical survey：commit
  [`9b30b93572797c94db5ad9236fb746410f8d761f`](https://github.com/erik-sutton95/OpenPocketCine/tree/9b30b93572797c94db5ad9236fb746410f8d761f)，核對
  [`handbook/pocket3.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/pocket3.md)、
  [`handbook/commands.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/commands.md)。其 accepted/status 結果來自 camera Wi-Fi datalink。
- 本地 typed encoders/coordinators：`Sources/Pocket3Core/CameraSettingsCommand.swift`、
  `Pocket3Core/Pocket3NativeSettingCoordinator.swift`、
  `Pocket3Core/Pocket3ExposureValidation.swift`、
  `Pocket3Core/Pocket3NativeProtocolPhase0.swift`、
  `Pocket3Core/Pocket3AudioSettings.swift`。
- 本地 writer boundary audit：
  `research/2026-09-09/ble-camera-write-route.md`；該稽核把 Pocket 3 BLE-only
  WB／AF-mode／EV 的成功 writer evidence 記為 0。
- 本地 hardware evidence：`docs/HARDWARE_ACCEPTANCE.md` 及其連結的
  `artifacts/`；read-only observation 與 failed/absent write evidence 分開。

下一步只允許在同一 Pocket 3 firmware／paired session 做上述單一 bounded
probe。任何 session、peer、sequence、ACK、readback 或 physical result mismatch
都要停止，不猜新 opcode、不重試、不自動加入相機 Wi-Fi。
