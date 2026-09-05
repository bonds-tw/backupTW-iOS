# 電子公文接收站 Phase 5：同意證據重驗與本機生命週期

- 狀態：**App 端已實作**
- 日期：2026-09-01
- 範圍：保存證據每次讀取重驗、簽章範圍與 SHA-256 指紋檢視、防止重複簽署覆寫、只刪本機證據的明確生命週期
- 不代表：已向政府註冊、已核發收件地址、已撤回政府端紀錄、已收到正式公文，或法定送達成立

## 為什麼這一階段先做證據生命週期

前四階段已經能建立行動自然人憑證簽章、保存 receipt，並以 App Attest
broker 承接 Release 路徑。但「JSON 可以 decode」不等於「簽章證據仍可信」；原本畫面也會在
receipt 存在時繼續顯示簽署動作，可能讓第二次簽章直接覆寫第一次證據。

這一階段先把本機能誠實完成的部分收好：

1. `OfficialDocumentInboxArchive.receipt()` 每次讀取都重驗 MOICA G3 certificate chain、
   receipt construction、32-byte one-use nonce、簽章與帶上限的簽署時間關係。
2. 驗證失敗時不顯示「已簽署」，也不允許再簽一份覆寫原檔。
3. 已簽署時，原動作改成「查看已簽署的同意證據」，不再啟動第二次行動自然人憑證請求。
4. 證據頁只顯示同意、certificate 與 signature 的 SHA-256 指紋，不顯示或分享原始
   certificate／signature，也不保存身分證統一編號；畫面同時告知 certificate 指紋具有
   跨簽章可連結性，App 不傳送、記錄或分享這些指紋。
5. 使用者可以刪除這支 iPhone 上的試辦 certificate／signature；合成公文套件不會一起被刪除。

## 刪除不是撤回

畫面刻意使用「從這支 iPhone 移除同意證據」，不使用「撤回申請」或「停用公文匣」。
目前沒有正式公文匣可以撤回，App 也沒有權限刪除內政部因行動自然人憑證服務留下的紀錄。
若未來 G2C 服務提供註冊與撤回 API，必須以新的政府端 receipt／status model 實作，不能把
今天的本機刪檔函式接上去並改文案。

## 與現行公文交換規範的邊界

檔案管理局現行規範要求交換系統包含雜湊檢核、重複收文停止後續處理、收文確認、自動狀態、
地址簿、全程加密、資料維護、身分權限與憑證註冊。Phase 5 只強化本機同意證據，沒有把它
誤稱為上述任一交換能力。

官方參考：

- [文書及檔案管理電腦化作業規範](https://www.archives.gov.tw/tw/arctw/156-1795.html)
- [機關公文電子交換作業辦法](https://www.archives.gov.tw/tw/arctw/155-1741.html)
- [內政部行動自然人憑證系統介接申請要點修正說明](https://moica.nat.gov.tw/news_in_18a0249785700000a5f7.html)

## 自動化證據

測試覆蓋：

- 真實 throwaway RSA-2048 fixture 對同意 TBS 簽章後可重驗。
- 換 nonce、沿用原 signature 會被拒絕。
- consent／certificate／signature 指紋固定為 64 位 hex，UI 不持有原始值。
- 不合法 nonce／時間 metadata 在載入 trust anchor 前即 fail closed。
- archive 不以未驗證 receipt 覆寫已保存證據。
- 移除本機 receipt 後，EN／DI／ESW 合成套件仍保留。
- 已簽署的畫面進入證據頁，不會再次開始簽章。
- 新增文案皆有正體中文。

## 下一個完成門檻

1. 完成 TestFlight production App Attest 與 MOICA UAT start→callback→poll；這是簽章通道門檻，
   不是 G2C 註冊證據。
2. 取得 G2C／G2B2C 正式介接窗口、測試資格、現行 DTD／標籤集、地址簿、來源簽章、
   ESW 解密與收文確認契約。
3. 由主管機關提供私人收件的同意版本、註冊 response、收件地址、狀態查詢、撤回與紙本
   fallback 語意後，再新增 `official` environment；在此之前維持 `localPrototypeOnly`／
   `syntheticFixtureOnly` fail closed。

正式介接的 live 查核、公開地址簿元件與主管機關最小交接包接續記錄於
[`official-document-inbox-phase6.md`](official-document-inbox-phase6.md)。
