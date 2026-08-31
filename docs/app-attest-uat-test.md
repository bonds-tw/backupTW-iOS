# App Attest UAT 真機驗收

- 狀態：**Xcode development 真機已通過；等待 TestFlight production 真機證據**
- 日期：2026-08-31
- 對應：[#42](https://github.com/bonds-tw/backupTW-iOS/issues/42)、[#47](https://github.com/bonds-tw/backupTW-iOS/issues/47)
- 不代表：MOICA UAT 可用、簽章 start／poll 已啟用、TestFlight 已上傳，或 App Store production category 已驗證

## 這個檢查會做什麼

「設定 → 診斷 → App Attest UAT 檢查」只有在使用者確認後才執行：

1. 從 code-signed Info.plist 讀取 reviewed endpoint；Debug 因 endpoint 為空而 fail closed。
2. 在這次安裝建立或沿用 App Attest key，必要時向 broker 完成 attestation／register。
3. 取得只綁定這個 installation 的一次性 assertion challenge。
4. 對固定的 `/v1/assertions/verify` request shape 產生 assertion。
5. Cloudflare 驗證 RP ID／environment、certificate／nonce／key、signature、challenge 與遞增 counter；production 另驗 launch metadata，成功只回 `{"verified":true}`。

固定 request 只有 `key_id`、`challenge`、`assertion_object`。沒有身分證字號、credential 欄位、零知識證明、MOICA 請求、待簽內容或 session token；後端也不會為這條路徑載入 signing secrets。

## 實機測試紀錄與下一步

### Xcode 直連 development 驗收

Apple Development provisioning 只能對應 development App Attest。以 Xcode 直連手機測試時，使用建置時明確覆寫的 `signing-dev.mashbean.net`；它沒有 signing secrets，start／poll 都關閉。這個結果不得當成 TestFlight category `2` 證據。

2026-08-31 23:09（Asia/Taipei），iPhone 14／iOS 27.0 以 Apple Development identity 對 `signing-dev.mashbean.net` 完成註冊，接著連續兩次 assertion 都回 200；physical-device XCTest 1 test、0 failures。實機產生的 attestation／assertion 沒有 Apple 2026 文件列出的 launch metadata，因此 dev broker 只在 `appattestdevelop` AAGUID 已驗證後，套用伺服器唯一固定的 category `3`／build `1` fallback。這個 fallback 不存在於 TestFlight UAT／production，不能當成實機直接證明 category／build 的證據。

人工操作仍是「設定 → 診斷 → App Attest UAT 檢查」，先確認畫面 endpoint 為 `signing-dev.mashbean.net`，接著連續成功執行兩次以驗證註冊與遞增 counter。

### TestFlight production 驗收

1. 安裝實際 TestFlight build，不要用 Simulator 或 Xcode Debug build 代替。
2. 開啟「設定 → 診斷 → App Attest UAT 檢查」。確認畫面上的 endpoint 是 `signing-uat.mashbean.net`，App build 與待測 TestFlight 一致。
3. 點「執行 App Attest 檢查」，閱讀資料邊界後確認。
4. 成功時按右上角複製。報告應只有 result、endpoint、App／iOS 版本、時間，以及兩個 `false` 邊界；不得有 key ID、challenge、assertion 或個資。
5. 不刪 App 再執行一次；第二次應沿用註冊並以更高 counter 通過。
6. 更新 App 後重做一次。再以「刪除 App → 重裝」重做，確認舊 installation 不會被誤當成新 key。

測試紀錄至少保存：TestFlight build number、裝置型號、iOS 版本、時間、endpoint、App 內安全報告，以及對應時段的 Cloudflare invocation／CPU 指標。App 報告的 `PASS` 只證明 App Attest UAT 連線與 counter；不證明 MOICA ATH-01／ATH-02 或簽章成功。

## Fail-closed 預期

| 情境 | 預期 |
| --- | --- |
| Debug／未設定 endpoint | `configuration_missing`，不發網路 request |
| 裝置不支援 App Attest | `app_attest_unsupported` |
| development build 打 production UAT | server `attestation_invalid` |
| TestFlight build 不在 allowlist | server `attestation_invalid` |
| challenge 重用或 counter rollback | server `challenge_used`／`replay_detected`，不自動重註冊繞過 |
| UAT 無法連線或 response shape／headers 不合約 | `network_unavailable`／`invalid_response` |

## 上傳前仍需完成

- 從實際 archive 讀取 `CFBundleVersion`，以 `BONDS_EXPECTED_UAT_BUNDLE_VERSION` 跑 broker live preflight；本機 target 的 build number 不是替代證據。
- 確認 archive 的 bundle ID、App Attest entitlement、UAT endpoint 與 secret／local-provider canary scan。
- Apple 帳號必須能建立 App Store distribution archive 並上傳；只有 Apple Development identity 不足以宣稱 TestFlight ready。
- 上傳後仍要等 processing 完成並確認 tester 可安裝，才算 TestFlight 發佈完成。
