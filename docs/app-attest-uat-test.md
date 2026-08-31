# App Attest UAT 真機驗收

- 狀態：**App／Cloudflare 的無個資檢查鏈已實作；等待 TestFlight 真機證據**
- 日期：2026-08-31
- 對應：[#42](https://github.com/bonds-tw/backupTW-iOS/issues/42)、[#47](https://github.com/bonds-tw/backupTW-iOS/issues/47)
- 不代表：MOICA UAT 可用、簽章 start／poll 已啟用、TestFlight 已上傳，或 App Store production category 已驗證

## 這個檢查會做什麼

「設定 → 診斷 → App Attest UAT 檢查」只有在使用者確認後才執行：

1. 從 code-signed Info.plist 讀取 reviewed endpoint；Debug 因 endpoint 為空而 fail closed。
2. 在這次安裝建立或沿用 App Attest key，必要時向 broker 完成 attestation／register。
3. 取得只綁定這個 installation 的一次性 assertion challenge。
4. 對固定的 `/v1/assertions/verify` request shape 產生 assertion。
5. Cloudflare UAT 驗證 signature、validation category、`CFBundleVersion`、challenge 與遞增 counter，成功只回 `{"verified":true}`。

固定 request 只有 `key_id`、`challenge`、`assertion_object`。沒有身分證字號、credential 欄位、零知識證明、MOICA 請求、待簽內容或 session token；後端也不會為這條路徑載入 signing secrets。

## 晚點真機測試

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
