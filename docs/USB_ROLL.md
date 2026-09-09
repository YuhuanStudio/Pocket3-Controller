# USB Roll 接入

> 本文件的 `artifacts/` 與 `research/` 連結指向本機證據目錄，不隨公開原始碼發布；版本摘要與公開下載驗證見 Release 說明。

2026-09-09，build 6已完成軟體驗證及第一次實機單步往返。這是P0已列出的`roll-abs`控制，不是機身5D搖桿的快速回中／前後翻轉，也不是影像後製旋轉或USB直幅模式。

既有實機枚舉宣告signed16、範圍−30…30、step1、default0，見[原始控制表](../research/2026-09-07/uvc-controls-complete.txt)。程式不硬編這個範圍或0：每次連線依實際控制的min/max/正步進和GET_DEF建立介面。缺少合法步進時拒絕寫入；預設值缺少或不合法時不提供恢復操作。原始數值未校準成物理角度，亦未證明正負號對應的影像方向。

## 使用方式與結果

- 手動控制區提供Roll滑桿、每次一個裝置步進的增減，以及恢復裝置預設值。
- 尚未送出的拖曳值只保留最新一個。prepare期間回到目前值，或回到正在執行的目標，會撤回舊的排隊目標。
- 開始手動Roll前結束其他控制；相機重連、睡眠、暫停、Stop或其他手動控制會撤回舊任務。
- 每次只送一個signed16 little-endian SET_CUR，使用已宣告的selector與實際terminal/interface，100ms只約束該IOKit request，不代表機械停止時間。
- 正常完成只依至少3筆、0.2秒的精確原始值回讀；沒有本機Roll量測可以支持非零容差。結果明示這是UVC回讀，未證明物理效果。
- 未確認、取消或寫入錯誤不自動重送。待停止狀態跨Task取消保留，全域Stop另用新鮮目前值保持並確認穩定；連線已換時舊cleanup不能寫到新session。

## CLI與AI範圍

`pocket3 roll-status [--session CAPTURE-SESSION-ID]`讀取能力。`roll`與開發用`validation-roll`均要求signed16整數`--raw`，並綁定明示或剛讀取的capture session；前後重連會拒絕寫入。

普通CLI／自動化Roll要求App控制權及**獨立Roll停止驗證**。相機已重新開啟，但本輪僅完成0→1→0單步回讀，`rollStopValidated`仍保持false；Pan/Tilt的既有驗證、普通Roll目標回讀或靜止保持不會把它設成true。MCP／App內AI的Roll工具與獨立實機驗證仍未完成，現有6個MCP工具不因此假稱已提供Roll。

## 本輪證據與剩餘

C session/interface的fake I/O＋AddressSanitizer已通過：[session](../artifacts/offline-roll-2026-09-09/c-session.log)、[interface](../artifacts/offline-roll-2026-09-09/c-interface.log)。build6完整軟體gate與三語UI亦已通過，後續按鈕等高修正及只讀設定整合以最新gate另記。實機[單步往返](../artifacts/hardware-roll-2026-09-09/one-step/result.json)有0→1→0、不同的新影格與恢復；不是物理角度或移動中Stop證據。

相機開啟後仍需：實際Roll讀取、小幅正／負調整與GET_DEF恢復、可見方向與圖像／物理效果、移動中Stop、失聯與重連，以及獨立AI開放條件。需與原生快速預設、pan/tilt校準、直幅格式分開驗收。
