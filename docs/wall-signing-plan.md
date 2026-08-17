# iOS 連儂牆簽署流程：最終實作計畫

2026-08-17。這份文件把「在 App 裡簽一面公開的牆」從一句 CTA 變成可以照著寫的東西。三份程式碼（`backupTW-iOS`、`bond-website`、`go-zkid-verifier`）我全部讀過並在本機量過；每一條事實都附行號，推論的地方會說那是推論。

先講結論，因為它決定了整份計畫的形狀：

> **v1 對一般使用者來說不存在，而那是對的狀態。**
> `ZKProofRunAssembly.makeSigner` 在 Release build 回 `nil`（`backupTW/ZK/ZKProofRunWiring.swift:677-684`），所以**沒有任何一個發行版能產生證明**，也就沒有任何一個發行版能簽這面牆。同時 `signZK` 在 Worker 裡沒有接路由（`worker/src/index.ts:451-466` 只有三個分支），`wall.bonds.tw` 不存在（本機 `dig` 無回應）。
> 所以這條路整條掛在 `#if DEBUG` 底下。把它做成「Release 也看得到、但按下去說做不到」的灰色列，就是 bonds.tw 網站上那個 `href="#"` 的手機版——一個永遠兌現不了的邀請。不做。

---

## 一、釘住的合約

這一節是三份程式碼之間唯一會**安靜壞掉**的地方。不合的話沒有編譯錯誤、沒有 400，只有一個永遠 `verified:false` 的牆。所以先把它寫成事實表。

### 1.1 challenge

| 事實 | 值 | 證據 |
|---|---|---|
| 端點 | `GET /wall/challenge`（**未定，見 §七**）→ `issueChallenge` | `worker/src/index.ts:265`；repo 全域 grep `issueChallenge` 只有定義，沒有路由 |
| 回應欄位 | 恰好兩個：`challenge`、`decimal` | `worker/src/index.ts:273-278` |
| `challenge` 格式 | `<48 小寫 hex>.<毫秒 epoch>.<64 小寫 hex HMAC-SHA256>` | 同上；MAC 是 `HMAC-SHA256("<nonce>.<expiry>", CHALLENGE_SECRET)` hex |
| nonce 長度 | **24 bytes** = 48 hex 字元 | `crypto.getRandomValues(new Uint8Array(24))`，`index.ts:268` |
| TTL | **30 分鐘 = 1,800,000 ms** | `CHALLENGE_TTL_MS`，`index.ts:250` |
| `decimal` | nonce 當 **big-endian 無號整數**的十進位 | `BigInt('0x' + nonce).toString(10)`，`index.ts:277` |
| 送回去的是什麼 | **`challenge` 原字串，一字不改**。`decimal` 永遠不回傳 | Worker 在 `openChallenge` 重算 decimal，從不採信 client 的，`index.ts:300`、`:434` |
| App 內部型別 | `ProofChallenge.fromVerifier(<32 字元 base64url>)` | 24 % 3 == 0，所以 base64url 無 padding；`ProvingInputs.swift:112` |
| 為什麼不用改 App | 24 bytes 落在 `fieldElement()` 的 `8...31` 窗內 | `ProvingInputs.swift:176`（≥8）、`:179`（≤31） |

**31 bytes 那道天花板在這條路上完全不是問題。** 地圖把它列成未解風險是對的——但那是對「陌生驗證方送 32-48 bytes」而言。這面牆自己鑄的是 24 bytes，`PresentationRequest`（上限 64 base64url 字元 = 48 bytes，`PresentationRequest.swift:148`）在這條路上一次都不出現。**不需要、也不准發明 SHA-256 截斷**。

### 1.2 app_id

| 事實 | 值 | 證據 |
|---|---|---|
| 電路吃的 | 原始 31 字元字串 `55349ff540392a077ca3dcc9bbda4c3` | `TWFidOConfiguration.swift:32`；本機量長度 = 31，全小寫 hex |
| TW FidO 吃的 | `base64(UTF8(app_id))`，**不同編碼** | `TWFidOClient.swift:618` |
| Go 端比對 | `subtle.ConstantTimeCompare([]byte(parsed.AppID), []byte(expected))`，`UnpackAppID` 固定產 31 **bytes** | `linkverify/verifier.go:217-218`；`verifier/public_inputs.go:9,126-131` |
| Go 端啟動檢查 | `len([]rune(appID)) != 31` — **量的是 rune，比的是 byte** | `verifier/main.go:211-217` |

這個 rune/byte 落差是 go-live 阻斷條件（§六第 5 條）。App 這邊已經在 `ProvingInputs.swift:287,319-322` 用「長度 31 + 全小寫 hex」獨立擋過一次，所以 App 側不需要新程式碼，需要的是把同一個值寫進 Cloud Run 的環境變數。

### 1.3 提交

| 事實 | 值 | 證據 |
|---|---|---|
| 端點 | `POST /wall/sign-zk`（**未定，見 §七**）→ `signZK` | `/wall/sign` 已被開放徽章佔用，`index.ts:462` |
| body 欄位 | 恰好三個：`challenge`、`certChainProof`、`userSigProof` | `index.ts:405-410`；沒有 `badge`，沒有其他欄位被讀 |
| 兩個證明的編碼 | **標準 base64（有 `+`、`/`、`=`）**，不是 base64url | Worker 原封轉發字串 → Go `[]byte` → `encoding/json` 用 `base64.StdEncoding`。`verifier/main.go:86-93` |
| 送幾個檔 | **兩個**：`cert_chain_rs4096_proof.bin`、`user_sig_rs2048_proof.bin` | `verifyRequest` 只有兩個 proof 欄位。`*_instance.bin` **不送** |
| proof type | 寫死 rs4096 | `verifier/main.go:132`；rs2048 cert-chain 的 verifying key 刻意不在 image 裡 |
| 原始大小 | 113,055 + 77,743 = **190,798 B** | `ZKProofPackage.swift:20-25`（2026-08-08 實測） |
| 上線大小 | base64 後 150,740 + 103,660 = 254,400 字元，加 JSON 外殼 ≈ **254.6 KB** | 本機算的 |
| Go body 上限 | 2 MiB = 2,097,152 | `verifier/main.go:246` |
| Go 寫入逾時 | **120 秒** | `verifier/main.go:262 WriteTimeout` |
| Go 併發 | **一次只驗一個**，無佇列上限 | `oneAtATime = make(chan struct{}, 1)`，`main.go:77` |

### 1.4 每一個回應分支，以及它燒掉了什麼

這張表是整份設計的脊椎。Worker 的求值順序是：`CITIZEN_ENABLED` → secrets → rate limit → 每日預算 → parse body → `openChallenge` → **`claimChallenge`** → `fetch` 驗證器。`claimChallenge` 在 `index.ts:418-420`，在 fetch 之前，在其他所有檢查之後。所以：

| 回應 | claim 跑了嗎 | challenge 燒了嗎 | 同一份證明能再送嗎 | App 可不可以說「什麼都沒公開」 |
|---|---|---|---|---|
| 503 `unavailable` | 否 | 否 | **可以** | 可以 |
| 429 `rate-limited` | 否 | 否 | **可以** | 可以 |
| 503 `verifier-budget` | 否 | 否 | **可以** | 可以 |
| 400 `malformed` | 否 | 否 | 可以（但這是 App bug） | 可以 |
| 400 `challenge-invalid` | 否 | n/a | 不行（綁死在一個 Worker 不認的號碼上） | 可以 |
| 400 `challenge-used` | 是（回 false） | 早就燒了 | 不行 | **不可以** |
| 503 `verifier-unavailable` | 是 | **燒了** | 不行 | 可以（`!response.ok` 在 INSERT 之前，`index.ts:437`） |
| 200 `{"verified":false}` | 是 | **燒了** | 不行 | 可以 |
| 200 wall state | 是 | 燒了 | n/a | — |
| 傳輸中斷 / 非 JSON / 未知 5xx | **不知道** | **當作燒了** | 不行 | **不可以** |

最後一列是判官抓到的真缺陷，值得單獨說：`INSERT INTO signature` 在 `index.ts:444-446`，之後才呼叫 `read()`，而 `read()` 還要再跑兩條 D1 query（`SELECT COUNT(*)`、`SELECT ... LIMIT 60`，`index.ts:173-183`）。**那兩條 query 失敗會讓整個 Worker 丟出未攔截的例外，Cloudflare 回自己的 HTML 錯誤頁——而那時候簽名已經寫進去了。** 所以：

> **規則：submit 這一通的任何非 JSON 回應、任何未列在上表的狀態碼，一律歸 `.unknown`，永遠不准說「沒有任何東西被公開」。** 只有解析成功、且屬於上表前六列的 JSON 錯誤碼，才有資格說那句話。

原本那條「content-type 不是 JSON 就當作 captive portal，並說沒有公開」的規則是錯的，而且錯在最貴的方向。改掉。

### 1.5 兩種 200 怎麼分辨

成功回 `{signatureCount, recent:[...]}`（`index.ts:177-183`），拒絕回 `{verified:false}`（`index.ts:442`）。**沒有共用的判別欄位。** 解法固定：

1. 先讀 `verified`。若 `verified == false` → `.refused`。
2. 再找 `signatureCount`。有 → `.published`。
3. 兩個都沒有 → `.unreadableReply`，**絕不猜**。

先讀 `verified` 是讓一個同時帶兩個 key 的畸形 body 往「拒絕」倒，不是往「成功」倒。這個順序也讓 bond-website 日後在成功 body 加上 `verified: true` 時 App 不會壞。

---

## 二、三份程式碼的事實訂正

寫計畫的過程中，有三件被寫在別處的「事實」是錯的。放在這裡，因為照著錯的做會浪費在最貴的地方。

**（一）`CheckChallenge` 已經接好了，不是待辦。** 有一份設計把「Go 沒有呼叫 `CheckChallenge`」列為 go-live 阻斷條件。那是只讀了 library 就停手：`linkverify.Verifier.Verify`（`verifier.go:66-116`）確實沒叫它，但 bond-website 的服務層叫了——`verifier/main.go:144-153`，`verified := result.Verified; if verified { outcome := s.verifier.CheckChallenge(result.Parsed, req.Challenge); verified = outcome != nil && outcome.Match }`，上面還有一段註解正好在講忘了叫的後果。**不要去「修」它。** 在這個位置動手，錯一次就是每一份證明永遠可重放。

**（二）challenge 不是「一定被燒掉」。** 有一份設計說「challenge 在驗證器之前就被花掉，所以除了成功以外的每一個結果都已經消耗了它」，並用這句話當作「一律不准重送」的理由。上表證明有五個分支根本沒走到 `claimChallenge`。差別是實的：429 之後強迫使用者從頭來，代價是**再一次把身分證統一編號送給內政部**——這支 App 自己的提示文案（`ZKProofViewController.swift:60-62`）就是在讓使用者同意這件事。所以重試策略要按上表分岔，不是一刀切。

**（三）`wall.bonds.tw` 不存在，而且是刻意沒做的。** `dig +short wall.bonds.tw A` 無回應；`bonds.tw` 回 104.21.76.159 / 172.67.197.102。`worker/wrangler.jsonc` 沒有 `routes`、沒有 `custom_domain`。`worker/MOVING.md` 寫得很清楚：Worker 現在在 `https://bonds-wall.gimmychang.workers.dev`（bonds.tw 自己的帳號，2026-08-16 搬完），而自訂網域「⚠️ 尚未做、留給日後決定……那是動到 live 網域的 DNS，沒有先問就不做」。

把 `wall.bonds.tw` 編進一個要上 App Store 的二進位檔，等於把 NXDOMAIN 編進去。而 NXDOMAIN 在 `URLError` 裡長得像連線問題，會被算成「檢查一下你的網路」——在一個賣點是「絕不冤枉別人」的畫面上，去怪使用者的 Wi-Fi。**主機名是待拍板事項，不是預設值**（§七）。

**（四）90 秒的 submit 逾時比伺服器自己宣告的預算還短。** Go 的 `WriteTimeout` 是 120 秒，而且一次只驗一個、沒有佇列上限，跑在會冷啟動的 Cloud Run 上、image 帶著兩把 verifying key。兩個人同時簽，第二個人就排隊。**client 的 deadline 不能小於 server 宣告的 deadline**，否則每一次「慢的成功」都會變成一個永久的 `.unknown`，再變成一次重複簽名。改：`timeoutIntervalForRequest = 180`、`timeoutIntervalForResource = 240`。

---

## 三、實作步驟

### 步驟 1｜先把無網路 canary 加寬，跟這個功能同一個 commit

檔案：`backupTWTests/OfflineVerifierTests.swift`

`docs/trust-chain-recommendation.md:244` 已經指名這件事該做。現在的 `theVerifierSourceNamesNoNetworkingAPI`（`:1261`）只 parse 一條寫死的路徑 `backupTW/Presentation/OfflineVerifier.swift`，所以它寫成之後新增的每一個檔案都被安靜跳過。而 `NetworkCanary`（`:1177`）那個 `URLProtocol` 看不到用自己 `URLSessionConfiguration` 建的 session——現存四個網路呼叫點全部是那樣建的，新增的這個也是。**所以原始碼掃描是唯一真的有效的機制。**

改成列舉整個 `backupTW/` 目錄，並用**相等**（不是包含）比對允許清單：

```swift
private static let mayOpenASocket: Set<String> = [
    "backupTW/ZK/CircuitAssets.swift",
    "backupTW/ZK/ZKProofRunWiring.swift",
    "backupTW/TWFidO/TWFidOClient.swift",
    "backupTW/Model/CredentialIssuance.swift",
    "backupTW/ViewController/MyDataWebViewController.swift",
    "backupTW/Wall/WallClient.swift",
]
```

任何其他檔案出現 `URLSession`、`URLRequest`、`WKWebView`、`NWConnection`、`CFStream`、`getaddrinfo`、`dataTask`、`downloadTask`、`import Network`、`import CFNetwork`、`import SystemConfiguration` 就紅。用相等比對的意思是：新開一個 socket 會紅，**把一個檔案從清單刪掉卻沒刪程式碼也會紅**。

`backupTW/Presentation/OfflineVerifier.swift` 一行不動。它檔頭那句「Nothing in this file opens a socket」是檔案範圍的，仍然成立。

跟這個功能同一個 commit 落地，理由不是整潔：這個功能正是 canary 存在的目的要抓的東西。

### 步驟 2｜`backupTW/Wall/WallConfiguration.swift`

```swift
struct WallConfiguration: Sendable {
    let baseURL: URL
    enum Path {
        static let read = "wall"
        static let challenge = "wall/challenge"   // 未定，見 §七
        static let sign = "wall/sign-zk"          // 未定，見 §七
    }
    static let challengeTimeout: TimeInterval = 20
    static let submitRequestTimeout: TimeInterval = 180   // > Go 的 WriteTimeout 120
    static let submitResourceTimeout: TimeInterval = 240
}
```

`baseURL` **沒有 `.production` 預設值可以寫**（§二之三、§七之一）。在拍板之前，它由 `#if DEBUG` 提供，Release 這條路整個編不進去。

session，第三個組態工廠，跟 `CircuitAssets.makeSessionConfiguration()`、`TWFidOClient.privateSession` 並列：

```swift
static func makeSessionConfiguration() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.httpCookieAcceptPolicy = .never          // ← 三道，不是兩道
    c.waitsForConnectivity = false
    c.allowsConstrainedNetworkAccess = true
    c.allowsExpensiveNetworkAccess = true
    c.httpAdditionalHeaders = ["accept": "application/json"]
    return c
}
```

`.ephemeral` **自己會留一個記憶體 cookie jar**——`TWFidOClient.swift:281-288` 的註解自己就說了「cache, cookies and credentials in memory only」。Cloudflare 會在 Workers 回應上設 `__cf_bm`，那顆 cookie 會被存起來、幾分鐘後在 submit 那一通被送回去，把「拿號碼」和「送證明」兩通綁在一起——包括使用者中途從行動網路換到 Wi-Fi 的那種情況。所以三個 cookie 設定都要下，並且在測試裡斷言。

`allowsConstrainedNetworkAccess = true` 是刻意跟 `CircuitAssets.swift:401` 相反：那邊關掉是為了讓 950 MB 的下載在低數據模式下一秒失敗而不是吊死，254 KB 沒有這個問題。

**Info.plist 不加任何東西。** 沒有 `NSAppTransportSecurity`、沒有 `NSExceptionDomains`、沒有 `NSAllowsLocalNetworking`、沒有憑證 pinning。Cloudflare Workers 給 TLS 1.3 + forward secrecy，預設 ATS 就過；為一個不需要例外的主機加例外是永久性的削弱；一個沒辦法快速更新的 App 不該對輪替中的憑證 pin。DEBUG 覆寫也必須是 `https://`——指向 `wrangler dev --local-protocol https` 或 preview Worker，不要為了本機方便去開 ATS 鑰匙，因為那把鑰匙會跟著出貨。

**但 Info.plist 有一個字串要改。** `backupTW/Info.plist:27`（`NSCameraUsageDescription`）現在寫的是：

> 全程離線比對，不會拍照、不會錄影，也不會將任何影像**或資料**上傳。

「任何影像或資料」，前面掛著「全程」，句子裡沒有任何東西把它綁回相機。它出現在 App Store 權限對話框——這支 App 語境最少的一個畫面。同一份計畫一邊把無網路測試擴大到整個原始碼樹（因為那是 App 級性質），一邊主張這句承諾只是畫面級，這兩件事不能同時成立。改成：

> 全程離線比對，不會拍照、不會錄影，也不會將任何影像上傳。

仍然是真的，而且那本來就是原意。`NSBluetoothAlwaysUsageDescription`（`:25`，「全程不連任何伺服器」）不動——它的範圍是藍牙出示連線，牆這條路一次都不碰藍牙，而 `WallBoundaryTests`（步驟 9）會把這件事釘住。

### 步驟 3｜`backupTW/Wall/WallChallenge.swift`

```swift
struct WallChallenge: Equatable, Sendable {
    /// 一字不改送回去。App 從不重組它。
    let token: String
    /// 一定是 .fromVerifier。只有建構這裡決定得了。
    let proofChallenge: ProofChallenge
    /// 從伺服器 Date header 與 expiry 算出來的「還剩多久」，
    /// 之後只用單調時鐘推進。裝置的日曆時間永遠不參與。
    let ttlAtIssue: TimeInterval
    let anchor: ContinuousClock.Instant

    static let minimumUsableToStart: TimeInterval = 900
    static let minimumUsableToSubmit: TimeInterval = 300
}
```

**兩個門檻，不是一個。** 這是判官抓到的實缺陷：用同一個 780 秒去回答「值不值得開跑」和「還能不能送出」，會在證明已經做好、身分證統一編號已經送出去之後，把一份還有十三分鐘有效期的證明丟掉，然後跟使用者說「號碼過期了」——而那句話在說出口的當下是假的。

- `minimumUsableToStart = 900`：FidO 上限 600 秒（`LiveTWFidOSignSession.timeLimit`）+ 證明 + 送出，1800 秒的 TTL 有兩倍餘裕。
- `minimumUsableToSubmit = 300`：只需要蓋住 240 秒的 resource timeout 加一點餘裕。

**時鐘用單調時鐘，不用裝置日曆。** 原本「decode 時檢查 expiry 是否在未來」的做法只可能在錯的時候觸發：Worker 才剛用 `Date.now() + 30min` 鑄出來，不可能發一個已過期的 challenge，所以那個檢查的真陽性率是零，偽陽性率等於「手機時鐘快超過 30 分鐘的比例」。那些使用者永遠簽不了，而且會被歸咎給牆。改成：拿回應的 `Date` header 當伺服器時間，算出 `ttlAtIssue = expiry - serverNow`，之後全部用 `ContinuousClock` 推進。沒有 Date header 就退回裝置時鐘並在測試裡標記這條路徑。

`parse(token:decimal:serverDate:)` 依序檢查，跟 `openChallenge`（`index.ts:293-299`）一樣嚴，不比它寬鬆：

1. 三段，否則 `.challengeMalformed`
2. 第 0 段符合 `^[0-9a-f]{48}$`（**只收小寫**）
3. 第 2 段符合 `^[0-9a-f]{64}$`（只驗形狀，MAC 在這裡驗不了）
4. 第 1 段符合 `^[0-9]{1,15}$`，且 `ttlAtIssue > 0`
5. hex → 24 bytes → `VerifiableCredential.base64URLEncoded(_:)` → 32 字元 → `.fromVerifier(...)`
6. **`try proofChallenge.fieldElement() == decimal`，否則 `.challengeDecimalDisagrees`**

第 6 條是承重的。兩邊都是同 24 bytes 的 big-endian——App 端是 `ProvingInputs.swift:208` 的手刻長乘法，Worker 端是 `BigInt('0x' + nonce).toString(10)`——所以「相等」是可證明的，「不相等」就代表其中一邊改了。它花微秒，換掉的是：身分證統一編號送到內政部之後、十秒證明之後，才發現編碼對不上。`decimal` 視為必填，缺了就是 `.challengeMalformed`；對一個交叉檢查欄位寬容，就等於沒有交叉檢查。

因為是 `.fromVerifier`，`ZKProver.caveats(for:)`（`ZKProver.swift:1234-1241`）會少掛 `challengeNotBoundToVerifier`，bundle 帶六條而不是七條。這是證明上唯一可觀察的差異，而且它是對的：號碼確實是牆發的。**但要注意 §四之四說的：這條 caveat 拿掉的正當性，來自 `verifier/main.go:150-153` 真的有叫 `CheckChallenge`——那是我讀過的，不是假設。**

### 步驟 4｜`backupTW/Wall/WallSubmission.swift`

```swift
struct WallSubmission: Equatable, Sendable {
    /// 標準 base64（含 padding）。Go 的 encoding/json 用 StdEncoding 解 []byte，
    /// URL-safe 字母表會被直接拒絕。這裡明寫成 String，而不是丟給
    /// JSONEncoder 的 dataEncodingStrategy 預設值——因為那是一個沒人會去讀的預設。
    let certChainProof: String
    let userSigProof: String
    let encodedByteCount: Int

    /// 推導，不重寫：ZKProver.proofFilenames 帶 `keys/` 前綴，
    /// 而 bundle.proofDirectory 本身就結束在 keys。
    static let artifactNames = ZKProver.proofFilenames.map {
        ($0 as NSString).lastPathComponent
    }

    static let maximumEncodedBytes = 1_500_000

    /// 唯一的建構子，而且它吃 ZKProofBundle。
    init(readingFrom bundle: ZKProofBundle) throws
    func body(challengeToken: String) throws -> Data
}
```

只有一個建構子、而且吃 `ZKProofBundle`，是為了讓 `VerifiablePresentation`、`MOICASignedCredential`、`StoredCard`、`ZKProofPackage`、裸 `Data` 在那個呼叫點**根本拼不出來**。持卡人的 X.509 Subject CN 裡有法定姓名——那條路不該靠 code review 擋，該靠型別擋。

**兩個 `*_instance.bin` 不送**，因為 Go 的 request struct 沒有那兩個欄位。但理由要說對：判官抓到原本寫的「送 instance 會讓更多 public signal 經過 Cloudflare」是**假的**——`linkverify/linkverify.go:88-110` 只把兩個 proof 檔寫進暫存 keys 目錄，public signals 是 FFI 從 proof bytes 裡撈出來的（`zk_last_signals()`）。**nullifier、pk_commit、app_id_packed、challenge、34 個 issuer modulus limb、smt_root，不管送不送 instance，全部都會過 Cloudflare 邊緣、也全部會進 Cloud Run 的記憶體。** 不送 instance 省的是 103 KB 頻寬和一次型別誤用，不是任何揭露面。這句話要寫在原始碼註解裡，因為相信錯的版本會讓後面的人低估暴露面。

`maximumEncodedBytes` 的存在不是省頻寬，是**省一個 challenge**：Go 超過 2 MiB 回 413，Worker 把所有非 2xx 的 Cloud Run 回應塌成 `verifier-unavailable`，而那是燒掉那一側。本地先拒絕，challenge 就活著。同 `ZKProofViewController.swift:913` 對 `LinkTransport.maximumPayloadBytes` 的做法。

### 步驟 5｜`backupTW/Wall/WallClient.swift` + `WallError.swift`

一個縫，讓測試在完全沒有網路的情況下跑過每一個分支（這很重要，因為牆現在上不了線）：

```swift
protocol WallSigning: Sendable {
    func readWall() async throws -> WallState
    func issueChallenge() async throws -> WallChallenge
    func submit(_ s: WallSubmission, challenge: WallChallenge) async throws -> WallSubmissionResult
}
enum WallSubmissionResult: Equatable, Sendable {
    case published(signatureCount: Int)
    case refused
}
```

解碼規則，依 §1.4 / §1.5：

- **狀態碼與 body 一起讀，不是先看 content-type。** 只有解析成功、且 `error` 字串屬於 §1.4 前六列的，才允許進入「什麼都沒公開」那一側。
- submit 這一通的任何非 JSON、任何未知狀態碼、任何傳輸中斷 → `.unknown`。challenge 那一通的同類錯誤 → 什麼都沒花，可以直說。
- **DNS 解析失敗要有自己的 case**（`.hostDoesNotExist`），不能歸到「檢查你的網路」。這條在 `wall.bonds.tw` 拍板前是最可能發生的一種失敗。

重試成本掛在**結果**上，不是掛在**錯誤**上——同一個 `URLError.timedOut` 在 challenge 那通是「什麼都沒花，隨便重試」，在 submit 那通是「可能會多一筆」：

```swift
enum WallRetryCost: Equatable, Sendable {
    case resend        // challenge 還在，證明還在記憶體裡
    case startOver     // 要新號碼，要再跑一次行動自然人憑證
    case mightDuplicate
    case none
}
```

`.resend` 是判官逼出來的修正：429、`verifier-budget`、`unavailable`、`malformed` 之後，challenge 沒燒、證明還在記憶體、**同一份 body 可以直接再送一次**。逼使用者從頭來，代價是多一筆送到內政部的身分證統一編號紀錄。那不是可以隨手付的東西。

**沒有任何自動重試。** 每一次重試不是燒一個 challenge，就是可能多一筆公開簽名，兩件都是使用者的決定。

### 步驟 6｜`backupTW/Wall/WallSignRun.swift`

`ZKRunStage` **不擴充**——加 case 會讓 `ZKProofViewController.stageGroup()`（`:418` 對 `ZKRunStage.allCases` 展開）畫出永遠不動的列。改用平行 enum：

```swift
enum WallSignStage: String, CaseIterable, Equatable, Sendable {
    case files        // ~950 MB，在任何時鐘出現之前
    case challenge    // 時鐘從這裡開始
    case signature    // TW FidO，≤600 秒
    case proof
    case selfCheck    // 有 verifying key 才跑
    case submission
}
```

**狀態原封重用 `ZKRunStageState`。** 這是整份設計裡最划算的重用：`.unavailable` 畫灰色無圖示、`.failed` 畫橘色三角形這個不變式已經在 `ZKProofRun.swift:585-599` 裡，所以「牆被關掉了」在結構上不可能被畫成「牆拒絕了你的證明」。`ZKStagePresentation.detail/verdict/isBusy` 一行不用改。

```swift
enum WallSignOutcome: Equatable, Sendable {
    case published(signatureCount: Int)
    case refused(producerSelfCheckPassed: Bool?)   // 牆的查驗器跑了，說不行
    case notAccepted(WallError)                    // 還沒查就被擋掉，確定沒加上去
    case unknown(WallError)                        // 送出去了，答案沒回來
}
```

`.unknown` 是第一級公民，不是失敗的一種。牆刻意不存任何能識別一筆簽名的東西，所以「我那筆算了沒有」在設計上永久不可解——把它畫成失敗，是往看起來安全的方向撒謊。

`run` 的順序，挑成「越可能失敗的越早、越貴」：

1. 重新 `plan()`；proving 素材沒齊就 `.files → .failed(.filesNotReady)` 收工。950 MB 由 `prepareFiles` 在**任何 challenge 出現之前**、在自己的同意閘之後準備好。一個可能跑一小時的下載，絕不能跑在一個 30 分鐘的時鐘裡面。
2. `.challenge` → 取號、parse、交叉檢查、記錄單調錨點。剩餘 < `minimumUsableToStart` 就再取一次，然後放棄——一面發短號碼的牆是組態壞了，不是可以重試進去的東西。
3. `.signature` / `.proof` / `.selfCheck` 全部來自**一次** `ZKProofRunner.run(challenge:onUpdate:)`。用全函數映射，不寫 `default:`，這樣 `ZKRunStage` 加 case 會編譯失敗：`.assets→.files, .signature→.signature, .proof→.proof, .verification→.selfCheck`。合併規則沿用 `ZKProofViewController.apply` 的：非終態更新不覆蓋已終態。
4. run 回來 `report == nil` 且 `.verification` 失敗 → **這支手機自己驗自己的證明並拒絕了**（`ZKProver.swift:1201-1225`）。**不送。** 結果 `.notAccepted(.proofRefusedOnThisDevice)`，challenge 沒花掉。這是「verifying key 選配但一旦有就會用」在這條路上真正買到的東西，ZK 畫面上買不到。
5. 新鮮度閘：剩餘 < `minimumUsableToSubmit` 就不 POST。
6. `.submission` → `submit`。
7. **收尾掃地。** 不論結果，把這次 run 的四個產物（`ZKProver.proofFilenames + instanceFilenames`）從工作目錄刪掉。理由：`instance` 檔裡是直接可解析的 nullifier，`ZKProver.swift:1250-1257` 自己就說那是「使用者要求被遺忘時想擺脫的東西」；牆這條路沒有 export、沒有藍牙送出，留著它們只是在一次政治行動之後，於裝置上留下一個可關聯的把柄。ZK 畫面的行為完全不變（它要留著給 export）。

`.selfCheck` 在 968 MB 的 verifying key 不在時是 `.unavailable`——`ZKAssetPreparing.verificationOnlyRequirementNames` 已經處理好，所以牆這條路需要的是 ~950 MB，不是 ~2 GB。

### 步驟 7｜`backupTW/Wall/WallCopy.swift`（一）：`WallDisclosure`

`ProofCaveat` 描述的是**證明**，不長出「公開發布」的 case。這面牆會知道什麼，是另一個軸，需要自己的可列舉型別（可列舉是為了讓 `LocalizationCoverageTests` 走得到）：

```swift
enum WallDisclosure: String, CaseIterable, Equatable, Sendable { ... }
```

**1 `proofLeavesTheDevice`**
EN: "This is the only thing in this app that sends anything to a server. About 250 KB of proof goes over the internet."
ZH:「這是這支 App 裡唯一會把東西送到伺服器的動作。大約 250 KB 的證明會經由網路送出去。」
（不是 190 KB。原始 190,798 B 經 base64 之後上線的是 254,400 字元。這份計畫在拒絕使用者的時候用編碼後的數字，那在告訴使用者代價的時候就不能改用原始數字——兩次都往好聽的方向偏，就不是四捨五入了。）

**2 `nullifierReachesTheOperator`** — 最鋒利的一條
EN: "The proof carries two numbers that are the same for you every time. bonds.tw says it does not store them and does not publish them. Nothing in the proof stops them — that is a promise, not a property."
ZH:「證明裡有兩個對你每次都一樣的號碼。bonds.tw 說它不會保存、也不會公開。證明本身擋不住他們——那是一個承諾，不是一個性質。」

**兩個，不是一個。** `nullifier` 是 signals[1]，由 app_id 上的 RSA 簽章推出來（`go-zkid-verifier/README.md:10`），所以它綁在 `bondsAppID` 上。但 `pk_commit` 是 signals[0]，兩份證明各有一個而且**必須相等**（`linkVerify` 靠它把兩份證明綁在一起），也就是說它只能由持卡人的金鑰決定，沒有任何 relying-party 域分隔。App 自己的註解（`ZKPublicInputs.swift:153-155`）只寫「Ties the two proofs together」，連 ⚠️ 都沒掛。**推論（需向電路原始碼確認，§七之五）：`pk_commit` 是一個跨所有 zkID relying party 的全域固定識別碼，比 nullifier 的範圍還大。** 在確認之前，文案以「兩個號碼」陳述，這在兩種情況下都是真的。

**3 `issuerKnowsWhenYouAsked`** — 新增，判官抓到的最重的一條
EN: "內政部 already knows your ID number asked for a signature for this app, and when. The wall publishes the minute each signature was made. Those two lists can be lined up."
ZH:「內政部已經知道你的身分證統一編號在什麼時候為這支 App 要過一次簽章。這面牆會公開每一筆簽名發生在哪一分鐘。這兩份清單對得起來。」

證據：`ProofCaveat.idNumberDisclosedToIssuer` + `worker/src/index.ts:145-147` 的 `minutePrecision`（`toISOString().slice(0,16)`）+ `read()` 是不需要驗證的公開端點。SIGN 與寫入之間的間隔被這份設計自己的算式綁住（≤600 秒 FidO + 證明 + 送出），而 `VERIFIER_DAILY_LIMIT` 預設 200/天，代表任何 11 分鐘窗內的期望簽名數約 1.5 筆——**對大多數簽名者來說，發卡機關可以從一個公開頁面把人指出來。**

`docs/lennon-wall.md` §1 的鐵律「公開資料只有徽章類型與時間戳」正是這個向量：它的威脅模型假設攻擊者需要 nullifier，而內政部不需要。這條 App 端沒有辦法修（唯一的緩解是伺服器端把時間粗到小時、或隨機延後公開），所以 App 該做的是**在同意之前把它說出來**，並把它列進 §六的 go-live 討論。

**4 `revocationNotCheckedByTheWall`**
ZH:「這面牆不檢查撤銷清單。這支 App 做證明的時候套用了一份，但牆不看它，所以已經掛失的卡片一樣拿得到徽章。」（`verifier/main.go:238` `SmtRoot: nil`）

**5 `countIsSignaturesNotPeople`** — 改寫，原本的版本在說謊
ZH:「這面牆數的是簽名，不是人。它**分得出來**同一個人簽了兩次——證明裡那兩個號碼會一模一樣——它只是說它不看。簽兩次就是兩筆。」
（原本寫「它不會檢查你以前簽過沒有」，把一個「選擇」寫成「能力」，而且就寫在第 2 條堅持要區分承諾與性質的同一份清單裡。）

**6 `cannotBeWithdrawn`**
ZH:「簽名沒有辦法撤回。這面牆不保存任何說明哪一筆是你的東西——它匿名的理由就是這個。」

**7 `operatorMustBeTrusted`**
ZH:「證明不會公開，所以 bonds.tw 以外的人沒辦法自己重算牆上的數字。公開證明會洩漏上面說的那兩個號碼。」

**8 `issuerNotCheckedByTheWall`** — **無條件納入**，不是「如果 verifier 沒設就納入」
ZH:「這面牆不檢查證明背後的憑證是不是內政部發的。在這個版本裡，徽章代表一份有效的證明，不一定代表一張自然人憑證。」

原本寫成條件納入是錯的：那是把一個 App Store 送審週期的編譯期常數，綁在一個維運者幾分鐘就能重部署的 Cloud Run 執行期事實上。兩邊都會錯。做法是：無條件納入，並在 App 裡放一個寫下來的假設常數

```swift
enum WallVerifierAssumptions {
    /// verifier/main.go:239 目前是 IssuerCert: nil，
    /// 而 linkverify/verifier.go:99 在 nil 時整個跳過 checkIssuerModulus。
    static let wallChecksIssuerModulus = false
}
```

用測試把 case 的存在釘在這個常數上，翻轉它就是一個看得見、有論證的單行 diff。順帶：`verifier/main.go:187` 的 `handleHealth` 現在宣稱它檢查 `issuer_modulus`——**那個端點在說謊**，見 §六第 6 條。

### 步驟 8｜`WallCopy.swift`（二）：畫面文案與每一個失敗句

`WallSignCopy`，形狀比照 `ZKProofCopy`，有 `static var allProse: [String]`。

`whatItDoesTitle`「在一面公開的牆上加一個簽名」

`whatItDoes` — **這句被判官指出是整份設計裡唯一一句系統完全撐不住的話**，改掉：

> ~~「你的姓名、身分證統一編號與憑證都不會離開這支手機。」~~
> ZH:「把一份零知識證明送到 bonds.tw。如果牆那邊的查驗器接受了，數字會加一，並出現一個徽章與時間（只到分鐘）。**你的姓名與憑證不會送到 bonds.tw；你的身分證統一編號會送到內政部，因為那是取得簽章的方式。**」

`ZKProofViewController.swift:41-44` 已經把規則寫下來過了：「『The person checking never sees…』，不是『without showing…』。不揭露這件事對查驗方成立，對發卡機關是假的。」原本的寫法直接違反這條，而且它會被放在畫面最上面——使用者做決定時讀的那一句——同一個畫面往下兩段就顯示 `idNumberDisclosedToIssuer`。一個畫面在一次捲動之內自相矛盾，矛盾在這支 App 最敏感的事實上。而且 `noWallProseOverClaims` 的禁用詞表抓不到它。

`clockIsAdvisory`「下面的倒數是從拿到號碼那一刻開始算的經過時間，牆用的是它自己的時間，所以兩邊可能差幾秒。」

`whatTheRunCosts`「開始之後：你在行動自然人憑證裡核可（最多十分鐘）、這支手機做證明、牆那邊檢查。牆發出的一次性號碼有三十分鐘。」

`selfCheckIsOptional`「這支手機可以先自己檢查一遍自己的證明，但要先下載額外的檢查檔案。沒有它們的話，證明有問題要等到牆拒絕才知道，而那時候一次性號碼已經用掉了。」

`settingsRowSubtitle`「這支 App 裡唯一會把東西送到伺服器的動作。公開、永久，而且收不回來。」
（**放在 `WallSignCopy` 裡**，`SettingsViewController` 只引用。判官抓到的：入口那一列的副標是使用者讀到的第一句，如果它是 view controller 裡的裸字串，`allProse` 的走訪和禁用詞測試都碰不到它。「匿名」這個詞在整份文案裡一次都不出現。）

證明的 caveat **推導、絕不重寫**：

```swift
static let plannedCaveats: [ProofCaveat] = ZKProver.caveats(for: .fromVerifier(""))
```

#### 每一個失敗分支的句子

原則：標題說發生什麼、內文說**花掉了什麼**、重試按鈕用它的代價命名。

**404 / DNS 失敗（今天的現實）**
「這個版本找不到那面牆。」/「什麼都沒有送出去，這支手機上也沒有任何東西改變。這是這個版本的位址設定問題，不是你的網路。」無圖示、無重試。
（**不說「牆還沒開始收證明」**——Worker 對「未接路由」和「App 把路徑寫錯」回一模一樣的 404，而路徑名今天就是我方單方面的提案。用有把握的話說。）

**503 `unavailable`**「用證明簽署目前是關閉的。」/「經營這面牆的人把它關掉了。什麼都沒有送出去，現在再試一次也會得到同樣的答案。」無重試。

**429 `rate-limited`**「這個網路送出的請求太多了。」/「沒有東西被用掉——**同一份證明可以再送一次**。這面牆是按網路位址計算的，所以同一個 Wi-Fi 上的其他人也算在裡面。」
重試：「再送一次同一份證明」，倒數 60 秒後可按。文案不承諾 60 秒夠——`index.ts:200-209` 記錄了實測七次連發全部 200，這個限制器是斜坡不是牆。

**503 `verifier-budget`**「這面牆今天能付錢檢查的證明已經用完了。」/「台灣時間早上八點重置。沒有東西被用掉，在一次性號碼還有效之前，同一份證明可以再送一次——還有 %@。」
（00:00 UTC = 08:00 台北，來自 `index.ts:372`。）

**400 `challenge-invalid`** — **不要說「過期」**
「這面牆不認這個一次性號碼。」/「可能是它過期了，也可能是牆那邊換過金鑰。**不論哪一種，重新開始就要做一份新的證明，也要再在行動自然人憑證裡簽一次名。**」
（`openChallenge` 對格式錯、非小寫、過期、MAC 不符**回同一個字串**。App 在 parse 時已經驗過格式、送出前已經用單調時鐘驗過剩餘時間，所以走到這裡還活著的原因只剩金鑰輪替與時鐘偏差。原本斷言「過期」，是在唯一一個必須猜的分支上，猜了一個自己剛剛排除掉的原因。）

**400 `challenge-used`**「這個一次性號碼已經用掉了。」/「每一個只算一次。如果前一次送出後沒收到回覆，那一次很可能已經算進去了。」

**503 `verifier-unavailable`**「這面牆連不上檢查證明的服務。」/「你的證明沒有被檢查，也沒有任何東西被公開。一次性號碼已經用掉了，所以再試一次就要重做一份證明——包括再在行動自然人憑證裡簽一次名。」

**200 `{"verified":false}`** — 兩個變體，而且 A 變體的原句是**誤診**
標題：「這面牆檢查了這份證明，沒有接受。」
（A，本機自檢通過）「這支手機檢查的是數學，而且通過了。**牆檢查的是數學、加上這份證明是為哪個服務做的、加上它綁的是不是牆剛剛發出的那個號碼**——這兩件事這支手機沒有辦法自己檢查。所以這通常代表牆那邊的設定和這支 App 對不上，不代表你的卡片有問題。沒有任何東西被公開。這件事值得回報。」
（B，沒跑自檢）「這支手機沒有自己檢查過這份證明，所以沒有東西可以拿來比對。沒有任何東西被公開。」

證據：手機端 `verifyOnThisDevice()` 只賭 `outcome.isFullyValid`（三個 FFI 事實）；牆端 `linkverify.Verify` 跑同一個配對驗證，**再加** `checkAppID`（`verifier.go:112-118`）與 `CheckChallenge`（`main.go:150-153`）。牆是嚴格超集。所以「本機過、牆拒絕」**不是矛盾，正是 `WALL_APP_ID` 設錯的預期徵狀**——而這份計畫指定這句話是那個設定錯誤唯一會浮現的地方。橘色三角形保留。

**400 `malformed`**「這支 App 送出的東西，這面牆讀不懂。」/「沒有任何東西被公開，也沒有東西被用掉。這是這支 App 的問題，不是你做錯了什麼。」橘色三角形——這一條**確實**是我們的錯。同一份證明可以再送一次（見上表），但不主動提供按鈕：能重送不代表值得重送。

**回覆遺失 / 非 JSON / 未知 5xx（第四種結果）**
「證明送出去了，但是沒有收到回覆。」/「它可能被加上去了，也可能沒有。這面牆不留任何能認出你的東西，所以沒有辦法查你那一筆有沒有算進去——這正是它匿名的原因。」無圖示。
兩個**次要**動作，沒有主要動作：
- 「看看這面牆現在的數字」（走同一個無 cookie 的 session 打 `GET /wall`；**不開 Safari**，理由見 §四之六）
- 「再簽一次，知道這可能會多出一筆」

**傳輸失敗（什麼都還沒花）**
`.offline`「連不上這面牆。檢查一下這支裝置的連線。什麼都沒送出，這支手機上也沒有任何東西改變。」
`.lowDataMode`「這需要 Wi-Fi 或完整行動網路。檢查連線，或關掉低數據模式。」（與 `CircuitAssets.swift:209-211` 同措辭，讓兩處讀起來像同一支 App）
`.hostDoesNotExist`「這個版本設定的位址不存在。這不是你的網路的問題。」
`.challengeDecimalDisagrees`「這面牆和這支 App 對一次性號碼的算法不一致。什麼都沒有送出去。這支 App 需要更新。」

**每一個終局畫面都必須出現的一對句子**，依這次 run 有沒有走過 `.signature` 二選一：
走過了 —「在這一步之前，你的身分證統一編號已經送到內政部了，那件事收不回來。」
沒走過 —「你的身分證統一編號沒有送出去給內政部。」

這一對是整份設計裡最容易漏掉、漏掉最貴的東西。

**成功**「簽好了。你的簽名在牆上了。」/「這面牆現在有 %d 個簽名。它沒辦法告訴你哪一個是你的，這支 App 也沒辦法。」

### 步驟 9｜`backupTW/ViewController/WallSignViewController.swift`

構造與 `ZKProofViewController` 相同：`UICollectionViewController`、inset-grouped list、supplementary header、diffable data source 走私有 `Group`/`Row`、`Row.Kind` switch 決定字體、`reload()` 整組重建並 `animatingDifferences: false`。stage 列直接重用 `ZKStagePresentation`。

`buildGroups()` 順序（在一個 method 裡決定，不在呼叫點組裝）：

```
about → wallLearns → badgeCannotShow → preparation? → action
      → stages? → result? → whatToDoNext? → theWall?
```

`wallLearns` = `WallDisclosure.allCases`（八列），`badgeCannotShow` = `plannedCaveats`（六列）。兩組都在按鈕**上面**，共十四列，刻意的：`ZKProofViewController.swift:112-120` 早就把這場爭論結掉了——決定發生在按鈕上方，caveat 放下面就不會被讀。牆只是把賭注提高，不是降低。兩個標題必須不同，好讓兩個軸讀得出來：「這面牆會知道什麼」與「這個徽章證明不了什麼」。

**`viewDidLoad` 不發任何網路請求。** `GET /wall` 只有在使用者點「看看這面牆現在有幾個簽名」時才發。這是 App 唯一的發布介面，它應該是最嚴的，不是最鬆的。只渲染 `signatureCount`；`recent` 那 60 列丟掉——它對簽署者沒有可行動的資訊，而它的截圖會把簽署者釘在一個分鐘窗裡。

**同意閘**，一個 alert：

標題「公開簽署這面牆？」
內文：「你的簽名會出現在 bonds.tw 的公開頁面上，而且會一直留著。它收不回來——這面牆不留任何能認出哪一筆是你的東西，所以沒有東西可以查，也沒有東西可以刪。這面牆數的是簽名，不是人。**按下去之後，這支手機會立刻向 bonds.tw 要一個一次性號碼**，就算你後來取消也一樣。」
確認「公開簽署這面牆」／取消。

最後那句是判官抓到的：同意之後、身分證輸入之前就會發出 challenge 請求，所以「按了同意又中途放棄」的人已經在牆的邊緣留下一次請求。在政治言論的威脅模型裡，「誰考慮過要簽但退回去了」不比「誰簽了」不敏感。順序不改（它是對的），但後果要說。

至於「發布這個動作到底該不該有 alert」——現有兩個對外送出（藍牙、存檔）都沒有，因為「掃描就是同意」是一個持卡人的物理動作。發布沒有這種動作，所以要人造一個：上面一長段可讀的揭露用來決定，一個短 alert 點名三件不可逆的事用來同意。

**同意之後的順序**（挑成「越可能失敗的越先、越便宜」）：

1. `plan()`；proving 素材沒齊 → 沿用現有下載同意 alert 的措辭與 `ZKStagePresentation.preparationSummary`，然後 `prepareFiles`。**沒有任何時鐘在跑。**
2. `guard ZKProofRunAssembly.canRequestSignature`（步驟 10）。
3. 起飛前警告，每個都可取消：低耗電模式／`thermalState` 為 `.serious`/`.critical`／`MachMemory.availableMemoryBytes()` 低於門檻（「不夠的話這支 App 會直接被關掉、沒有任何提示——一次性號碼也會跟著沒了」，因為 `ZKProofRunReport` 追蹤 headroom 正是為了 jetsam）。
4. **取號碼**。在身分證提示**之前**，所以一面死掉的牆花掉零個揭露決定，而身分證那個嚴肅的同意時刻不會為一個跑不起來的 run 而出現。打字約 30 秒，TTL 有 1800 秒。
5. `ZKProofViewController.makeIDNumberPrompt` **原封重用**。它已經是 `static`、已經有兩個動作與 `[weak alert]` 的測試。重用它代表牆這條路不可能跟 ZK 那條路的揭露文案漂移。
   ⚠️ 但確認鍵目前的文字是「Send the number to 內政部」（`ZKProofViewController.swift:625-631`，該處註解說明揭露必須寫在控制項上）。在牆這條路上這句仍然成立——按下之後下一個真的會發生的事就是 FidO 推播，因為 challenge 已經在第 4 步拿到了。**這是把取號放在提示之前的第二個理由**：它讓這顆按鈕的字保持是真的。
6. `ZKProofRunAssembly.makeSigner` → `WallSignRunner.run`。

**倒數列**在 challenge stage 底下，1 秒 timer，終局時 invalidate，用單調時鐘：「這個一次性號碼還有 %@ 就過期。」

**回到前景時重查**：使用者必須把這個畫面切到背景去行動自然人憑證核可，時鐘照跑。`willEnterForeground` 時若沒有 run 在飛、而手上的 challenge 已經不夠新，就丟掉並說出來。

**`isIdleTimerDisabled = true`** 貫穿一次 run，在 `endRun()` 與 `deinit` 還原。

**圖示對應**（把「unavailable 不是失敗」這條規則延伸到新軸）：`wallNotLive`、`hostDoesNotExist`、`signingSwitchedOff`、`rateLimited`、`verifierBudgetSpent`、`verifierUnreachable`、`challengeExpired`、`replyLost` → **無圖示**（關於牆或網路的事實，不是關於證明的）。`refused`、`rejectedAsMalformed` → 橘色三角形。`published` → 綠色勾。

**`PrivacyShieldedScreen`：要接。** 原本拒絕的理由（「使用者切背景時身分證 alert 已經關掉了」）是對使用者行為的假設，而機制不需要那個假設——`PrivacyShield.hasShieldedContent` 會走訪 `presentedViewController`（`SceneDelegate.swift:153-165`），所以接了就連 alert 在上面那一刻也蓋得住。而且**這是全 App 唯一一個「設計上規定使用者必須切到別的 App」的畫面**，同時它從一個標題會出現 bonds.tw 的設定區進來——App 切換卡本身就是一筆「這支裝置跑過連儂牆流程」的紀錄。一行 conformance，不要延後。順帶把 `ZKProofViewController` 也接上（同樣的洞今天就存在）。

### 步驟 10｜入口與唯一一處對既有 ZK 檔案的修改

**不放 Home。** `HomeViewController` 的兩個 section 裡，「📶 Offline check」的兩條副標都正面斷言沒有網路（`:140`、`:144`），`docs/lennon-wall.md` §6 也明說不能混。

在 `SettingsViewController` 的 `Experimental` section 加第二列，照該檔自己的規則（加 `Row` 常數 + `case`，用 `title` 比對，絕不用 `indexPath`），**整列包在 `#if DEBUG` 裡**：

```swift
static let signTheWall = NSLocalizedString("Sign the Lennon Wall", comment: "")
```

ZH 標題「簽署連儂牆」，副標取自 `WallSignCopy.settingsRowSubtitle`，symbol `paperplane`，tint `.systemPink`（全 App 唯一沒用過的色，重點就是它不該長得像旁邊那幾列）。`Item` 在 (identifier, title, secondaryText) 上必須唯一，否則 diffable data source 會 trap（`ListModel.swift:20-27`）。

`#if DEBUG` 的理由在文件開頭：Release build 連簽章都做不到。等 bonds-tw 簽章後端存在、且牆上線之後，把這列搬進 Home 的第三個 section「📣 公開簽署」並從 Settings 移除——一列，一個地方。

**唯一一處對既有 ZK 檔案的修改**，五行，放在 `ZKProofRunWiring.swift` 的 `makeSigner` 旁邊，讓兩者共用同一個 `#if` 而不可能不一致：

```swift
/// 這個 build 到底連不連得到 TW FidO，不需要身分證統一編號就能回答。
/// 牆的畫面必須在取號碼之前就有辦法拒絕；makeSigner 只有在持卡人打完字之後才答得出來。
static var canRequestSignature: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
}
```

測試釘住 `canRequestSignature == (makeSigner(idNumber: "A123456789", open: { _ in true }) != nil)`。

`backupTW/ZK/` 其餘一行不動。`ZKProofRunner`、`ZKHolderSigning`、`ZKProving`、`ZKRunStage`、`ProofChallenge`、`ProvingInputs`、`ZKProver` 全部不碰——verifier-challenge 這條路本來就是完整的，缺的只是一個 production caller。

### 步驟 11｜測試

`backupTWTests/WallSignTests.swift`，全部不需要一面活著的牆：

*challenge*
- `challengeParsesTheWorkersOwnFormat`
- `theFieldElementMatchesTheWorkersDecimal` — 表格驅動：全零（兩邊都是 `"0"`）、全 `ff`、**前導零 byte**、一組獨立算出十進位的隨機值。這條把 App 的 `decimalString(bigEndian:)` 釘在 `BigInt('0x'+nonce).toString(10)` 上。
- `theAsciiHexMistakeIsRefused` — 把 48 個 hex 字元當 UTF-8 bytes 餵進去，斷言它**大聲失敗**。跨語言數值協定的危險模式是安靜地算出另一個答案，所以錯的編碼也要釘。
- `aDisagreeingDecimalIsRefusedBeforeAnythingIsSpent`
- `anUppercaseNonceIsRefused`
- `expiryIsTrackedOnAMonotonicClockNotTheDeviceClock` — 把裝置時鐘往前撥一小時，challenge 仍然可用。
- `theStartThresholdAndTheSubmitThresholdAreDifferentNumbers`

*submission*
- `theSubmissionCarriesOnlyTheTwoProofsAndNoInstances`
- `theBodyHasExactlyThreeFields` — JSON 編碼後斷言 key **集合相等**。四行，擋的是兩年後有人加一個 device id 或 locale。
- `theProofFieldsAreStandardBase64NotBase64URL` — 用會產出 `+` 與 `/` 的 fixture，斷言不出現 `-`/`_`，且 `Data(base64Encoded:)` round-trip。
- `theArtifactNamesAgreeWithZKProver`
- `anOversizedBodyIsRefusedLocally`

*回應（用 `WallSigning` 假件驅動每一個 Worker 分支）*
- `everyWorkerBranchMapsToASentenceAndARetryCost` — §1.4 那張表當資料。
- `aRateLimitedSubmitLeavesTheProofSendable` / `aVerifierUnavailableSubmitDoesNot`
- `aLostReplyIsNeverReportedAsAFailure`
- `bothTwoHundredShapesAreToldApart` — 含一個同時帶 `verified:false` 與 `signatureCount` 的合成 body，必須讀成拒絕（fail closed）。
- `aNonJSONReplyToTheSubmitIsUnknownNotNotPublished` — **這條是那個 `read()` 在 INSERT 之後才跑的洞的守衛。**
- `anUnrecognisedFiveHundredIsUnknownNotNotPublished`
- `theSessionRefusesCookiesThreeWays`

*run*
- `aProofThisDeviceRefusedIsNeverSubmitted`
- `everyZKRunStageMapsToAWallStage`
- `unavailableIsNotDrawnAsAFailure`
- `aSecondConcurrentRunIsRefusedWithoutTouchingTheFirst`
- `aTerminalRunLeavesNoProofOrInstanceFileBehind`

*文案*
- `noWallProseOverClaims` — 禁用詞走訪 `allProse + WallDisclosure.allCases`：「完全匿名」/anonymous、「無法追蹤」「追查不到」、「可以刪除」「可以撤回」、「唯一」、「未被撤銷」，**外加 `不會離開這支手機`**（就是被抓到的那句的形狀）。
- `thePlannedCaveatsAreExactlyTheUnconditionalSix` — `#expect(WallSignCopy.plannedCaveats == ProofCaveat.unconditional)`。
- `theIssuerDisclosureIsPinnedToTheWrittenAssumption`

*邊界*（`WallBoundaryTests`，原始碼掃描）
- `backupTW/Wall/` 底下不出現 `VerifiablePresentation`、`MOICASignedCredential`、`StoredCard`、`ZKProofPackage`、`SelectiveDisclosure`
- `backupTW/Wall/` 底下恰好一個檔案出現 `URLSession`
- 牆這條路不出現 `CBPeripheralManager`、`AVCaptureSession`（讓 Info.plist 那兩句話保持真）

`backupTWTests/LocalizationCoverageTests.swift` 加四個 case（不是三個）：

```swift
@Test(arguments: WallDisclosure.allCases) func everyWallDisclosureReachesAChineseReader(_:)
@Test func everyWallErrorReachesAChineseReader()   // 手刻 everyError，比照 everyFailure
@Test func everyWallProseReachesAChineseReader()   // WallSignCopy.allProse
@Test func everyZKProseReachesAChineseReader()     // ZKProofCopy.allProse — 既有的洞
```

⚠️ **但 `readableInChinese` 本身要修，否則對這批字串是空跑。** `LocalizationCoverageTests.swift:43-48` 先看 `hasHan`（任一個 U+4E00–U+9FFF 的 scalar）就回 true，**才**去查 zh-Hant bundle。這支 App 的房規是把中文專有名詞直接嵌在英文 source string 裡，所以 `whatFailureCosts`（含「行動自然人憑證」「內政部」）零翻譯也會綠。修法：`hasHan` 改成「Han 字元佔比超過門檻」，或者「字串同時含有 ASCII 句子時不吃 `hasHan` 短路」。這一條不修，加那四個 case 只是把測試數字變好看。

所有字串進 `backupTW/Localizable.xcstrings`，英文字面當 key，zh-Hant 狀態 `translated`。目前是 488/488、零缺，要保持。**中文先寫、英文回頭對**——英文字面只是查表用的 key，中文才是里長辦公室裡的人真的會讀的東西。

---

## 四、對判官指出的每一條致命缺陷的處置

| # | 缺陷 | 處置 |
|---|---|---|
| 1 | `whatItDoes` 說身分證統一編號不離開手機 | **改**（步驟 8）。這是唯一一句系統完全撐不住的話。 |
| 2 | 90 秒 submit 逾時 < Go 的 `WriteTimeout` 120 秒 | **改**：180/240（步驟 2、§二之四）。 |
| 3 | `.notJSON` 先於狀態碼、且斷言「什麼都沒公開」 | **改**：submit 的任何非 JSON／未知回應一律 `.unknown`（§1.4）。 |
| 4 | `verified:false` 變體 A 說「兩邊不一致」 | **改**：牆是嚴格超集，這是 `WALL_APP_ID` 設錯的徵狀（步驟 8）。 |
| 5 | 一個 780 秒門檻回答兩個問題 | **改**：900 / 300 兩個常數（步驟 3）。 |
| 6 | `challenge-invalid` 被渲染成「過期」 | **改**：說「牆不認這個號碼」，兩個可能的原因都列（步驟 8）。 |
| 7 | 把 `wall.bonds.tw` 編死 | **改**：主機名是待拍板事項，DNS 失敗有自己的 case（§二之三、§七之一）。 |
| 8 | 內政部 SIGN 紀錄 × 牆的分鐘時間戳可以 join | **改**：新增 `WallDisclosure.issuerKnowsWhenYouAsked`；伺服器端緩解列入 §七之三。 |
| 9 | `nullifierReachesTheOperator` 只講一個號碼，漏掉 `pk_commit` | **改**：文案講「兩個號碼」；`pk_commit` 的範圍待確認（§七之五）。 |
| 10 | 「不送 instance 可以減少過 Cloudflare 的 public signal」是假的 | **改**：理由改寫成頻寬與型別誤用，並把「signals 從 proof bytes 就能還原」寫進註解（步驟 4）。 |
| 11 | `.ephemeral` 仍留 in-memory cookie jar | **改**：三道 cookie 設定 + 測試（步驟 2）。 |
| 12 | `countIsSignaturesNotPeople` 把「選擇」寫成「能力」 | **改**（步驟 7 第 5 條）。 |
| 13 | 拒接 `PrivacyShieldedScreen` | **改**：接，並順手接 `ZKProofViewController`（步驟 9）。 |
| 14 | run 結束後 instance 檔留在磁碟 | **改**：終局掃地（步驟 6 第 7 點）。 |
| 15 | `issuerNotCheckedByTheWall` 條件納入 = 編譯期猜執行期 | **改**：無條件納入 + 寫下來的假設常數 + 測試（步驟 7 第 8 條）。 |
| 16 | 「190 KB」少報三分之一 | **改**：250 KB（步驟 7 第 1 條）。 |
| 17 | `.unknown` 把「看看這面牆」放主要動作 | **改**：降為次要，且**不開 Safari**——同一個註冊網域、同一個 IP、幾秒之內、Safari 帶著完整 cookie 與既有身分，等於把剛剛看過你化名的那一方重新認出你的瀏覽器。整份 cookie 拒絕的努力會在那一下被抵銷。改用同一個無 cookie session 在 App 內打 `GET /wall`。 |
| 18 | 一律禁止重送，代價是多一次內政部揭露 | **改**：按 §1.4 分岔，`.resend` 四個分支提供「再送一次同一份證明」（§二之二）。 |
| 19 | Settings 副標與禁用詞測試走不到 | **改**：副標移進 `WallSignCopy`（步驟 8）。 |
| 20 | `readableInChinese` 對嵌了中文專有名詞的英文字串空跑 | **改**：修 `hasHan` 短路（步驟 11）。 |
| 21 | 「有一份設計說 `CheckChallenge` 沒接」 | **不採納那條**：它已經接了（`main.go:150-153`）。寫進 §二之一，避免有人去「修」。 |
| 22 | 決定性的牆端故障（過期 image、`WALL_APP_ID` 錯、缺 `used_challenge` 表）在 App 端長得像暫時性故障，重試無上限 | **部分接受**。App 端加一個 session 內的閘：同一次進入畫面連續兩次 `refused` 或 `verifierUnreachable` 之後，重試動作消失，改成「這面牆現在對每一份證明都給同樣的答案。等它修好再來。」明列在步驟 9 的 result section，不只寫在風險清單裡。**接受的部分**：App 端沒有遙測，看不出全域狀況，真正的煞車必須在牆端（§六第 8 條）。 |
| 23 | 每日預算數的是徽章不是驗證器呼叫，所以擋不住「系統性拒絕」 | **接受，且是牆端問題**。列入 §六第 8 條。App 端做不了。 |
| 24 | 不渲染 `recent` 60 列被當成隱私上的拒絕，其實什麼都沒減少 | **接受措辭修正**：`GET /wall` 是公開端點，不渲染只代表這支 App 自己不製造那張截圖。不再把它寫成緩解。 |

---

## 五、v1 刻意不做

- **不改 `ZKProofRunner`、`ZKHolderSigning`、`ZKProving`、`ZKRunStage`、`ProofChallenge`、`ProvingInputs`、`ZKProver`。** `fromVerifier(_:)` 早就在、測試早就整條驅動過它，缺的只是 caller。動 `ZKRunStage` 會讓既有畫面畫出永遠不動的列。
- **不送 `ZKProofPackage`。** Go 的 request struct 只有三個欄位，沒有一個是 instance。caveat 清單與 `producerSelfCheckPassed` 留在手機上——後者是被查驗方自己的說詞，本來就不該當證據送出去。
- **不把 base64 交給 `JSONEncoder` 的預設 `dataEncodingStrategy`。** 明寫成 String，讓「標準字母表（被 Go 的 `encoding/json` 逼出來的）」這個選擇出現在呼叫點，而不是躲在一個沒人讀的預設值裡。
- **不採用 Worker 的 `decimal` 當 field element。** 用 App 自己的 `fieldElement()` 重算再比對。
- **不為「公開發布」加 `ProofCaveat` case。** 那是目的地的性質，不是證明的性質。混在一起會讓 `ProofCaveat` 同時代表兩件事。
- **不放進 Home 的「📶 Offline check」。**
- **不加 `NSAppTransportSecurity`／`NSExceptionDomains`／`NSAllowsLocalNetworking`／憑證 pinning。**
- **不從 `viewDidLoad` 打 `GET /wall`。**
- **不做「查我那筆有沒有算進去」。** 它需要一個 per-signer handle，而整份設計就是拒絕擁有那個 handle。做一個假的（比對時間戳、比對數字差）比留著這個缺口更糟。
- **不做任何自動重試、不排隊、不背景上傳、不 resume。** 背景 URLSession 會把 body 落到磁碟並在 App 被關掉之後繼續送，等於把一份證明放在 App 清不掉的地方。
- **不快取 TW FidO 的簽章素材來讓重試變便宜。** `(cert, signed_response)` 可以在沒有持卡人在場的情況下、對任何新 challenge 永遠鑄出有效證明（`ZKProver.swift:421-434`）。這是這裡最誘人也最危險的最佳化。
- **不把伺服器回的文字放上畫面。** Worker 的 `error` 字串是不可信輸入，每個分支對應本地 `NSLocalizedString`。
- **不設自訂 User-Agent。** 預設值已經指名這支 App，TLS 指紋也會，牆的 `badge` 欄位本來就分得出 App 與網頁。中性 UA 買不到東西，假的 UA 是說謊。
- **不把 TW FidO 的 `time_limit` 從 600 秒調短來換時鐘餘裕。** 600 + 證明 + 240 ≈ 850 秒對上 1800 秒已經兩倍餘裕，調短只是懲罰切 App 比較慢的人。
- **不顯示證明階段的百分比進度條。** FFI 沒有進度可回報，`ZKRunStageState.running(progress: nil)` 已經寫明：不確定的轉圈勝過一根卡在 0% 的長條。

---

## 六、`signZK` 可以接路由之前必須成立的事

對應 `docs/wall-verification-options.md` 第 20 條。前四條是 App 這邊直接依賴的，後面幾條是我讀出來的缺陷。

1. **兩條路由接上**（第 12 條）。在那之前 App 的行為是「這個版本找不到那面牆」，那是一個有名字、有句子的分支，不是 bug。
2. **`issueChallenge` 要一起檢查 `CITIZEN_ENABLED`。** 現在它只檢查 `CHALLENGE_SECRET`（`index.ts:266`），所以一面會拒絕每一次提交的牆，照樣愉快地發號碼。那會製造這份設計裡最糟的路徑：身分證統一編號送出去了、FidO 跑完了、證明做完了，然後在 submit 拿到 503。一行：
   ```ts
   if (env.CITIZEN_ENABLED !== '1') return json(request, { error: 'unavailable' }, 503);
   ```
   App 仍然要處理「拿號碼之後才被關掉」（預算會用完、驗證器會在兩通之間死掉），但這一行把「號碼什麼都不代表」變成「號碼是一個剛才還成立的承諾」。
3. **`signZK` 裡的 Cloud Run `fetch` 要包 try/catch，並帶 `AbortSignal.timeout`。** `index.ts:425` 沒有 catch，subrequest 丟例外就是一個沒有 JSON body 的裸 500——而那個時候 `claimChallenge` 已經跑過了。App 只能把它歸到 `.unknown`（「我們不知道」），那對使用者嚴格劣於「沒有公開」。加一個 catch 就把未知變成已知。逾時值要小於 App 的 180 秒。
4. **`used_challenge` 套進正式 D1**（第 21 條）。沒套的話每一次 `claimChallenge` 都在 INSERT 上丟例外——配合第 3 條，會以一個未攔截的 500 抵達 App，什麼都沒燒卻長得像燒了。
5. **`WALL_APP_ID` 設成 `55349ff540392a077ca3dcc9bbda4c3`，並把啟動檢查從 rune 改成 byte。** `main.go:213` 量 `len([]rune(appID))`，`checkAppID` 比的是 `UnpackAppID` 產出的 31 **bytes**。帶任一個多位元組字元的值會通過啟動檢查，然後讓每一份證明永遠失敗，而且長得跟卡片壞掉一模一樣。
6. **設 `IssuerCert`。** `main.go:239` 是 `nil`，而 `linkverify.Verify:99` 在 nil 時整段跳過 `checkIssuerModulus`——**一份由偽造 MOICA 簽出來的證明會通過這個 binary 執行的每一項檢查**，同時 `handleHealth:187` 對外宣稱它檢查了 `issuer_modulus`。這是 go-live 阻斷條件，不是用文案能繞過去的東西。在修好之前，`handleHealth` 那份清單本身是假的，應該先改成只列真的有跑的檢查。
7. **決定分鐘時間戳要不要保留**（§四之八）。這是唯一一個 App 端無解的隱私向量。選項：公開粗到小時；或寫入時加隨機延遲；或維持現狀但把 §七之三 那句揭露當成正式立場。
8. **兩個計數缺陷。** `citizenSignaturesToday` 數的是 `badge='citizen'` 的列，而唯一寫 `'citizen'` 的 INSERT 在 `verdict?.verified !== true` 提早返回**之後**——所以一面系統性拒絕的牆（`WALL_APP_ID` 錯、image 過期、proof type 不合）會永遠叫醒並計費 Cloud Run，而每日預算永遠不會觸發。另外 `Number(env.VERIFIER_DAILY_LIMIT ?? '200')`（`index.ts:400`）沒有 NaN 防護，一個非數字的值會讓 `>= limit` 永遠為 false，把唯一的花費閘門安靜關掉。
9. **（選配）成功 body 加 `verified: true`。** App 照今天的形狀寫（先看 `verified`、再看 key 存在），所以這只是去掉一個脆弱點，不會解鎖任何東西。`read()` 回的是 `Response`，要小改；不值得就跳過。

---

## 七之〇、其中四條已經結案（2026-08-17／18）

**5（`pk_commit` 有沒有 relying-party 域分隔）→ 我的推論被推翻了。**

電路原始碼在本機的 Cargo checkout 裡（`zkid` submodule 是空的，從沒 checkout 過；
真正的來源在 `~/.cargo/git/checkouts/zkid-*/36bcdd4/wallet-unit-poc/circom/`）。

`pkCommit` 是 `userPkLimbs` **加上 `pkBlind`** 的 Poseidon hash，而 `pkBlind` 是每
一次證明工作階段從 OS RNG 現抽的 31 bytes（`random_pk_blind`，`mobile/src/lib.rs`
每產一對證明呼叫一次）。**它不是識別碼**——同一個人對任何人證明任何事，每次都是不
同的值。電路自己的 SPEC 指名「持有整份 MOICA 憑證目錄的攻擊者」，並說這個 blind
正是防那件事的東西。

所以 App 原本的註解「Ties the two proofs together」是對的，不需要警告。

**而我寫的揭露文案因此是錯的**：它說「兩個對你每次都一樣的號碼」。**高估危害也是
寫錯**，而且就寫在一份用測試禁止過度宣稱的檔案裡。已改成「一個號碼」，三處引用一
起改。

⚠️ **不過有一件值得回報上游的**：隱藏性是**證明端保證的，不是電路保證的**。沒有
任何約束逼 `pkBlind` 要新鮮，`ChunkedPoseidonP256` 自己的註解就寫著「NOT inherently
hiding」。一個把 `pkBlind` 釘死的皮夾實作，會**安靜地**把 `pk_commit` 變成我原本
以為它已經是的那個跨服務全域識別碼——而查驗端與使用者都看不出來。上游的 CLI 對
`--pk-blind` 覆寫有警告，但電路裡與查驗端都沒有檢查。以那份 SPEC 自己假設的攻擊者
來說，「皮夾必須被信任會正確抽樣」是一個值得在協定文件裡明講的部署假設。

（現行出貨路徑是安全的：`mobile/src/lib.rs` 每次都從 `getrandom` 現抽。）


**1（主機名）→ `https://bonds.tw/api/wall`。** 授權下來之後才發現**權限本身把答案
決定了**：token 只有 `zone (read)`，建不了 DNS 記錄，而 Workers 自訂網域要的正是
那筆寫入。路徑 route 只要 `workers_routes (write)`，有。

而路徑其實是更好的選擇，理由跟 DNS 無關：**這個字串會被編進一個要送到手機上的二
進位檔**。`bonds-wall.gimmychang.workers.dev` 是某個人帳號的子網域——帳號改名，每
一份已安裝的 App 就永久失去這面牆，而且沒有辦法推修正給一支不更新的手機。

⚠️ 加 route 的第一次部署**把 live wall 弄掛了約三分鐘**：`routes` 會把 workers.dev
子網域預設關掉，而網站前端正寫死指向它。實測，不是推論。詳見 `MOVING.md`。

**2（路徑名）→ base 是 `https://bonds.tw/api/wall`，其下 `challenge`／`sign-zk`。**
dispatcher 同時接受 `/api/wall` 前綴與裸路徑，因為換手期間兩種 client 都存在。

**3（分鐘時間戳）→ 保留，並且升格成「立場」。** 所以它必須寫在它影響的人看得到的
地方——按鈕旁邊，不是設計文件裡。牆上原本只寫「只留下徽章類型與時間」，現在明講
「到分鐘為止，寫進去的時候就截掉」，並加一句說清楚殘留風險。中英兩版同步。

**6（`go.mod` / `go.sum`）→ 建好了**，pin 在上游 commit `4bd1fdb`。⚠️ 在 Mac 上
`go build` 會停在連結階段（`ld: library 'zk_verifier' not found`），那是預期的，也
是 Dockerfile 開頭就寫著「用 Cloud Build，不要在 Mac 上建」的原因；編譯本身乾淨。

**4（`IssuerCert`）→ 部分結案。** 它不再是 `nil`：`main.go` 現在從
`issuercert.NewProvider`（`LoadEmbedded`）建信任庫，**沒有它就不准啟動**。原本的
`nil` 不是「用預設值」——`linkverify.Verify:99` 是 `if v.IssuerCert != nil`，nil 會
把 `checkIssuerModulus` 整段跳過，而 `/healthz` 同時宣稱它檢查了 issuer_modulus。
`/healthz` 的清單現在從實際跑著的 verifier 推導。

**但 `WallDisclosure.issuerNotCheckedByTheWall` 仍然無條件納入**，而且那是刻意的：
App 的文案是編譯期常數、走 App Store 送審週期，verifier 的組態是維運者幾分鐘就能
改的 runtime 事實。把前者綁在後者上，兩邊都會在某些時刻是錯的。

---

## 七、還決定不了、需要你拍板的

（下列為仍未結案的三條。原本七條的 1／2／3／6 見上。）

1. **牆的正式主機名。** 這是最硬的一個：`wall.bonds.tw` 不存在（`dig` 無回應、`wrangler.jsonc` 沒有 `routes`/`custom_domain`、`MOVING.md` 明寫「⚠️ 尚未做……那是動到 live 網域的 DNS，沒有先問就不做」）。今天存在的只有 `https://bonds-wall.gimmychang.workers.dev`——那個名字裡有帳號擁有者的本名，會出現在每一支 App 的每一次網路請求裡。**在拍板之前不編任何 production 值。** App Store 的二進位檔不像 Worker，改不了。
2. **兩條路徑的名字。** `/wall/challenge` 與 `/wall/sign-zk` 是我方單方面的提案，bond-website 裡不存在任何相關字串（`/wall/sign` 已被開放徽章佔走）。這要在出貨的那個 build 之前談定。
3. **分鐘時間戳與內政部 SIGN 紀錄的 join，要不要處理。** §四之八 / §六第 7 條。這是「一面宣稱匿名的牆，比沒有這面牆更糟」那個風險真正的形狀，而且它不在原本任何一份威脅模型的預設攻擊者裡（那些模型假設攻擊者需要 nullifier）。
4. **`IssuerCert` 什麼時候會設。** 決定 `WallDisclosure.issuerNotCheckedByTheWall` 是永久文案還是過渡文案，也決定徽章到底代表「一份有效的證明」還是「一張自然人憑證」。
5. **`pk_commit` 有沒有 relying-party 域分隔。** 我推論它沒有（兩份證明必須各自算出相等的值，而 cert_chain 電路根本沒有 app_id 輸入），但這要在電路原始碼裡確認。如果沒有，它就是一個跨所有 zkID 部署的全域固定識別碼，比 nullifier 嚴重，而且 App 自己的註解（`ZKPublicInputs.swift:153-155`）完全沒有警告它。在確認之前，文案用「兩個號碼」的寫法在兩種情況下都成立。
6. **`go.mod` / `go.sum` 在哪裡。** `verifier/Dockerfile:43` 要 `COPY go.mod go.sum ./`，但兩個檔案在 repo 裡不存在也沒被 gitignore——所以**這個 verifier binary 照現在 committed 的內容建不起來**，而 pin 住的 go-zkid-verifier 版本只能從本機 module cache（`v0.0.0-20260807153223-4bd1fdb32af1`，對應本機 checkout 的 commit `4bd1fdb32af1`）看出來。這件事在第 5 條與第 6 條之前就會擋住任何重新部署。
7. **一次 rs4096 + rs2048 證明在實機上到底要多久。** 這份計畫到處用「約 10 秒」，那是估的，不是量的。它進到 `minimumUsableToStart = 900` 的算式裡，也決定了低耗電模式／過熱警告的門檻該落在哪。**收工前該量一次**，做法比照 `ZKLinkSendViewController` 當初把外推的傳輸時間換成「21.7 秒，2026-08-13 實測」的那次——那次外推錯了 2.5 倍。
