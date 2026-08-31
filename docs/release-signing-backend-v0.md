# ADR：Release 簽章與 bonds 後端 v0

- 狀態：**已採用**
- 日期：2026-08-31
- 對應：[#38](https://github.com/bonds-tw/backupTW-iOS/issues/38)
- 完成範圍：架構、責任邊界、API 與估工已定；**服務尚未建立、Release 簽章尚未可用、TestFlight 尚未驗收**

## 決策

有備而來的出貨版本採用一個獨立的 `bonds-signing-broker`，專門代理行動自然人憑證 ATH-01／ATH-02：

- SP service ID 與 AES-256 key 只存在後端；App 不得取得 `sp_checksum` 或 `idp_checksum` 的等價能力。
- 正式服務以 Google Cloud Run `asia-east1`（台灣）為目標，SP key 使用同區域的 Regional Secret Manager；正式 API 不經 Cloudflare proxy。
- iOS 以 App Attest 為敏感 API 的裝置／App 完整性門檻。Release 裝置不支援或無法完成 App Attest 時，保留查驗能力，但簽發身分證與建立 ZK 證明必須 fail closed。
- 後端只接受兩種固定簽章意圖，不提供任意 `sign_data`、任意提示文字或 push 介面。
- ZK challenge、nullifier 政策、verifying key 發布與撤銷 root 錨定各自留在正確的信任邊界，不塞進簽章代理。

後端的第一個正式版本不重用 `bonds-wall` Worker，也不重用個人的 OIDC4VP verifier。三者處理的資料、管理者、生命週期與失效半徑不同，合併只會把身分證統一編號帶進原本刻意不識別簽署者的服務。

## 為什麼現在需要後端

現有程式已經把危險路徑隔開，而不是缺少一個設定值：

- `backupTW/TWFidO/SPSecrets.swift` 整檔在 `#if DEBUG` 內；正式 archive 不會編入本機 SP credential provider。
- `backupTW/TWFidO/TWFidOConfiguration.swift` 的 Release provider 固定丟出 `requiresBackend`。原因是取得 AES key 的人可以冒用 bonds-tw 對任意身分證統一編號送出簽章提示。
- `backupTW/Model/CredentialIssuance.swift` 與 `backupTW/ZK/ZKProofRunWiring.swift` 已共用 `TWFidOSignSession` 抽象；Release 目前刻意不組裝 live signer。
- 本機流程不只產生 `sp_checksum`，還會用同一把 SP key 驗證 ATH-02 的 `idp_checksum`。只把「開始簽章」搬到後端、結果仍在 App 驗證，仍然會把解密／驗證能力帶回出貨 binary，不能接受。

因此 v0 必須代理完整的 ATH-01 開始與 ATH-02 查詢，並在後端完成 provider response 驗證；App 收到的 certificate 與 signature 仍須再用內建的內政部 trust anchor 驗證一次，作為不同金鑰體系的 defense in depth。

## 部署拓樸

| 元件 | v0 選擇 | 保存內容 |
| --- | --- | --- |
| Mobile API | 獨立 Cloud Run service，`asia-east1` | 不保存 request body |
| DNS | `bonds.tw` DNS 可由 Cloudflare 管理，但 API record 不開 proxy | 無 |
| SP secret | Regional Secret Manager，`asia-east1`，以明確 version 讀取 | service ID、SP AES key、自有 session-token key |
| App Attest registry | Firestore regional database，`asia-east1` | key ID hash、public key、receipt、environment、last counter、建立／最後使用時間 |
| 一次性 challenge／冪等紀錄 | Firestore TTL document | challenge hash、request hash、加密 session token、到期時間；不含身分證統一編號 |
| FidO session | AES-GCM 加密且帶版本的 opaque token，由 App 暫持 | MOI transaction／ticket、intent、key version、App Attest key hash、到期時間 |
| 簽章結果 | 不寫資料庫或 object storage | ATH-02 當次驗證通過後直接回 App |

[Cloud Run 官方位置表](https://cloud.google.com/run/docs/locations)列出 `asia-east1`（台灣），並說明 Cloud Run resource 的 associated customer data 存在所選區域；[Regional Secret Manager](https://cloud.google.com/secret-manager/regional-secrets/data-residency)則可讓 secret 的靜態、使用中與傳輸處理維持在指定區域。這些平台說明仍不能取代正式的個資／契約審查；production go-live 前要再確認內政部 SP 契約、Google Cloud data processing terms 與實際 logging 設定。

不以 Cloudflare Worker／Durable Object 承載 v0 的理由是：Cloudflare Durable Objects 的 APAC 只能設定 location hint，並非台灣 jurisdiction guarantee；SQLite Durable Objects 又提供約 30 日 point-in-time recovery。即使 live storage 能清掉，也不符合本案對短生命週期簽章 session 的直觀刪除承諾。參考 [Durable Objects data location](https://developers.cloudflare.com/durable-objects/reference/data-location/) 與 [storage／PITR 說明](https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/)。

## 責任邊界

| 能力 | iOS App | Signing broker | 查驗方／Wall | 公開資產／上游 |
| --- | --- | --- | --- | --- |
| 使用者確認與 Face ID／裝置密碼 | 執行並顯示目的 | 不代替使用者同意 | 不負責 | — |
| App 完整性 | 產生 App Attest key、attestation、逐次 assertion | 驗 certificate chain、RP ID、AAGUID、key ID、counter、challenge 與 canonical request hash | — | Apple App Attest root／service |
| 身分證統一編號 | 僅在使用者啟動簽章時送出 | 只在 ATH-01 request 記憶體內處理；不得 log／persist | 不得收到 | 內政部 FidO 仍會收到 |
| SP AES key／checksum | 永遠不得持有 | 以固定版本 secret 產生 `sp_checksum`、驗 `idp_checksum` | 不得持有 | 內政部與 bonds-tw SP 管理者 |
| 簽章目標 | 建立 credential TBS，或選擇 ZK holding proof intent | 依 allowlist 重建／檢查實際 `sign_data`；拒絕任意字串 | 不得要求 broker 任意代簽 | — |
| Certificate／signature | 以 pinned MOI trust anchor 再驗一次；只為目前流程使用 | ATH-02 驗 checksum 後直接回傳，不保存 | 只收到使用者明確出示的證明 | MOI CA trust anchor |
| ZK challenge | 接受查驗方提供的 challenge | **不發放**，也不宣稱把它簽進 FidO signature | 每個 relying party 自己發放、驗證與消耗 | 公開訊號 FFI 必須先完成 |
| Verifying key | 由使用者明確安裝，逐檔驗 pinned hash／manifest | **不承載、不授權** | 驗證端安裝 public key material | 公開唯讀發布來源 |
| Nullifier | 本機產生 proof，不上傳到 generic broker | **不蒐集、不做全域去重** | 只有在 verifier-scoped 設計完成後，個別 relying party 才能依目的保存 | 上游先匯出 public signals |
| 撤銷 root | 顯示目前 caveat，不可誤稱已鏈上核對 | **不是撤銷 authority** | 比對 proof public root 與公開錨定 | 鏈上／registry publisher；須先有 public signals FFI |

這個切法刻意不把 signing broker 變成新的身分中心。它看得到一次 ATH-01 所需的身分證統一編號，但不應同時看得到使用者去過哪個查驗方、哪個 nullifier 或哪份 MyData 原始文件。

## 允許的兩種簽章意圖

API 不接受任意 `hint` 或任意 `sign_data`，只接受以下 discriminated union：

1. `zk_holding_proof_v1`
   - 後端固定使用 `TWFidOConfiguration.bondsAppID`：`55349ff540392a077ca3dcc9bbda4c3`。
   - 後端固定繁體中文提示；client 不能覆寫。
   - 這仍然只簽固定 relying-party identifier，沒有簽 verifier challenge；`signatureMaterialIsReplayable` caveat 必須保留。
2. `national_id_credential_v1`
   - App 傳完整 `bonds-tw-credential-v1:<64 lowercase hex>` TBS。
   - 後端嚴格驗 prefix、總長、字元集與 API version，再送交 FidO。
   - 後端固定繁體中文提示；client 不能覆寫。

v0 不做 ATH-03 push、不收 device alias、不讓呼叫端指定 return URL。回到 App 的 URL scheme 與提示文字都由 server-side configuration 固定，避免把服務做成任意推播／簽章 oracle。

## API v1

所有 endpoint 都是 HTTPS、JSON、`Cache-Control: no-store`；身分證統一編號與 opaque session token 不得放在 URL、query string、error message 或 telemetry。

### App Attest 註冊

- `POST /v1/attest/challenge`
  - 回傳至少 32 bytes entropy 的短效、簽章 challenge token。
- `POST /v1/attest/register`
  - 輸入：challenge token、App Attest key ID、attestation object。
  - 驗證：Apple chain、nonce、RP ID、AAGUID、credential ID、counter `== 0`。
  - key record 為 create-only；相同 key 的完全相同重送可冪等成功，但不得重設 counter 或換 environment。

Apple 要求 server 發放 unique one-time challenge、保存已驗證的 public key／receipt，且 assertion counter 必須嚴格增加；development 與 production key 也必須分開。以 [Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server) 為實作規範，不自行縮減驗證步驟。

### 敏感 request challenge

- `POST /v1/assertions/challenge`
  - 輸入：App Attest key ID。
  - 回傳短效 one-time challenge。
  - challenge redemption 與 assertion counter 更新在同一個 Firestore transaction 內完成。

### 開始簽章

- `POST /v1/signatures/start`
  - 輸入：`request_id`、App Attest key ID、assertion、assertion challenge、身分證統一編號、intent。
  - assertion 的 `clientData` 必須涵蓋 API version、HTTP method、path、challenge、request ID、canonical body hash。
  - 回傳：opaque `session_token`、固定 return scheme 的 FidO deep link、`expires_at`。
  - `request_id` 在同一 App Attest installation 及 TTL 內冪等；相同 ID 配不同 body hash 回 `409 replay_detected`。

### 查詢結果

- `POST /v1/signatures/poll`
  - 輸入：App Attest assertion／challenge 與 `session_token`。
  - 後端解密 token、核對 expiration、installation hash、intent 與 SP key version，再呼叫 ATH-02。
  - `pending` 時不回 certificate／signature。
  - `complete` 時先驗 `idp_checksum`，再直接回 certificate、signed response 與必要 metadata；不持久化結果。

`session_token` 的 encryption key 與 SP AES key 分離。token 使用版本化 AES-256-GCM、隨機 nonce 與固定 API version AAD；任何 authentication failure 一律回 generic invalid／expired，不暴露內部欄位。

iOS 端要以 actor 序列化同一 App Attest key 的 assertion 產生與送出，避免兩個並行 request 以顛倒順序到達，使正常的較小 counter 被 server 判為 replay。

## 驗證與重放防護

- App Attest 是高風險 endpoint 的必要條件，不是使用者身分證明；Face ID／裝置密碼與行動自然人憑證的確認仍各自存在。
- 每次 register／start／poll 都有 server challenge；start／poll assertion 綁完整 canonical request，而不只綁 path。
- start 有 App installation-scoped idempotency key，避免斷線重按產生兩個 FidO prompt。
- session token 綁 App Attest key hash，不能拿到另一台裝置 poll。
- ATH-02 response 必須先以該 session 的 SP key version 驗 `idp_checksum`，才能回 App。
- App 仍用 MOI trust anchor 驗 certificate 與 signature。兩層驗證保護不同邊界，不能互相取代。
- App Attest 不支援、production attestation 失敗、counter 倒退或 challenge 重放時，Release 簽章一律不可用；不得退回 shared API key、DeviceCheck token、匿名 endpoint 或 DEBUG secret。

## 錯誤模型

對外只回穩定的 machine code、繁中可顯示分類、`retryable` 與 `request_id`；不得回 MOI raw response、exception、身分證統一編號或 ticket。

| HTTP | code | 是否重試 | App 行為 |
| --- | --- | --- | --- |
| 400 | `invalid_request` | 否 | 不送 FidO 前指出版本／資料格式錯誤 |
| 401 | `attestation_required`／`assertion_invalid` | 重新註冊後才可 | 簽章不可用，不降級 |
| 409 | `replay_detected`／`idempotency_conflict` | 否 | 停止並要求重新開始 |
| 410 | `session_expired` | 否 | 說明簽章工作階段已逾時 |
| 422 | `provider_rejected` | 視 safe subcode | 顯示拒絕／取消／卡片狀態，不顯示 raw provider code |
| 429 | `rate_limited` | 是，遵守 `Retry-After` | 不自動重送 start |
| 502 | `provider_response_invalid` | 否 | 視為完整性錯誤，告警 |
| 503 | `signing_unavailable` | 是 | 保留查驗能力；不假裝已簽發 |
| 200 | `pending`／`complete` | poll 可重試 | 不用新的 start request 重試 poll |

ATH-02 完成後是否能以同一 ticket 重複取得同一結果，必須在 UAT 實測。確認前，網路中斷發生在 server 已驗完、client 未收到結果時要顯示「結果未知」，不得自動重開新的簽章。若 provider 不能重複 poll，才另開 ADR 評估短暫 encrypted result buffer；不能為了方便直接把 certificate／signature 寫進長期 datastore。

## 保存、記錄與監控

### 保存政策

- 身分證統一編號：application code 不持久化、不放 log、不放 trace attribute、不放 metric label；只存在 start request 與呼叫 ATH-01 的記憶體生命週期。
- FidO transaction／ticket：只在 client 持有的加密 session token 內，最長 10 分鐘。
- certificate／signed response／hashed ID：後端不持久化；當次 verified response 直接回 App。
- App Attest public key／receipt／counter：裝置安裝生命週期；App 回報刪除身分資料時可撤銷 association，reinstall 會建立新 key。
- challenge／idempotency document：TTL 10 分鐘；只保存 hash、opaque ciphertext 與時間。
- 備份：短效 collection 不開 PITR／export；production backup policy 必須證明不會把 request body 或簽章結果帶進備份。

「不持久化」只描述我們的 application storage 與 logging 設定，不等於宣稱雲端供應商、網路或內政部完全沒有處理紀錄。隱私告知必須把這些處理者分開說明。

### 監控

- Cloud Run request log 不記 body；application structured log 只含 stage、safe error code、latency bucket、deployment version。
- 不把 IP、App Attest key ID、session token、MOI ticket、certificate subject、身分證統一編號放進 log 或 metrics。
- 指標只做聚合：start／poll count、成功率、provider latency、App Attest failure rate、rate-limit count、invalid checksum count。
- `provider_response_invalid`、checksum failure、secret access denied、異常 start surge 立即告警；告警內容仍不得附 raw payload。
- 上線前以 synthetic UAT identity 做可辨認的健康檢查；不得用真人身分證統一編號當背景 cron probe。

## 金鑰與事故處理

- `SP_AES_KEY_CURRENT`、`SESSION_TOKEN_KEY_CURRENT` 都以 Regional Secret Manager 的明確 version number 注入，不用 `latest` alias。
- 每個 session token 記錄 SP key version；舊 session 在 10 分鐘 drain window 內仍使用原 version。
- 正常輪替：新增 secret version → UAT canary → deploy 指向新 version → 等舊 session 10 分鐘到期 → disable 舊 version → 驗證 Release start／poll。
- 是否允許 SP current／previous 同時有效，取決於內政部 SP 契約；沒有重疊能力時，採短維護窗 fail closed，不自行假設雙 key 可用。
- SP key 外洩：停止 start endpoint、保留非簽章查驗、通知 SP 管理窗口、撤銷／更換 key、檢查 aggregate anomaly，再恢復服務。
- session-token key 外洩：停止 start／poll、輪替 token key，所有未完成 session 作廢；它不能被拿來產生 `sp_checksum`，因為兩把 key 分離。
- Release pipeline 必須有 archive string scan／secret canary，證明 SP key、service credential 與 DEBUG provider 沒進 IPA。

## 明確不做

- 不把 production SP secret、可產生 checksum 的衍生值或遠端 secret fetch credential 放進 App。
- 不把 `bonds-wall` 改成身分簽章 broker，也不讓 signing broker 代管 Wall 的 challenge／signature count。
- 不代理 MyData 登入、下載或保存任何 MyData 原始文件。
- 不提供任意 `sign_data`、任意提示、任意 callback URL、ATH-03 push 或 device alias。
- 不建立帳號系統、不保存全域身分 profile、不把 App Attest key 當人。
- 不保存 certificate、signed response、hashed ID、ZK proof 或 nullifier。
- 不做 global nullifier registry；目前固定 app ID 會讓 nullifier 跨 verifier 共用，直接集中收集會擴大可連結性。
- 不宣稱修掉 `signatureMaterialIsReplayable`。現行 FidO signature 沒有綁 verifier challenge，只有內政部協定改動才能根治。
- 不在 public signals FFI 尚未完成時宣稱已核對 proof challenge、nullifier 或撤銷 root。

## 可估工子任務

估工是工程日範圍，不含內政部申請／換 key、Apple Developer entitlement、Google Cloud 帳務與外部審查等待時間。

| 工作包 | 大小 | 粗估 | 完成門檻 |
| --- | --- | --- | --- |
| [B1](https://github.com/bonds-tw/backupTW-iOS/issues/42)：private backend repo、Cloud Run／Firestore／regional secrets IaC、CI | M | 3–5 日 | UAT service 可部署；prod resources 不放真 secret |
| [B2](https://github.com/bonds-tw/backupTW-iOS/issues/42)：App Attest register／assertion verifier、atomic counter／challenge | L | 5–8 日 | Apple fixture、replay、wrong RP ID／AAGUID／counter 測試全過 |
| [B3](https://github.com/bonds-tw/backupTW-iOS/issues/43)：FidO ATH-01／ATH-02 broker、checksum parity、opaque session token | L | 5–8 日 | 與 Swift 固定向量相同；不落 raw ID／result；冪等 start |
| [B4](https://github.com/bonds-tw/backupTW-iOS/issues/43)：rate limit、redacted observability、rotation／incident runbook | M | 3–5 日 | log capture 與故障演練無敏感值；current→next 輪替成功 |
| [I1](https://github.com/bonds-tw/backupTW-iOS/issues/44)：App Attest actor、key lifecycle、challenge／assertion client | M | 3–5 日 | dev／prod environment 分離；reinstall／unsupported 誠實處理 |
| [I2](https://github.com/bonds-tw/backupTW-iOS/issues/45)：remote `TWFidOSignSession`、opaque handle、Release assembly | L | 5–8 日 | Release 可簽 credential 與啟動 ZK；DEBUG local path 不可達 |
| [I3](https://github.com/bonds-tw/backupTW-iOS/issues/46)：Release verifying-key 安裝與 pinned manifest／hash | M | 2–4 日 | 不需 signing broker 即可安裝、重驗與離線查驗 |
| [Q1](https://github.com/bonds-tw/backupTW-iOS/issues/47)：UAT／TestFlight security matrix | L | 4–7 日主動工時 | 真機 start→callback→poll、重複 poll、斷線、重放、rotation、archive scan 全有證據 |

單人序列約 30–50 工程日；B1/B2/B3/B4 與 I1/I3 可部分並行。即使程式完成，沒有真實 iPhone、正式 App Attest environment、有效 SP UAT credential 與 TestFlight archive，也不能把本階段標成產品完成。

## 最終 Release／TestFlight 門檻

1. Release archive 能安裝，binary／resources／strings 掃描找不到 SP AES key、service credential、DEBUG secret filename 或 local provider 可達路徑。
2. TestFlight 使用 production App Attest environment 完成 register、start、callback、poll；development attestation 必須被 production backend 拒絕。
3. 真機完成一次身分證 credential 簽發與一次 ZK holding proof 簽章；App 端都重新驗證 MOI certificate／signature。
4. 同一 `request_id` 重送不產生第二個 prompt；不同 body、重放 challenge、counter 倒退、跨裝置 session token 全被拒。
5. 斷線與 ATH-02 repeat-poll 行為有 UAT 實測結論；未知結果不自動重簽。
6. SP key 輪替、session-token key 輪替、provider outage、checksum failure 與 emergency disable 均演練一次。
7. 從 Cloud Logging／Error Reporting／Trace／Firestore／backup 抽查，找不到身分證統一編號、ticket、certificate、signature 或 request body。
8. verifying key 可在 Release 安裝、hash 驗證與離線使用；這項不依賴 signing broker 健康狀態。
9. ZK 畫面繼續顯示 replay、global uniqueness、cross-verifier nullifier 與 revocation-root caveat，直到各自的上游／查驗方門檻真的完成。

## 被排除的替代案

- **把 AES key 放 Keychain／Secure Enclave／Harvard BKC Keyring**：只能保護裝置自己的非對稱 key，不能讓每一份可逆向的 App 安全持有同一把 SP shared secret；不採用。
- **App 傳資料給後端只換 `sp_checksum`，再直接呼叫 MOI**：仍需在 App 驗 ATH-02 `idp_checksum`，等價 secret boundary 沒有移走；不採用。
- **Cloudflare Worker + Durable Object**：適合 wall／verifier，但不提供台灣 jurisdiction guarantee，短效 state 又受 PITR retention 影響；不採用於 production signing broker。
- **在既有 Wall Worker 加路由**：會把政治表態服務與法定身分簽章的資料、事故半徑及權限混在一起；不採用。
- **generic signing API**：會讓合法 App 或被竄改 App 以 bonds-tw 名義要求任意持卡人簽任意內容；不採用。

## 參考規範

- Apple：[Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)、[Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)、[App Attest environment](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.devicecheck.appattest-environment)
- Google Cloud：[Cloud Run locations](https://cloud.google.com/run/docs/locations)、[Firestore locations](https://cloud.google.com/firestore/docs/locations)、[Regional Secret Manager](https://cloud.google.com/secret-manager/regional-secrets/data-residency)、[Secret Manager best practices](https://cloud.google.com/secret-manager/docs/best-practices)
- Cloudflare（替代案證據）：[Durable Objects data location](https://developers.cloudflare.com/durable-objects/reference/data-location/)、[Durable Object storage／PITR](https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/)
