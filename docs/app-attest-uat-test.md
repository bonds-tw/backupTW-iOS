# App Attest UAT 真機驗收

- 狀態：**Xcode development 真機已通過；等待 TestFlight production 真機證據**
- 日期：2026-09-01
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

2026-08-31 23:05（Asia/Taipei；App 報告 `2026-08-31T15:05:00.076Z`），同一台 iPhone 的人工診斷第一次回 `server_attestation_invalid`。證據截圖的 SHA-256 是 `00de9d9bd8d9b983eb35a4f85d955809b371d12be8bcd5643e07a2f4ebade61`；截圖保留在使用者本機，未上傳 public repo。這個失敗發生在 development Worker 相容修正部署前；與前後版本差異及後續真機通過結果比對，原因是 iOS 27 development attestation／assertion 沒有 Apple 2026 文件列出的 launch metadata，而舊 parser 仍要求該欄位。這筆紀錄不能算 PASS，也不應被後續成功覆蓋。

2026-08-31 23:09，dev broker 加入 development-only 相容路徑後，iPhone 14／iOS 27.0 以 Apple Development identity 對 `signing-dev.mashbean.net` 完成註冊，接著連續兩次 assertion 都回 200；physical-device XCTest 1 test、0 failures。相容路徑只在 `appattestdevelop` AAGUID 已驗證後，套用伺服器唯一固定的 category `3`／build `1` fallback。這個 fallback 不存在於 TestFlight UAT／production，不能當成實機直接證明 category／build 的證據。

人工操作仍是「設定 → 診斷 → App Attest UAT 檢查」，先確認畫面 endpoint 為 `signing-dev.mashbean.net`，接著連續成功執行兩次以驗證註冊與遞增 counter。

### Release archive 前置驗收

2026-09-01 以 Xcode 26.6 從乾淨、隔離的 DerivedData 成功建立 generic iOS Release archive。實際封存內容是 `tw.bonds.backupTW`、版本 `1.0 (1)`，endpoint 為 `https://signing-uat.mashbean.net`；App Attest entitlement 存在，binary strings 也找不到 local signing provider、SP credential 環境變數、credential filename 或 CI canary。以 archive 的 `CFBundleVersion=1` 執行 broker live preflight 已通過：UAT 使用 production App Attest、allowlist 只含 build `1`、無 signing secret bindings，start／poll 都維持關閉。

本機 archive 目前仍由 Apple Development identity 簽署。[Apple 文件](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.devicecheck.appattest-environment)指出，經 TestFlight、App Store 或 Enterprise 發行後，App 會忽略 entitlement 的 source value 並使用 production App Attest；因此 archive 內看到 `development` 不能當成 TestFlight environment 的失敗，也不能當成已通過的證據。Xcode 的 Validate App 尚未完成：CLI 回報團隊 `538MCM44UX` 缺少可用的 App Store Connect account access。必須先在 Xcode 補齊對該團隊的 App Store Connect 權限，再由 distribution workflow 重簽、驗證與上傳。

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

## 上傳前狀態

- 已從實際 archive 讀取 `CFBundleVersion=1`，並以 `BONDS_EXPECTED_UAT_BUNDLE_VERSION=1` 通過 broker live preflight。
- 已確認 archive 的 bundle ID、App Attest entitlement、UAT endpoint 與 secret／local-provider canary scan。
- 尚未通過 Validate App：Apple 帳號必須具有團隊 `538MCM44UX` 的 App Store Connect access；只有 Apple Development identity 不足以宣稱 TestFlight ready。
- 上傳後仍要等 processing 完成並確認 tester 可安裝，才算 TestFlight 發佈完成。
