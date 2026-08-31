# 電子公文接收站 Phase 4：不透明簽章工作階段與 Release 組裝

- 狀態：**iOS 端 opaque handle、遠端 broker session 與 fail-closed Release 組裝已實作**
- 日期：2026-08-31
- 對應：[#45](https://github.com/bonds-tw/backupTW-iOS/issues/45)
- 範圍：local／remote transport capability 分離、broker expiry、callback transaction 解碼、三條 Release 簽章路徑、重試語意、Release binary canary scan
- 不代表：Cloudflare UAT 已部署、`signing-uat.bonds.tw` 已可連線、真實 App Attest／TestFlight 已通過、MOICA UAT 已互通，或電子公文已取得法定送達介接

## 本階段結果

`TWFidOSignSession` 不再把所有 transport 都偽裝成 `TWFidOTicket`。共用流程現在只取得 `TWFidOSignHandle`：

| Handle 內部能力 | DEBUG 本機 transport | Release broker transport |
| --- | --- | --- |
| 流程可見 | transaction ID、到期時間 | transaction ID、到期時間 |
| transport 私有 | MOICA ticket claims | broker bearer session token |
| 錯誤 transport 使用 | 拒絕 | 拒絕 |
| 字串／reflection | 固定顯示 redacted | 固定顯示 redacted |

Storage 是 private enum；remote session token 不再塞進 `spTicket`，也沒有以全域 side table 把 token 掛在假 ticket 上。Local transport 只能取出 local ticket，broker transport 只能取出 remote token，型別錯用會在發網路 request 前失敗。

Broker 回傳的 `expires_at` 也進入 handle。Credential、ZK 與電子公文同意三條流程都取 server expiry 與 client fallback deadline 的較早者，因此不會在 server session 已失效後繼續等待。

## Release 組裝

三個 Release entry point 現在共用 `SigningBrokerSessionAssembly`：

- 身分證 credential 簽發 `CredentialIssuanceAssembly`
- ZK holding proof `ZKProofRunAssembly`
- 電子公文接收站同意 `OfficialDocumentSigningAssembly`

Assembly 只從 code-signed Info.plist 讀取 allowlist 內的 HTTPS host，再建立 App Attest broker transport。它不讀環境變數、不讀本機 SP credential、不接受 runtime 任意 URL，也沒有失敗後改走 DEBUG signer 的 fallback。

目前 App 的 Info.plist 尚未設定 `BondsSigningBrokerBaseURL`，所以 Release 三條路徑仍會 fail closed、UI 顯示後端尚未連接。這是部署前的預期狀態，不是可用的遠端簽章證據。

## Callback 修正

MOICA deep link 的 `rtn_val` 是 transaction ID 的 base64url 表示，不是 raw transaction ID。Client 現在會先限制 encoded 長度，再 base64url decode、驗 UTF-8／長度／控制字元，最後才把 raw transaction ID 交給 callback router。

這個修正避免「行動自然人憑證已跳回 App，但 router 等的是另一個字串」的情況。Callback 仍然只用來提早觸發 poll；它不是簽章成功證據，certificate／signature 仍必須由 broker poll 取得並由 App 以 pinned MOI trust anchor 驗證。

## 重試與未知結果

- Retryable poll failure 可在同一 deadline 內重試。
- Terminal broker error 立即停止。
- Start 不會因 poll 失敗自動重送；未知結果不會建立第二個 MOICA prompt。
- Task cancellation 仍會清掉 callback waiter。
- ZK 的 `signatureMaterialIsReplayable` caveat 保留；換成 remote broker 不會讓固定 app ID 簽章突然綁定 verifier challenge。

## 自動化證據

測試目前覆蓋：

- Remote handle 保存 transaction／expiry，但字串與 reflection 不洩漏 bearer token。
- Local handle 交給 broker 時，在呼叫 transport 前以 `wrongTransport` 拒絕。
- Broker polling 使用原 remote token；server expiry 可縮短 client deadline。
- MOICA `rtn_val` 正確 base64url decode；raw／不合法值被拒絕。
- Release assembly 接受 reviewed `signing-uat.bonds.tw`，拒絕任意 hostname。
- Credential 與 ZK 的 retryable／terminal poll 行為；retryable unknown result 不重送 start。
- 既有 credential TBS、固定 ZK app ID、電子公文同意 receipt 與錯誤／逾時案例持續通過。

CI 新增獨立 Release simulator build。建置環境刻意放入 SP service ID／AES key canary，再掃描成品 binary；若 local provider 類名、環境變數名、credential filename 或 canary 出現在 Release 成品，CI 會失敗。這是 simulator binary 邊界，仍須在 TestFlight archive／IPA 再做一次相同檢查。

## 下一個完成門檻

1. 依 `bonds-signing-broker` runbook 完成 Cloudflare UAT first deploy；保留 `SIGNING_START_ENABLED=false`，保存 custom domain certificate、deployment version 與 `/healthz` 證據。
2. 從實際 TestFlight archive 取得 `CFBundleVersion` allowlist，才把 reviewed `https://signing-uat.bonds.tw` 寫入該組態；不可把本機 dev endpoint 帶進 TestFlight。
3. 真實 iPhone 依序驗 development App Attest、TestFlight category `2`、counter、reinstall、App update 與 unsupported device fail-closed。
4. 完成 secrets／SP 管理者核准與 log redaction 抽查後，才在 UAT 開啟 signing start。
5. 以 MOICA UAT 驗 ATH-01／ATH-02 pending、success、拒絕、timeout、callback、斷網與 unknown-result；確認 repeat-poll 行為且不產生第二張 ticket。
6. 三條意圖各自做真機 start→跳轉→callback→poll；App 端 pinned MOI certificate／signature 驗證必須實際通過。
7. TestFlight IPA 重做 secret／local-provider scan，並保留 Reduce Motion 與錯誤文案驗收證據。
