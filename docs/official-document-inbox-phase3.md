# 電子公文接收站 Phase 3：App Attest 簽章通道

- 狀態：**App 端 transport 與 fail-closed 邊界已實作**
- 日期：2026-08-31
- 範圍：App Attest key lifecycle、Keychain state、attestation/register、逐次 assertion、canonical signing request、固定 intent、ephemeral HTTPS transport、counter 次序序列化
- 不代表：TestFlight production attestation 已通過、Release 簽章已啟用、MOICA UAT 已互通，或電子公文正式介接成立

## 已實作

`AppAttestSigningBrokerTransport` 現在可以承接三種既有簽章流程：

- `national_id_credential_v1`
- `zk_holding_proof_v1`
- `official_document_inbox_consent_v1`

Transport 會先確認裝置支援 App Attest，再產生 key、保存 key ID 與未完成的 attestation state，向 broker 取得一次性 challenge，完成 Apple attestation/register。之後每次 start／poll 都先取得新的 assertion challenge，依 API v1 產生排序且無空白的 canonical JSON、計算 SHA-256，再呼叫 `generateAssertion`。

同一把 key 的完整 request 由可取消的 gate 序列化，不只把 `generateAssertion` 包在 actor 裡。這是因為 Swift actor 在 `await` 時可以重入；若只依賴 actor，兩個 request 仍可能交錯送達後端，使 App Attest counter 較大的 assertion 先被消耗，較小的下一個 request 被判定 rollback。

## Key lifecycle

- Key ID、endpoint scope、registered flag、尚未送達 broker 的 challenge／attestation object 暫存在 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、`ThisDeviceOnly` Keychain item，不進 iCloud Keychain。
- Apple 回 `serverUnavailable` 時保留同一 key、同一 challenge 與同一 client-data hash；下一次在 challenge 有效期內以相同輸入重試。
- Apple 回 invalid key、App 重裝後舊 key 不可用，或 broker 已無 installation 時，忘記舊 key 並只重建一次。
- `replay_detected`／counter rollback 不會觸發自動換 key；它會 fail closed，避免用重註冊繞過 replay 訊號。
- App Attest key 是安裝實例完整性證據，不是使用者帳號，也不與 MyData 原始檔、卡片內容或電子公文套件一起上傳。

## HTTP 與資料邊界

- 只允許 code-signed Info.plist 選擇三個 `bonds.tw` hostname 或暫用的 `signing-uat.mashbean.net`；Release 已固定填入後者，不能由 runtime 任意改 URL。
- URLSession 使用 ephemeral storage、無 cache、無 cookie，所有 response 必須是 JSON 且帶 `Cache-Control: no-store`。
- 禁止 HTTP redirect，避免帶有身分證統一編號的 POST body 被 307／308 轉送到其他 host。
- Client 不持有 SP service ID／AES key，也不接受任意 provider URL、hint、callback 或 signing target。
- Broker 回傳的 certificate／signature 只留在當次流程；`hashed_id_num` 不在 API response。

## App Attest 現行格式

後端已同步驗證 Apple 2026 文件新增的 launch metadata：attestation 的 `apple_validation_category_01`／`apple_bundle_version_01`，以及 assertion 的 `validationCategory`／`bundleVersion`。TestFlight UAT、App Store production 分別只接受 category `2`、`4`，並明列 `CFBundleVersion` allowlist；certificate public key 與 authenticator-data COSE public key 都必須對上 key ID。

2026-08-31 的 iPhone 14／iOS 27.0 development attestation／assertion 都未帶上述 metadata。隔離的 dev broker 因此只在 `appattestdevelop` AAGUID 已驗證後，使用伺服器唯一固定的 category `3`／build `1` fallback；UAT／production 沒有此相容路徑，缺 metadata 仍會拒絕。development 真機已通過註冊與連續兩次 assertion，但這不是 TestFlight category `2` 證據。

App target 已加入 App Attest entitlement，source value 為 `development`。Apple 文件指出，經 TestFlight、App Store 或 Enterprise 發行後會忽略這個 source value 並使用 production environment；這仍須以真機 TestFlight attestation 與後端紀錄作為完成證據。

## 本階段驗證

測試覆蓋：

- 首次 key／attestation／register、後續 key 重用。
- Start／poll canonical body 與 assertion hash。
- Apple `serverUnavailable` 同 key／同 hash 重試。
- reinstall／invalid key 重建。
- unsupported device 在任何網路或 key 操作前 fail closed。
- replay rejection 不換 key。
- 並行 assertion 排隊與排隊中 cancellation。
- HTTPS endpoint、response no-store／JSON、deep-link transaction ID、certificate／signature 大小與 base64 邊界。

這些是 protocol stub 與模擬器證據，不是 Apple 真實 attestation，也不是 MOICA 互通證據。

## 後續狀態

Cloudflare Workers Free + SQLite-backed Durable Objects 已部署為 UAT／低流量試辦 runtime；公開 health 與 App Attest challenge 已通過，signing secrets、start 與 poll 維持關閉。#45 的 opaque local／remote handle、三條 Release remote-only assembly 與 binary canary scan 已在 [Phase 4](official-document-inbox-phase4.md) 完成。

後續完成門檻因此收斂為：真機 development／TestFlight production App Attest、MOICA UAT ATH-01／ATH-02，以及 TestFlight IPA 與 Reduce Motion 驗收。開始簽章結果不明時仍不得自動建立第二張 ticket。

## 主要參考

- [Apple：Establishing your app’s integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [Apple：Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [Apple：App Attest Environment entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.devicecheck.appattest-environment)
