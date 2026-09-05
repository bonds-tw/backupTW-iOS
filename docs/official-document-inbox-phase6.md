# 電子公文接收站 Phase 6：正式介接前置與主管機關交接包

- 狀態：**App／UAT 前置持續完成；正式個人收件仍等待主管機關資格與契約**
- 日期：2026-09-01
- 已完成：TestFlight build 1 的 UAT Worker allowlist、App Attest-only Worker 更新、公開交換地址簿嚴格解析與指紋、正式資料 fail-closed 邊界
- 尚未取得：自然人個人收件資格／地址、MOICA UAT SP credential、交換測試 endpoint／mTLS、來源簽章 profile、ESW recipient key、交換確認訊息契約

## 本輪 live 結果

### App Attest 與行動自然人憑證

- `signing-uat.mashbean.net` 已更新為 Worker version
  `c1a3ab1e-a8b1-44bf-a9a3-afb111544538`；公開 health、TLS、challenge 與
  `CFBundleVersion=1` live preflight 通過。
- UAT Worker 的 signing secret inventory 仍為空，`SIGNING_START_ENABLED=false`、
  `SIGNING_POLL_ENABLED=false`。本機 `~/.config/secrets/` 也沒有 MOICA SP credential。
- 因此現在可以做 TestFlight production App Attest register／assertion，但不能誠實啟用
  ATH-01／ATH-02。沒有以 placeholder secret 或 App 內 shared AES key 繞過。

### 公文交換地址簿

檔案管理局在政府資料開放平臺公告的地址簿每日更新，欄位為 `ORGID`、`ORGNAME`、
`STATUSCODE`、`UPDATETIME`。2026-09-01 live CSV 為 3,015,834 bytes、40,013 筆資料，
SHA-256：

`f37e32c9a7c7a1f62d98394bffc3d479683a4e46cbe27cd80fedd2aefd690fd2`

`OfficialDocumentAddressBookSnapshot` 現在會：

1. 限制 5 MiB／100,000 rows，嚴格解析 quoted CSV 與 UTF-8。
2. 要求固定四欄、唯一 ASCII `ORGID`、有界欄位與已知 `T`／`D`／`F` 狀態。
3. 只讓狀態 `T`、`ORGID` 與 `ORGNAME` 完全一致的 EN sender 產生 directory evidence。
4. 保存整份 snapshot SHA-256、資料列更新時間與檢查時間。
5. evidence scope 固定為 `activeDirectoryListingOnly`；它不能被 UI 或後續程式解讀成
   「這一份公文的來源簽章已驗證」。

官方來源：

- [公文電子交換系統地址簿資料集](https://data.gov.tw/dataset/7617)
- [每日 CSV](https://www.good.nat.gov.tw/regcenter/pub/addressbook/file/all_active_utf8.csv)

## 為什麼正式個人地址不能由 App 自己產生

現行公開規範要求參與交換者依主管機關程序申請並完成註冊，收文前須把憑證完整內容與
註冊的機關憑證資訊核對，交換機制須具備加解簽章、加解密、憑證註冊與收方自動回復訊息。
公開的線上申辦說明目前面向機關、公司行號、組織與人民團體；人民團體申請還要求 XCA
憑證與固定 IP。尚未找到讓單一自然人用自然人憑證自行取得 G2B2C 地址的公開流程。

因此「有備而來替自己產生一個地址字串」不會成為官方地址；「地址簿有這個機關」也不會
驗證一份 package 的來源。這兩種捷徑都維持拒絕。

官方依據：

- [文書及檔案管理電腦化作業規範](https://www.archives.gov.tw/tw/arctw/156-1795.html)
- [機關公文電子交換作業辦法](https://www.archives.gov.tw/tw/arctw/155-1741.html)
- [內政部：人民團體申請公文電子交換說明](https://www.moi.gov.tw/News_toggle3.aspx?n=8363&sms=9015&_CSN=1635)

## 主管機關需提供的最小介接包

以下七項缺一不可；收到後才能寫 concrete production adapter：

1. **資格與法律語意**：自然人個人是否能成為收件人、試辦依據、同意版本、法定送達時點、
   未讀／拒收／逾期與紙本 fallback。
2. **註冊契約**：UAT／production endpoint、request／response schema、核發的 receiving address、
   狀態查詢、撤回與重新核發。
3. **傳輸信任**：mTLS／IP allowlist、交換中心 trust anchors、憑證鏈／撤銷查核、換證與輪替。
4. **格式版本**：現行 EN／DI／SW／ESW／DM DTD 與標籤集、大小限制、canonicalization、
   signature container／algorithm 與測試向量。
5. **ESW 解密**：recipient key 的產生／保管位置、card identifier 對應、key wrapping／content
   encryption algorithm、rotation、lost-device revocation 與 recovery。
6. **交換確認**：收文確認訊息格式、簽章、application ID 冪等規則、timeout／retry／重複收文、
   unknown-result recovery 與正式 receipt identifier。
7. **測試證據**：官方 sender、測試地址、成功／篡改／撤銷／過期／重複／斷線 fixtures，及主管
   機關端可核對的 delivery／confirmation 紀錄。

## 可直接寄出的介接詢問草稿（尚未寄出）

主旨：詢問自然人個人電子公文接收服務試辦與 G2B2C 技術介接

> 您好，我們正在開發「有備而來」開源 iOS App，希望研究由自然人本人使用行動自然人憑證，
> 同意並接收特定機關電子公文的可行性。目前 App 已完成 EN／DI／ESW 原始資料保存、雜湊與
> 重複 application ID 防護、App Attest、行動自然人憑證 app-to-app 簽章，以及公開交換地址簿
> 的嚴格解析；所有正式收文功能在未取得主管機關資料前均維持關閉。
>
> 想請教：(1) 現行 G2B2C 是否允許自然人個人取得收件地址，或是否有可申請的試辦／合作機制；
> (2) 若可，申請資格、法律送達語意、測試環境與聯絡窗口；(3) 現行 EN／DI／SW／ESW／DM、
> 來源簽章、recipient key、地址註冊與交換確認的介接規格及測試資料如何取得。我們願意先以
> 單一機關、無密等文書、清楚紙本 fallback 的封閉 UAT 驗證，並提供安全與隱私設計供審查。

檔案管理局電子文書檔案服務中心公開聯絡方式包含 `support@archives.gov.tw`、
網路電話 `07010160017`；寄送前應由專案負責人確認組織身分、試辦範圍與對外署名。

## 下一個可以標綠的證據

- TestFlight 同一安裝連續兩次 App Attest PASS，並保存 Worker version／CPU／時間。
- MOICA 核發 UAT SP service ID／AES key 後，以互動方式寫入 Worker Secrets，先開 poll、再逐意圖
  驗 start→callback→poll；不得把 secret 放入 repo、App 或報告。
- 主管機關書面確認自然人收件資格並提供上述最小介接包；第一份官方 fixture 必須同時通過來源
  簽章、地址註冊、ESW 解密與確認回執，才可新增 `official` environment。
