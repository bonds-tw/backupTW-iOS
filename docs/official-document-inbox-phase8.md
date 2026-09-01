# 電子公文接收站 Phase 8：G2C 收件與送達生命週期開發沙盒

- 狀態：**DEBUG 技術沙盒已完成；法定送達未啟用**
- 日期：2026-09-01
- 範圍：非路由測試地址、EN／加密 ESW、測試來源簽章、DI 解密、本機模擬收文確認
- 不代表：主管機關註冊、政府交換地址、正式來源機關憑證、正式 ESW profile、網路送達或法定效力

## 這一階段完成什麼

在尚未申請主管機關介接以前，App 可先驗證收件端的技術生命週期：

1. 使用者在 DEBUG build 明確啟用一個以
   `G2C-SANDBOX-NOT-ROUTABLE-` 開頭的不可路由測試地址。
2. 測試 sender 建立 EN，附上 ESW 的 SHA-256，並以 repo 自有 Ed25519 測試金鑰簽署
   sender、receiver、service、application、subject 與 ESW digest 的 canonical target。
3. ESW 只含 AES-256-GCM 加密的 DI；App 先核對收件地址、hash 與 sender signature，全部通過
   才嘗試解密。
4. 解密後的 DI 與原始 EN／ESW 分開保存；原始交換邊界 bytes 不被解析模型取代。
5. 詳情頁可以記錄一次本機模擬收文確認，重複操作保持 idempotent，不送出任何網路請求。

這使 UI、archive、密碼學拒收條件與收文狀態可以先完成，但不會製造一個看似政府核發的地址或
送達證明。

## 強制邊界

- `environment = developmentG2CSandbox`
- `sourceAuthentication = verifiedDevelopmentSandboxKey`
- `contentAvailability = developmentSandboxDecrypted`
- `legalEffect = noneDevelopmentSimulation`
- registration、import 與 confirmation mutation 全部包在 `#if DEBUG`
- Release build 可以誠實顯示既有沙盒紀錄，但無法建立測試地址、匯入沙盒來文或推進確認
- sender key 是 repo 擁有的固定測試 key，不是政府機關憑證，也不使用官方交換地址簿冒充驗章
- confirmation 只寫入 App 的受保護本機 archive；沒有 transport、server receipt 或對外回覆

正式模式不會在缺少主管機關設定時退回沙盒：未來必須另加官方 schema/profile、正式地址註冊、
來源憑證信任鏈、recipient key、重送／退信契約與確認回覆 transport，才能形成不同的
`official` environment。

## 拒收條件

沙盒也採 fail closed；以下任一情形都不保存套件：

- registration version、地址前綴或字元限制不符
- EN receiver 與本機測試地址不一致
- EN 所列 ESW SHA-256 與收到的 bytes 不一致
- sender key id、演算法或 signature 不符
- ciphertext、nonce、authentication tag 或解密後 DI 無效
- application ID 與已保存來文相同、但 envelope bytes 不同

## UI 操作

1. 開啟「資料保險箱 → 電子公文」。
2. 點「啟用 G2C 沙盒收件」。
3. 在警示中確認「啟用並接收測試公文」。
4. 詳情頁應明確顯示「G2C 開發沙盒—不是法定送達」、來源測試 key 已驗證、內容已解密，
   法定效力為「無」。
5. 點「記錄模擬收文確認」後，畫面顯示本機確認時間與識別碼；不會對外傳送。

同一安裝的既有行動自然人憑證／實體自然人憑證同意證據不會被移除。

## 自動化證據

- Swift unit tests：正向加密收件與確認、錯誤收件地址、竄改 sender claim、明確 action wiring。
- UI test：從資料保險箱進入、啟用、收件、檢查無法定效力標示、記錄本機模擬確認。
- Release build：`#if DEBUG` 邊界可編譯，正式組態沒有沙盒建立／推進入口。
- 正體中文：新增文案均納入 string catalog 與 localization gate。

## 法規與正式介接門檻

本階段只對應開發測試。依檔案管理局公布的
[文書及檔案管理電腦化作業規範](https://www.archives.gov.tw/tw/arctw/156-1795.html)，正式交換仍涉及
來源與目的端識別、檔案 hash、加解密、憑證、重複來文處理、確認訊息與交換狀態等完整契約；
[機關公文電子交換作業辦法](https://www.archives.gov.tw/tw/arctw/155-1741.html)對人民、法人或非法人團體
作為收文者另保留由機關訂定作業規定的空間。因此，App 端自行產生的沙盒地址與本機確認不能被稱為
政府受理的個人電子公文接收站，也不能構成法定送達。

## 下一個完成門檻

1. 取得主管機關提供或核可的 G2C 測試環境、個人收件資格／地址註冊方式與資料規格。
2. 取得正式 sender signature profile、trust anchors／撤銷檢查、ESW recipient key lifecycle、
   acknowledgment 與 retry／退信契約。
3. 在隔離的 UAT environment 完成 sender → exchange → iPhone → acknowledgment 的完整往返，
   並由主管機關確認其效力與適用程序；在此以前維持 `noneDevelopmentSimulation`。
