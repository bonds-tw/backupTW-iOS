# 把台灣數位憑證皮夾（TWDIW）整合進來：完整規劃

2026-08-16。回答「做一個第三方皮夾 App，讓官方認證的發行者、驗證者都能跑完整流程，
皮夾裡除了我們自己的『身分證』還有電子卡、數位駕照，藉此證明**最理想的皮夾長什麼樣子**」。

一手來源：<https://docs.denkeni.org/twdiw>（denkeni 的 TWDIW: The Missing Manual
與其 Related Personal Notes）、官方開源專案 `moda-gov-tw/TWDIW-official-app`（MIT）。
本文所有數字與行號都是我自己抓下來對過的，不是引述。

---

> **2026-08-16 補：對正式環境的實測，訂正了本文兩處說法。**
> 下面 §八是當天對公開端點做的唯讀量測（沒有送出任何表單、沒有申請帳號）。
> 原文保留不改，因為看得見推理怎麼歪的比看起來一路正確有用。
>
> | 本文原本寫的 | 實測 |
> |---|---|
> | `orgType=1`（政府部門）| **`orgType` 不是政府/民間之分。** 43 筆的 `orgGroupDetail.name` **全部**是「政府部門」，包括全家便利商店、統一超商、中華電信。`orgType` 1/2 看起來是發行端/驗證端。 |
> | 「官方皮夾產生的 did:key 不符合 JCS」（§一.D）| 方向對，範圍要縮小：**正式環境 43 個發行者 DID，43 個全部合規**，自簽章也 43/43 驗得過。**不合規的只有皮夾自己的 holder DID。** |
>
> 這個縮小很重要：它表示寬容規則只需要用在 `sub`（持有人），
> `iss`（發行者）那一側全世界都是正規的。
> 我原本想過因此對發行者 DID 強制正規化——**但那是錯的取捨**，見 §八.C。

## 〇、一句話結論

**第三方皮夾今天就走得通，因為 TWDIW 沒有「皮夾」這個概念——它不認皮夾，只認金鑰。**

這件事同時是我們的入口與它的缺口，而且兩邊都要說出來。

順帶一個讀文件時就該注意的訊號：denkeni 那份手冊裡，標題叫
**「If You're Building a Third-Party Issuer or Verifier Software」的那一節是空的**，
而「第三方**皮夾**」連標題都沒有。生態系目前的注意力全在發行端與驗證端。

---

## 一、量到的事實

以下每一條都可複現。

### A. 三個角色，只有兩個有門檻

| 角色 | 要做什麼才能上場 |
|---|---|
| 發行端 | 申請沙盒帳號 → 自架 issuer → 跟 TWDIW 團隊做 UAT → 正式 |
| 驗證端 | 同上，換成 verifier |
| **皮夾** | **文件沒有寫。沒有申請表、沒有註冊、沒有 attestation。** |

沙盒帳號申請頁（`wallet.gov.tw/apply/applyAccount.html`）的對象是「產品、服務或程式之串接測試」，
指向 `issuer-sandbox` 與 `verifier-sandbox` 兩個後台。**沒有 wallet-sandbox。**

### B. `client_id` 不是名單，是回音

這是整份規劃裡最重要的一條，證據鏈全在 MIT 授權的官方原始碼裡：

| 步驟 | 位置 | 內容 |
|---|---|---|
| 1 | `twdiw-vc-handler/…/CredentialService.java:1715` | 發行端自己簽的 ID Token，`aud` **寫死字串** `"moda_dw"` |
| 2 | `twdiw-oid4vci-handler/…/CredentialIssuer.java:225` | `client_id = IDT_payload_obj.getAsString("aud")` ← 從**自己剛簽的** ID Token 讀出來，存進 pre-auth code |
| 3 | 同上 `:1196` | `/token` 用 `getPreAuthCodeByClientIDAndPreAuthCode(client_id, pre_auth_code)` 比對 |
| 4 | 同上 `:1741` | proof JWT 的 `iss` 只跟 access token 上記著的那個 client_id 比 |

**整條鏈驗的是「你送的字串等於你送的字串」。** 沒有 client 註冊、沒有允許清單、
沒有 wallet attestation。`moda_dw` 這個值不是憑證，是一個從發行端自己出發、
繞一圈回到發行端的常數。

推論兩個方向都成立：

- **對我們**：入場沒有技術門檻。第三方皮夾送 `client_id=moda_dw` 與官方 App 無法區分。
- **對 TWDIW**：這是一個要回報的缺口。**已發出的憑證與「它被哪個皮夾拿走」之間沒有任何綁定**，
  所以「只有官方 App 能持有官方憑證」這句話（如果有人這樣說）在程式碼層級不成立。

真正被驗的東西是金鑰：proof JWT 的簽章會用 DID 裡取出的公鑰驗過
（`CredentialIssuer.java` 尾段 `ECDSAVerifier` → `signedJWT.verify`），
而那把公鑰接著被寫進憑證的 `cnf.jwk`。**裝置綁定是真的，皮夾身分是假的。**

### C. did:key 的拼法不一樣，我們現在會被拒

TWDIW 的 DID 長這樣（真實的，來自機關清單）：

    did:key:z2dmzD81cgPx8Vki7JbuuMmFYrWPgYoytykUZ3eyqht1j9Kbrzifm9txeer…

我把它 base58btc 解出來逐位元組看過：

    總長 129 bytes
    前 3 bytes = D1 D6 03  →  varint 0xEB51 = multicodec `jwk_jcs-pub`
    其餘 126 bytes = {"crv":"P-256","kty":"EC","x":"kY6ina…","y":"c5je-…"}

也就是說 **payload 是整份 JWK 的 JSON 文字**，不是壓縮點。官方後端的解法是：

```java
String did_hex_prefix = CryptoHelper.convertBinaryToHexString(Base58.decode(did.substring(1)));
String did_hex = did_hex_prefix.substring(6);   // 去掉prefix D1D603
String did_jwk = new String(CryptoHelper.hexStringToByteArray(did_hex));
```

`did.substring(1)` 假設 multibase 是 `z` 而不檢查；`substring(6)` 把 multicodec
**寫死成三個位元組**切掉而不檢查。所以 TWDIW 只吃這一種 did:key。

**我們的 `DIDKey` 用的是 `p256-pub`（0x1200），產出 `did:key:zDn…`。**
送過去會被切掉前三個位元組、當成 JSON 解析、必然失敗。

→ 第一件工程是**多一種拼法，而不是換掉現有那種**。我們自己那條離線路徑的 DID 不該改。

### D. 而且官方皮夾自己的 DID 不符合它宣稱的編碼

`jwk_jcs-pub` 這個 multicodec 的定義就是 JWK 經過 JCS（RFC 8785）正規化。
JCS 要求鍵依 UTF-16 碼元排序，也就是 `crv` < `kty` < `x` < `y`。

| DID | JSON 鍵序 | 合規？ |
|---|---|---|
| 機關（moda）| `crv, kty, x, y` | ✅ |
| **官方皮夾的 holder DID** | `crv, x, y, kty` | ❌ `kty` 掉到最後 |

我們的 `DIDKey` 有一個 `nonCanonicalDID` 錯誤案例，存在的理由正是拒絕這種東西
（「DID decodes to a valid key but is not the spelling this key produces」）。

**所以一個嚴格照規範實作的解析器，會拒絕真實世界唯一存在的那個台灣皮夾產生的 DID。**

由此定下一條規則，寫進程式碼註解：

> **我們自己產生的 DID 一律 JCS 正規；解析別人的 DID 一律不要求正規。**
> 不對稱是刻意的——正規化是**我們**對自己的義務，拿它去否決別人只會讓我們無法互通。

### E. 撤銷是一份每天過期的線上清單

`StatusList2021`。`GET https://issuer-vc.wallet.gov.tw/api/status-list/<config>/r0`
回一個 ES256 JWT，`credentialSubject.encodedList` 是 gzip+base64 的 bitstring。

實測那份 JWT 的 `nbf` = 1759823761、`exp` = 1759910161，**差正好 86,400 秒**。

→ **離線超過 24 小時，TWDIW 憑證的撤銷狀態就不可知。**
這跟我們 MOICA 那條路的 SMT 快照是同一個形狀的問題，但更緊（我們的快照沒有硬性 24 小時上限）。
新鮮度上限要訂第二個，而且不能沿用第一個的數字。

### F. 官方憑證帶身分證統一編號——跟我們相反

駕照電子卡實測的揭露欄位（`~` 之後那六段 base64，我解過）：

    name           陳筱玲
    id_number      A234567890
    roc_birthday   0570605      ← 民國 57-06-05 = 1968-06-05
    type           普通小型車
    controlnumber  4010402091445
    gDate          1020701

⚠️ **這六個值我第一次抄錯了三個**（姓名寫成「陳籍玲」、身分證多一位變成 11 碼、
管轄編號中間多一個空格）。原因是從 Craft.do 渲染後的頁面上讀，而不是把 base64
解開來看。上面是解碼後的值。**渲染過的內容不可以當資料來源**——
一個 11 碼的「身分證統一編號」如果留在文件裡，後面每一個讀它的人都會被誤導。

對照我們自己量過的事實：**自然人憑證的 Subject DN 裡沒有身分證統一編號**
（只有 C/CN/serialNumber 16 位數字），所以我們那條路**扣不住姓名，也拿不到號碼**。

**皮夾裡會同時放著兩種相反的卡**，這是產品的核心對比，不是技術細節：

| | 我們的自發行卡 | TWDIW 駕照電子卡 |
|---|---|---|
| 統一編號 | 拿不到 | 有，且可選擇性揭露 |
| 姓名 | **扣不住**（在 X.509 CN 裡，結構性） | 可扣住 |
| 離線可驗 | 可以 | 撤銷狀態 24 小時後不可知 |
| 信任誰 | 內政部的簽章，離線自證 | 發行機關 + 線上信任清單 |

### G. 沒有 IAL——皮夾看不出「櫃檯驗過證件」與「使用者打字」的差別

denkeni 自己問「是不是用 `kid: key-1` 標示 IAL？」，自己回答「(Update: nope)」。

實測 IAL-1 的 VC（自己在網頁填的 email）與 IAL-3 的 VC，**結構上一模一樣**：
同一個 `jku`、同一個 `kid: key-1`、同一個 `typ: vc+sd-jwt`、同一個發行者 DID。

唯一的差別是 `vc.type[1]` 那個不透明字串（`0052696330_email` vs `00000000_yoyoy`）
與發行者是誰。**憑證本身不帶身分確信度。**

→ 這正是 `PresentationScenario` 存在的理由，也是它目前沒有涵蓋的一類。

### H. 兩個規範偏差，會咬到嚴格實作的客戶端

1. **`format` 說謊。** issuer metadata 寫 `"format": "jwt_vc_json"`，
   實際回傳的是 `typ: vc+sd-jwt` 加上 `~` 分隔的揭露串。
   照 `format` 解析的客戶端會把整串當成一個 JWT，**永遠看不到揭露**。

2. **VP token 裡是 `"vp":{"context":[…]}`——沒有 `@`。**
   我從真實 vp_token 的 base64 解出來確認過。JSON-LD 處理會把整個 VP 的主張丟掉，
   而簽章照樣驗得過。**這正是我們 M1 被咬過的那個 bug 的同一個家族**
   （當時只掛 `credentials/v2`，expansion 靜默丟掉 `unifiedNo`／`birthdate`／`addressOfHousehold`）。

---

## 二、這些事實決定了「最理想的皮夾」長什麼樣

使用者要的是**證明**，不是相容性打勾。所以要先講清楚論點是什麼。

「最理想的皮夾」的區別**不是「裝得下很多張卡」**——官方 App 也裝得下。
是這個：

> **它把每一張卡證明得了什麼、證明不了什麼，寫在卡的旁邊。**

我們現在有硬證據說明為什麼這件事非做不可：官方那一套**分不出 IAL-1 與 IAL-3**、
**分不出哪個皮夾持有憑證**、**離線超過一天就不知道憑證還有沒有效**。
這些不是它的失誤清單，是**任何皮夾都必須替使用者承擔的資訊落差**，
而目前沒有任何一個介面在承擔。

所以最理想的形態是**三種來源的卡並排，每一張下面一行它自己的限制**：

| 卡 | 它證明得了 | 它證明不了 |
|---|---|---|
| 有備而來．自發行（MyData + 行憑簽章）| 離線可驗、內政部簽章當場可證 | 不可連結（姓名在憑證 CN 裡，結構性）、拿不到統一編號 |
| 有備而來．零知識 | 不揭露欄位即可證明持有 | nullifier 對所有查驗者相同、1.09 GiB／9.26 秒 |
| TWDIW．駕照電子卡等 | 發行機關背書、欄位齊全（含統一編號）| 看不出 IAL、離線 24 小時後撤銷不可知、必須信任發行者 |

**這個並排本身就是論證。** 不是「我們也支援官方標準」，
是「把三種信任模型放在同一個畫面上，它們的差異第一次變得可見」。

而我們已經有做這件事的機件：`PresentationScenario`、`CapabilityViewController`
（`.partial` 不得看起來像 `.supported`）、caveat 一律攤開不收在展開箭頭後面。
**這次是把既有的骨架接上第三種卡，不是從頭發明。**

---

## 三、M5 拆解（五個階段，每一個都有閘門）

排序原則：**不需要別人配合的先做**。

### M5.1 did:key 第二種拼法 + 解析寬容規則

新增 `jwk_jcs-pub`（0xEB51）的編碼與解碼，與現有 `p256-pub`（0x1200）並存。

- 產生：JWK 一律走 JCS（鍵序 `crv, kty, x, y`，無空白）。
- 解析：**不要求**輸入是 JCS 正規（見 §一.D）。
- fixture 直接用本文 §一.C／§一.D 的兩個真實 DID。

**閘門：拿官方那個非正規的 holder DID 當測試向量，必須解得開，
且不得被我們自己的正規化檢查拒絕。**

不碰網路，可離線做完。**這一階段本身就會產出一份可以回報上游的錯誤報告。**

### M5.2 OID4VCI 領卡（沙盒）

流程（實測順序）：

1. `GET <issuer>/api/issuer/<taxId>/credential-offer-object?nonce=…&sub=…`
   → `pre-authorized_code` + `credential_configuration_ids`
2. `GET <issuer>/api/issuer/<taxId>/.well-known/openid-credential-issuer`
   → `credential_endpoint`、`credential_configurations_supported`、欄位 display 名稱
3. `POST <issuer>/api/issuer/<taxId>/token`（form-urlencoded）
   `grant_type=urn:ietf:params:oauth:grant-type:pre-authorized_code`、`client_id`、
   `pre-authorized_code`、`authorization_details`、`tx_code`
   → `access_token`、`c_nonce`（600 秒）
4. `POST <issuer>/api/issuer/<taxId>/credential`（Bearer）
   `{"credential_identifier":…,"proofs":{"jwt":[…]}}`
   proof JWT：`typ: openid4vci-proof+jwt`、`kid` = holder did:key、
   `iss` = client_id、`aud` = issuer identifier（**結尾有斜線**）、`nonce` = c_nonce
5. 領到後另外抓 `…/api/images/cover/<taxId>/<config>` 當卡面

**閘門：從 `demo.wallet.gov.tw` 領到一張駕照電子卡，存進既有的 `CredentialStore`。**

`CredentialStore` 本來就是一檔一憑證、有 `allIDs()`，**結構上已經是多卡的**，不必改。

⚠️ **`client_id` 要送什麼，是一個「先量再決定」的點，不是先決定。**
送 `moda_dw` 一定會通（§一.B），但我們不應該長期冒用官方 App 的識別字串。
做法：**先送 `tw.bonds.backupTW`，量它會不會被拒。**

- 若通過 → 就用我們自己的，並回報上游「這個欄位目前不具鑑別力」。
- 若被拒 → **這件事本身就是要回報的發現**：TWDIW 沒有辦法讓第三方皮夾正當地表明身分，
  於是唯一能跑的方式是冒充。那是一個設計問題，不是我們的實作問題。

前置條件：沙盒帳號申請是給發行／驗證端的。**但 demo 站的「訪客領卡」不需要帳號**
→ 可以先不申請就把整條路跑通。要不要申請帳號、要不要按同意服務條款，**由使用者決定**。

### M5.3 SD-JWT VC 讀取與選擇性揭露

TWDIW 的 SD-JWT 把 `_sd` 放在 `vc.credentialSubject` 底下，**不是** SD-JWT VC 標準的
頂層 claims（沒有 `vct`，用 `vc.type`）。所以是一個 VCDM 1.1 與 SD-JWT 的混血。

我們的 `SelectiveDisclosure` 已經是同一套加鹽承諾機制（每條 128 bits 鹽、承諾摘要排序、
拒收未被承諾的揭露），**接得上，但要另寫 adapter，不要把我們的格式改成它的**。

**閘門：六個揭露全部解得開；而且我們既有的三條紅線測試要覆蓋 TWDIW 格式
——尤其「拒收未被承諾的揭露」。**

### M5.4 OID4VP 出示

`POST <verifier>/api/oidvp/authorization-response`（form-urlencoded）：
`state`、`vp_token`、`presentation_submission`。

vp_token 是 holder 金鑰簽的 JWT，`aud` 的形狀是
`redirect_uri:https://verifier-oid4vp.wallet.gov.tw/api/oidvp/authorization-response`
（**前面真的有 `redirect_uri:` 這個字首**）。

⚠️ **要不要複製 `"context"` 這個錯字（§一.H.2）？**
**要**——出示要被官方驗證端收下，就得照它實際吃的格式；
但要在程式碼裡註明**為什麼、從哪天開始、以及上游修好之後要拿掉**。
一個沒有註解的相容性 hack，三個月後會被當成我們自己的 bug 修掉。

### M5.5 卡片並排與能力對照

首頁三種來源並列，每張卡接上 `PresentationScenario`。
TWDIW 卡要新增兩條既有 caveat 型別沒有涵蓋的：

- **「這張卡看不出身分確信度」**（§一.G）
- **「離線超過 24 小時，撤銷狀態不可知」**（§一.E）

⚠️ `LocalizationCoverageTests` 目前涵蓋三種 caveat 型別但**不涵蓋
`PresentationScenario`**（這是 UX 盤點的 b-1，同一個洞）。
新增 caveat 之前要先把覆蓋補上，否則新的英文字串會照樣全綠。

---

## 四、明確不做的

這一節存在的理由跟 UX 盤點那一節一樣：**相容性工作天然傾向「把差異抹平」**，
而這個專案的價值恰好在差異本身。

- **不做第三方發行端／驗證端。** 要自架、要 UAT、要跟團隊排程，而我們的價值不在那裡。
  皮夾是我們唯一有話要說的角色。
- **不把我們的自發行憑證改成 TWDIW 格式。** TWDIW 的 VC 依賴線上撤銷清單與線上信任清單；
  改過去等於把我們的離線保證稀釋成它的等級。**兩種卡並存才是論點，統一格式會殺掉論點。**
- **不用 `moda_dw` 當長期身分。** 可以拿來量，不可以當結論。
- **不把 TWDIW 信任清單當成我們的 `TrustList`。** 它是 HTTPS API 加鏈上錨點
  （Arbitrum 合約 `0x84172caf8dd126c76f1fa8a2733ca3233264d31f`），
  跟我們 #26 的離線承諾模型是兩件不同的事。詳見 §五。
- **不做 NFC。** 官方只有 Android 持有端 SDK 有。
- **不做 ZK 與 TWDIW 的接合。** TWDIW 的電路不存在，我們的電路吃的是 MOICA 憑證鏈。
  兩者沒有接縫，硬接會產生一個看起來像零知識、實際上要信任發行者的東西——
  **那比不做更糟。**

---

## 五、順手處理 #26 卡住的那個設計決定

#26（TrustList 接進查驗器）卡在「`expectedCommitment` 從哪裡來」。

TWDIW **不能**直接回答這個問題——它的模型回答的是另一個問題（誰來公告清單），
而我們的問題是（一台離線的裝置怎麼知道自己手上是對的清單）。

但它提供了一個具體的東西：**一份真實存在、由第三方營運、可以指名的機關清單。**
於是 `OfflineVerifier` 現在那句「這台裝置上沒有信任清單可以評估第三方簽發者」
可以變成兩條分開的路：

- **我們自己那條路**（MOICA 簽章）：維持離線承諾模型，`expectedCommitment` 的來源仍待決定，**不受此案影響**。
- **TWDIW 那條路**：信任清單**線上取得、且明確標示為線上取得**，
  卡片上直說「這張卡的可信度取決於一份剛才從網路上拿到的清單」。

**這不是把 #26 解掉，是把它的範圍縮小到只剩我們自己那條路。**
縮小之後那個決定會好做很多，因為它不再需要同時服務兩種信任模型。

---

## 六、風險

**政策風險（最高）。** TWDIW 現在沒有辦法分辨皮夾——**但這不表示以後不會**。
歐盟 ARF 走的是 wallet attestation。若 TWDIW 補上，第三方皮夾會在一夜之間
從「不需要許可」變成「需要許可」。
→ 因此排程上**要早做**，而且要把「我們用了什麼身分字串」集中在一處，方便將來換。

**資料風險。** TWDIW 駕照帶統一編號（§一.F）。把它放進我們的皮夾，
等於把一個**我們自己那條路刻意拿不到**的識別碼帶進裝置。
→ `LocalDataEraser` 必須一體涵蓋；出示預設全部關閉的規則對 TWDIW 卡一樣成立；
→ 而且卡片說明要直說「這張卡裡有你的身分證字號」。

**條款風險。** 沙盒帳號申請有服務條款。**要由使用者自己讀過再決定按不按同意**，
我不會代按。

**上游偏差的風險。** §一.H 那兩個偏差如果上游修了，我們的相容性 hack 會反過來壞掉。
→ 所以每一個 hack 都要有註解寫明「哪一天、為什麼、修好後拿掉」。

---

## 七、要回報給上游的四件事

做這件整合會順手產出四份可以回報的發現，這本身就是這個專案對生態系的貢獻：

1. **`client_id` 不具鑑別力**（§一.B）——憑證與持有它的皮夾之間沒有綁定。
2. **官方皮夾產生的 did:key 不符合 `jwk_jcs-pub` 的 JCS 要求**（§一.D）——
   嚴格實作的第三方會拒絕它。
3. **issuer metadata 的 `format` 與實際回傳格式不符**（§一.H.1）。
4. **VP token 用 `context` 而非 `@context`**（§一.H.2）——JSON-LD 處理會靜默丟掉主張。

第 2 與第 4 都屬於「簽章驗得過、語意卻是錯的」這一類，
是**最難被自己的測試抓到**的那種缺陷。

---

# 八、對正式環境的實測（2026-08-16）

全部是公開端點的 **GET**。沒有送出任何表單、沒有申請帳號、沒有按同意任何條款。
下面每個數字都是當天量到的，指令留在這一節裡可以重跑。

## A. issuer metadata：`format` 說謊不是個案，是全部

```bash
curl -s "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/.well-known/openid-credential-issuer"
```

    HTTP 200，701,000 bytes
    credential_configurations_supported：882 組
    format 分布            ：{'jwt_vc_json': 882}      ← 882/882
    binding 分布           ：{['jwk']: 882}
    signing alg 分布       ：{['ES256']: 882}
    整份文件裡 'sd-jwt' 出現：0 次
    整份文件裡 '_sd' 出現   ：0 次
    'selective' / 'disclosure'：0 次 / 0 次

§一.H.1 說 `format` 與實際回傳不符。實測比那個更絕對：**一個照規範讀 metadata 的
OID4VCI 客戶端，沒有任何欄位可以讓它知道這些憑證是 SD-JWT。** 不是某一組設錯，
是 882 組全部這樣，而且 701 KB 的文件裡連「sd-jwt」這個字串都不存在。

順帶量到一個營運面的數字：**metadata 是 701 KB**（沙盒環境，882 組設定）。
皮夾若在每次領卡都抓一次完整 metadata，那是 701 KB 的行動數據。
真正需要的只有其中一組。

駕照電子卡那組的欄位定義（六個欄位，全部 `"mandatory": true`）：

    name          姓名
    id_number     國民身分證統一編號
    roc_birthday  民國出生年月日
    type          駕照種類
    controlnumber 管轄編號
    gDate         發證日期

## B. 正式環境的信任清單一共 43 筆

```bash
curl -s "https://frontend.wallet.gov.tw/api/did?size=20&page=0&orgType=1&status=1"
```

    orgType=1  20 筆
    orgType=2  23 筆
    orgType=3  0 筆      orgType=4  0 筆
    合計       43 筆

⚠️ **`size` 參數會被夾在 20**。送 `size=100` 照樣只回 20 筆，而 `page=1` 之後就空了
——分頁邏輯與 `size` 不同步，一個照著 `size` 算 offset 的客戶端會漏資料。
本專案要一頁一頁抓到空為止，不要相信 `size`。

**43 筆全部裝得進 App**。這對 #26 有直接影響：TWDIW 那條路的信任清單
不是一個「太大只能線上查」的東西。

⚠️ **`orgGroupDetail.name` 不可以顯示給使用者看。**
43 筆**全部**標成「政府部門」，其中包括：

    全家便利商店股份有限公司      統一超商股份有限公司
    中華電信股份有限公司          台灣大哥大股份有限公司
    遠傳電信股份有限公司          龍獨斑股份有限公司
    這咖股份有限公司              壹一壹一科技股份有限公司   …

**一個把這個欄位畫在卡片上的皮夾，會告訴使用者全家便利商店是政府部門。**
`orgType` 1/2 看起來才是發行端/驗證端之分（公路局兩邊都有，超商只在 2，
而超商正是電信 VC「超商取貨」情境的驗證方）。

## C. 43 個發行者 DID：全部合規，全部驗得過

用本專案的 `JWKDIDKey` 同一套規則逐筆解，再用 WebCrypto 驗自簽章：

    multicodec 分布   ：{0xeb51: 43}       ← 全部 jwk_jcs-pub
    JWK 鍵序分布      ：{crv,kty,x,y: 43}  ← 全部 JCS 正規
    JCS 正規          ：43 / 43
    自簽章 ES256 驗過 ：43 / 43
    payload.id 與 id 不符：0
    header.jwk 與 DID 內嵌金鑰不符：0

**所以 §一.D 要縮小範圍：不合規的不是「TWDIW」，是官方皮夾產生 holder DID 的那段程式。**
發行者那一側，正式環境是乾淨的。

⚠️ **一個想做卻不該做的改動。** 量到 43/43 之後，我原本要把發行者 DID 改成
「強制正規化」——反正大家都合規，白拿一個完整性檢查。**這是錯的取捨**：

- 安全上拿不到東西。攻擊者用自己的金鑰，無論怎麼拼都不會正規化成受信任的那一個字串；
  非正規拼法造成的是**比對失敗**（false negative），不是誤放行。
- 代價卻是真的。moda 哪天加進第 44 個發行者、而它的 DID 剛好非正規，
  我們就會**整個機關拒收**——為了一個拿不到的安全性質。

現行設計（接受、但 `isCanonical` 可供診斷回報）是對的。
**這次量測確認了它，而不是要求改它。**

## D. 鏈上錨定：存的是完整文件，不是雜湊

```bash
curl -s -X POST https://arb1.arbitrum.io/rpc -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getTransactionByHash","params":["0x50f8e4e6…"]}'
```

數發部那一筆（Arbitrum One，合約 `0x84172caf8dd126c76f1fa8a2733ca3233264d31f`）：

    to 與 scAddress 相符：True
    block              ：409,114,230
    calldata           ：2,596 bytes   selector 0xf6e0d282
    完整 DID 字串在 calldata 裡  ：True
    完整的自簽 DID 文件 JWS 也在 ：True
    sha256(DID) 在 calldata 裡   ：False

**不是雜湊，是明文。** 這比「刻在石碑上」那句宣傳更強：
**皮夾可以完全不信任 `frontend.wallet.gov.tw`，直接從 Arbitrum 讀出信任清單並自行驗證。**

⚠️ 但 **41/43**。唯一沒有上鏈的是**中國醫藥大學**（發行端與驗證端各一筆）：

    x509_type            : XCA        （其他機關多為 GCA）
    issuerMetadataBaseURL: null       ← 登記為發行端卻沒有 metadata 位址
    onChainHistory       : []

對這兩筆，那份 API 是唯一的真相來源，而且其中一筆宣稱是發行端卻沒有可用的發行端位址。

## E. 撤銷清單：比我寫的更糟，而且要重寫那句話

```bash
curl -s "https://issuer-vc.wallet.gov.tw/api/status-list/00000000_demo_drivinglicense_202504251418/r0"
```

    header    ：{"jku":"https://issuer-vc.wallet.gov.tw/api/keys","kid":"key-2","typ":"JWT","alg":"ES256"}
    nbf       ：2026-08-15 18:00:00 UTC
    exp       ：2026-08-16 18:00:00 UTC
    有效期    ：86,400 秒 = 整整 24.0 小時
    bitstring ：76 字元（壓縮）→ 16,384 bytes = 131,072 bits
    已撤銷    ：84 個位元

§一.E 說「離線超過 24 小時撤銷狀態不可知」。**那句話太寬容。**

`nbf` 不是「你抓下來的時間」，是**這份清單上一次被簽的時間**。
2025-10-07 那份捕獲的 `nbf` 與憑證的 `nbf` 是同一秒（發卡時重簽），
今天這份落在每日 18:00 UTC（台北 02:00）。所以：

> **一份剛抓下來的撤銷清單，剩餘有效時間介於 24 小時與趨近於零之間，
> 取決於它上一次被簽是多久以前。**

一個在 17:59 UTC 抓到清單的皮夾，手上那份**六十秒後就過期**。
UI 要說的不是「24 小時內有效」，是清單自己帶的 `exp`。

好消息是它很小：壓縮後 76 字元、解壓 16 KB、容得下 131,072 張憑證。
**快取成本幾乎是零**，所以「常常抓」是可行的策略，問題只在離線那段。

## F. 這一輪還沒做的

- **領卡本身沒有跑。** 那需要在 demo 站填表產生 credential offer，
  而送出表單這件事要使用者決定。§三 M5.2 的「先送 `tw.bonds.backupTW` 量它會不會被拒」
  仍然待做，是整個 M5 唯一需要別人點頭的一步。
- 沒有碰 UAT 環境（`frontend-uat`、`issuer-sandbox`），那些要帳號。

---

# 九、金鑰從哪裡來：一個追到底的問題，包含我一度過度警報的部分

實測撞出來的。做 M5.3 要決定「驗發行者簽章的公鑰從哪裡拿」，而 TWDIW 的
JWS header 同時給了兩個來源，它們**可以不一致**：

    header: {"jku":"https://issuer-vc.wallet.gov.tw/api/keys","kid":"key-1|key-2",
             "typ":"vc+sd-jwt","alg":"ES256"}
    payload: {"iss":"did:key:z2dmzD81…"}   ← 這個 DID 本身就內嵌一把公鑰

`jku` 是 JWT 的經典風險：讓被驗的文件自己指定去哪裡拿驗它的金鑰。

## A. 實測：撤銷清單用的是一把**不在 DID 裡**的金鑰

拿剛抓下來的那份 status list JWT，用兩個來源各驗一次：

    iss 這個 did:key 內嵌的金鑰   →  ❌ 驗不過
    jku 指的那組金鑰裡的 key-2    →  ✅ 驗過

`GET https://issuer-vc.wallet.gov.tw/api/keys` 回兩把：

    key-1  x=dnQ2W9ZTsILYac3XdcvxrYNgIgjSkGJUMecMXVJk7XM   ← 與 iss DID 內嵌的**相同**
    key-2  x=9CNEmxkQimYxZtsoLuHyu2w_dHrVWrXapZzpYE0qm78   ← DID 裡**沒有這一把**

而 DID 文件只有**一個** `verificationMethod`（我解過數發部那份，
`{id, verificationMethod, @context}`，一把金鑰）。

**所以：憑證由 key-1 簽，撤銷清單由 key-2 簽，而只有 key-1 在 DID 裡。**

## B. 我一度警報過頭，這裡是更正

看到官方驗證端對 `jku` 的檢查只有「非空字串」：

```java
if (jku != null && !jku.isBlank()) { LOGGER.info("[check vc jku]: PASS"); }
```

以及三個載入器全部 `setAllowedHostnames(null)`（發行者公鑰、撤銷清單、schema），
我當下的結論是「教科書等級的 jku 漏洞」。**那個結論是錯的**，把 orchestration 讀完才看清楚：

```java
// FutureTaskService.getIssuerPublicKey(issuer, jku, kid)
try {
    return DidUtils.extractIssuerPublicKey(issuer);      // ← 主要來源：iss 的 did:key
} catch (VpException e) {
    return resourceLoadService.loadIssuerPublicKey(jku, kid);  // ← 只在上面丟例外時才走
}
```

**主要來源是 `iss` 的 did:key，`jku` 只是 fallback。** 而且 `validateVC` 的
step 4 會平行跑 `validateDidStatus(iss)`，拿 `iss` 去查信任清單。

要讓 fallback 被走到，`extractIssuerPublicKey` 必須丟例外——條件全部是
「`iss` 不是一個格式正確的 jwk_jcs-pub did:key」。但**任何能通過信任清單的 `iss`
都必然是格式正確的**（§八.C 量到 43/43 全部合規）。
兩個條件互斥，所以**對憑證而言那條 fallback 實務上是死路**。

寫下來是因為：一個只讀 `ResourceLoadService` 就下結論的人（也就是十分鐘前的我）
會發出一個站不住腳的安全指控。**證據鏈要讀到 orchestration 才算讀完。**

## C. 但撤銷那條路上，情況不一樣，而且這才是真的發現

對憑證來說 `jku` 是死路，因為 DID 裡有那把金鑰。
**對撤銷清單來說 DID 裡沒有那把金鑰**（§九.A），所以 `jku` 不是 fallback，
是**唯一的路**。於是：

> **憑證這條路的信任錨點是公告的、上了 Arbitrum 的、可以離線驗的。
> 撤銷那條路沒有。** 簽撤銷清單的 key-2 不在任何 DID 文件裡、不在信任清單裡、
> 不在任何鏈上紀錄裡——它只存在於一個 URL。

實務後果，對我們這個離線優先的皮夾特別直接：

1. **查一張 TWDIW 憑證有沒有被撤銷，要連線到兩個端點**：撤銷清單本身，
   以及它 header 裡 `jku` 指的那組金鑰。而後者的信任基礎只有 TLS。
2. **離線時我們無法驗證撤銷清單的簽章**，即使清單本身被快取起來也一樣
   ——除非額外把 key-2 也快取，而那把金鑰沒有任何公告管道可以讓我們確認它是對的。
3. 這跟我們自己那條路是強烈的對比：MOICA 的撤銷走 SMT 快照，
   錨點是鏈上的 root，**離線可驗**（雖然 root 錨定檢查本身還沒實作，碼裡誠實標著）。

## D. 由此定下 M5.3 的兩個設計決定

**一、發行者公鑰一律從 `iss` 的 did:key 取，永不跟隨 `jku`。**
不是保守，是量過的：正式環境 43/43 發行者 DID 都內嵌了可用的金鑰，
所以跟隨 `jku` 拿不到任何我們拿不到的東西，只會多一個由被驗文件指定的網路來源。
`jku` 與 `kid` 照樣解析出來**存起來當診斷資訊**，因為「這張憑證宣稱去哪裡拿金鑰」
是回報上游與事後追查時要看的東西——但它不參與判定。

**二、撤銷狀態在離線時一律回報「未檢查」，不回報「未撤銷」。**
本專案已經有這個型別（`RevocationLookup.unavailable` 回報「沒有檢查過」而不是「通過」）。
TWDIW 卡沿用它，而卡片上的 caveat 要寫的不是「24 小時後過期」，是更準的那句：

> 這張卡有沒有被撤銷，只有連上網才知道；而且驗證那份撤銷清單所需要的金鑰，
> 不在任何公告的信任清單裡。

---

# 十、對抗式查證的結果（2026-08-16，九個獨立審查）

三項主張各自交給以「**反駁它**」為預設立場的審查，`client_id` 那條因為是要回報給
政府單位的安全性主張，用三個互不相同的視角各查一次。另外三份是實作面的勘查，
最後一份是完整性審查。以下只記與原文不同、或原文沒有的。

## A. 一項主張被推翻——是我的因果機制錯了

**C5：「VP token 用 `context` 而非 `@context`」。**

- **拼字錯誤是真的**，而且比我寫的更全面：`openid_vc_vp.dart` 裡三個產生 VP 的
  函式（`generateVPKx`、`generateVPNFC`、`transferVC`）**全部**寫 `'context'`。
  全 repo 搜那個 `@context` 的 URL 只出現在這三處——**系統裡沒有任何一條產生 VP
  的路徑寫對。**
- **但我加粗的那句因果是錯的。** 我寫「JSON-LD 處理會把整個 VP 的主張丟掉」，
  而 TWDIW 的驗證端**根本沒有做 JSON-LD 展開**，所以實際上沒有東西被丟掉。
  我把 M1 咬過我們的那個 bug 的機制，套到一個形狀相似但管線不同的地方。

正確的說法是：**這是一個會讓任何做 JSON-LD 展開的第三方驗證端整份讀不到主張的
互通性缺陷，而不是一個目前正在造成靜默資料遺失的缺陷。** 值得回報，但不能用
我原本那個描述回報。

## B. `client_id` 那條沒有被推翻，而且比原文更糟

三個視角（找註冊表／找 attestation／重讀 ID Token 那一段）都回報 refuted=false、
confidence=high。額外挖到三件原文沒有的：

1. **ID Token 的簽章根本沒被驗。** `CredentialIssuer.java:209` 取出 `IDT_sig`
   之後全檔再未使用。所以連「從發行端出發、繞一圈回到發行端」的那一圈，
   都不是靠簽章閉合的。
2. **`AccessTokenFilter` 的驗證邏輯整段被註解掉**，程式碼裡留著
   「尚未啟用 AccessToken 驗證，先讓請求繼續」。而 `SecurityConfiguration:77`
   把 `/api/**` 設成 `permitAll`。
3. **49 張資料表裡沒有任何 client／wallet／app／device 註冊表。** `client_id`
   只以欄位形態出現在 `pre_auth_code` 與 `credential_access_token`，值由發行端
   自己寫入。全 repo 無 `client_secret`／`client_assertion`／mTLS／Play Integrity／
   App Attest／DeviceCheck。

⚠️ **一處措辭要收緊。** 「任何第三方皮夾送 `client_id=moda_dw` 都與官方 App
無法區分」在**身分鑑別**這一層完全成立，但不等於任何人都能領到憑證——
領卡真正的門檻是 **pre-authorized code（QR 的內容）與可選的 `tx_code`**。
可以送出去的那句話是：

> **拿得到那張 QR 的人，用任何自製皮夾都能走完全程；官方 App 沒有任何
> 密碼學上或註冊上的特權。**

## C. 三件原本不知道的上游缺陷，其中一件比我原本列的四件都嚴重

**一、四個對外抓取全部關閉 TLS 主機名驗證。**
`ResourceLoadService` 的四個抓取（發行者公鑰、撤銷清單、schema、frontend DID 查詢）
都是 `setAllowedHostnames(null)`，而 `HttpUtils` 的 `HostnameVerifier` 是：

```java
if (allowedHostnames != null && !allowedHostnames.isEmpty()) {
    isVerified = allowedHostnames.contains(hostname);
} else {
    // directly pass when allowed hostname list is NOT set
    isVerified = true;
}
```

傳 `null` **不是**「不設允許清單、走系統預設驗證」，是**自訂 verifier 恆回 true**
——等於把 TLS 憑證與主機名的繫結整個拆掉。這四條連線收任何憑證。
RFC 8725（JWT BCP）§3.8 明文要求 `jku` 必須限制在受信任 URL 的允許清單。

**二、撤銷清單那條路在發行者簽章驗證完成前就發出請求。**
`PresentationServiceAsync.validateVC()` 的六個步驟是**同時起飛**的
`CompletableFuture`——step 3 抓撤銷清單、step 5 抓 schema，而發行者簽章要到
step 6 才驗。那兩個 URL 取自**尚未驗簽的** JWT payload。
所以任何能對驗證端 POST 一份 VP 的人，都能讓它去 GET 任意 URL（SSRF），
再配上第一條的主機名驗證恆真。

而且 `StatusListCheckTask` **沒有** `DidUtils.extractIssuerPublicKey` 的優先嘗試
——它直接 `loadIssuerPublicKey(jku, kid)`。這獨立確認了 §九.C：
**撤銷是 `jku` 這個模式在正式環境真正活著的那個實例，而它是自我指涉的
——清單自己說用哪把鑰匙驗自己。**

**三、官方皮夾的選擇性揭露會多送欄位。**
`utils.dart` 的 `sdJwtEncode` 決定保留哪些揭露的方法是**對解碼後整段 JSON
做子字串比對**：

```dart
String decoded = utf8.decode(base64.decode(base64Url));   // ["鹽","欄位名","值"]
for (var field in fields) { if (decoded.contains(field)) { result += part + '~'; continue; } }
```

`decoded` 包含鹽與值。所以駕照的 `id_number` 與 `controlnumber` **都含子字串
`number`**；值裡若出現另一個欄位名也會誤中；隨機鹽理論上也可能命中。
另外那個 `continue` 作用在內層迴圈，一個揭露同時命中兩個 field 會被**附加兩次**。

> **使用者勾選「只揭露 A」，實際可能送出 A 與 B。**
> 這是選擇性揭露這個功能的核心承諾被破壞，**比前面幾條更貼近使用者**。

（附帶：皮夾 SDK 的 `sdJwtDecode` 在三元素揭露那條分支——也就是 TWDIW 六個欄位
實際走的那條——**完全不驗摘要**，直接把值填進顯示結果。）

## D. 兩個必須在寫 M5.2 第一行程式之前決定的事

完整性審查標為 blocking 的兩條，我同意，而且它們改變 M5.2 的設計。

**一、credential offer 來自一張 QR，而流程裡沒有任何「這個發行者是誰」的檢查。**
M5.2 的第 1、3、4 步的 URL 全部來自那張 QR，而第 4 步會用持有人金鑰簽一個
proof JWT，`aud` 直接填對方給的值。**任何人印一張 QR，就能讓皮夾對他指定的
URL 產生一個由裝置長期金鑰簽出來的、內容由他選的 JWT。**

本專案對這類輸入已經有立場，寫在 `MOICACallbackRouter` 的檔頭：
inbound URL 是 untrusted input，只能當「再去查一次」的訊號，不能當結果。
同一條規則要套到 credential offer 上——而 §八.B 那 43 筆信任清單正好是
可以拿來比對 issuer DID 的東西（目前文件只把它用在驗發行者簽章，
沒用在「要不要連過去」）。

**二、TWDIW 領卡要用哪一把持有人金鑰——沿用現有那把會直接破壞不可連結。**
`VerifiablePresentation.create()` 交給查驗方的 holder DID，就是 `DeviceKey`
那把唯一的長期金鑰導出的。若領卡的 proof JWT 也用它：

> TWDIW 憑證的 `cnf.jwk` 會被寫進政府發行端的資料庫，
> 而**那串位元組正是任何一個離線查驗方看到的識別碼**。

我們刻意讓自然人憑證那條路拿不到統一編號（§一.F），
結果從另一扇門交出一個更好用的索引。而且**這條汙染不需要任何人上網才生效**
——離線出示的那張卡上就帶著這個公鑰，事後才對得上。

→ **至少一卡一金鑰。** 而一旦有第二把，`IdentityReset` 只吃單一 `keyTag`
就不夠用了——「重設身分」會漏掉 TWDIW 那幾把，殘留的金鑰正是使用者
以為已經丟掉的那個索引。

## E. 我被指出的證據弱點，逐一處理

完整性審查列了八條「證據不足卻被當成結論」。誠實處理：

| 指出的弱點 | 處理 |
|---|---|
| **「43 筆」是用我自己證明壞掉的分頁 API 數的**，20 恰好是 clamp 邊界 | **已補測，數字站得住。** 用 `size=20` 與 `size=5` 兩種頁大小各自逐頁列舉到空頁，都得到 20 與 23，且 id 全部不重複。`size=100` 那個異常是「頁大小被夾在 20、但 offset 照送出的 size 算」，是 API 缺陷，不影響逐頁列舉的總數。 |
| 「可以完全不信任 frontend.wallet.gov.tw」只驗了一筆交易，且 tx hash 來自 API | **接受，措辭要降級。** 目前證明的是「已知一筆交易，內容是明文而非雜湊」。要成為可用的無信任路徑，需要示範「只給合約位址就能列舉全部 43 筆」——沒有做。 |
| 「41/43 上鏈」用的是 API 自報的 `onChainHistory` | **接受，是循環的。** 中國醫藥大學那兩筆是「API 說沒有」，不是「鏈上找過沒有」。 |
| 非正規 holder DID 是 n=1、來源二手、未標 App 版本 | **接受。** 寬容解析這個決定獨立成立（§八.C），但把它列為要回報上游的第 2 件事，舉證責任是不同等級的，回報前要補樣本與版本。 |
| §〇「第三方皮夾今天就走得通」比證據強一級 | **接受。** 領卡從來沒有真的跑過，整條推論來自讀原始碼；也無法排除正式部署在網路層另有管制。§八.F 已自承，但 §〇 的措辭沒有跟上。 |
| 駕照六個欄位「都是字串」是單一 demo 卡的觀察，卻是 adapter 能不能用的前提 | **接受，而且失敗形態很差**：`SelectiveDisclosure` 對非三元素、非全字串的揭露是**拒整張卡**，所以一張真卡會被判成壞卡。882 組設定裡的電信、超商取貨卡完全可能帶非字串值。要決定：遇到不認得的揭露形狀，是拒收整張卡，還是收下並標記「有欄位無法顯示」。 |
| 「每日 18:00 UTC 重簽」是 n=2 | **接受。** 由它導出的「剩餘效期介於 24 小時與趨近於零」在邏輯上仍穩（只需要 `exp` 是絕對時間），但預抓排程不要依賴那個時刻。 |
| §一.B 的措辭會讓讀者以為誰都能領卡 | **已於 §十.B 收緊。** |

## F. 要回報上游的清單，從四件變成七件

依「使用者受害程度」排，不是依技術嚴重度：

1. **選擇性揭露會多送欄位**（§十.C 三）——勾選只揭露 A，實際可能送出 A 與 B。
2. **四個對外抓取關閉 TLS 主機名驗證**（§十.C 一）。
3. **撤銷／schema 在發行者簽章驗證前就被抓取**（§十.C 二），構成 SSRF。
4. `client_id` 不具鑑別力，且 ID Token 簽章未驗、AccessTokenFilter 被註解掉（§十.B）。
5. issuer metadata 的 `format` 與實際回傳不符（882/882，§八.A）。
6. VP 用 `context` 而非 `@context`（§十.A，**用修正後的描述**）。
7. 官方皮夾產生的 did:key 不符 JCS（§一.D，**回報前要補樣本與版本**）。

另外還有一件屬於設計層而非缺陷層的：**發行者身分是 `did:key`，金鑰即身分，
所以輪替簽章金鑰等於變成另一個 DID**，而所有已發出憑證的 `iss` 會從此不在
信任清單裡。皮夾將無法區分「這個發行者被撤下了」與「它換了金鑰、舊卡其實還是真的」。
**這是唯一一件會讓已經在使用者手上的卡集體變成無法評估的事。**

---

# 十一、一卡一金鑰的設計，以及我自己說錯的那一句

八份獨立設計與審查。**隱私審查推翻的是我在上一節寫的話**，所以先講那個。

## A. 我說錯的：一卡一金鑰**不會**切斷發行端與查驗端的關聯

§十.D 我寫：沿用單一裝置金鑰，「TWDIW 憑證的 `cnf.jwk` 會被寫進政府發行端的
資料庫，而那串位元組正是任何離線查驗方看到的識別碼」。

那句話對**現況**是正確的，但它暗示了一個錯的結論——好像換成一卡一金鑰就解決了。
沒有：

> **`cnf.jwk` 由發行端在領卡當下決定並存進資料庫，終身不可換。
> 同一張 TWDIW 卡，發行端看到的那把公鑰，就是每一個查驗方看到的那把。
> 一卡一金鑰完全沒有動到這件事。**

一卡一金鑰真正切斷的只有一件事：**不同卡之間**。A 卡的查驗方與 B 卡的查驗方
無法從金鑰看出是同一個人。而「這張卡的發行端與這張卡的所有查驗方」——
以及「同一張卡出示很多次」——照樣可連結，而且是協定性質，改架構解不掉。

所以卡面上的 caveat 不可以寫成「這張卡與你其他的卡不可連結」。要寫的是：

> 這張卡不會透過金鑰洩漏你持有其他卡；
> 但它揭露的姓名與身分證字號，會讓看過你其他證件的人認出你。

⚠️ 而且**內容層的關聯壓過金鑰層**：TWDIW 駕照帶姓名＋統一編號，
自發行卡出示時夾帶的 MOICA 憑證 CN 裡也是同一個姓名（§一.C 說過那是結構性的），
ZK 路徑的 nullifier 從自然人憑證導出、跟裝置金鑰無關。
**兩張卡出示給同一個查驗方，姓名在金鑰之前就把它們接起來了。**
一卡一金鑰是必要的，但把它講成「消除跨卡關聯」會讓後面的人以為這件事做完了。

## B. 拍板的設計

**一、per-credential 的 keyTag 是不透明隨機 handle。**
`tw.bonds.backupTW.key.<installID>.<32 hex>`。卡別、發行者、憑證 id 一律不得進入。
理由跟 `CredentialStore` 檔名是 hex 不是加密同一條：`kSecAttrApplicationTag`
是明文 metadata。一個叫 `…key.twdiw.00000000_demo_drivinglicense_…` 的 tag，
等於在 Keychain 裡宣告「這支手機的主人有一張政府駕照電子卡」。
（雜湊憑證 id 也不行——卡別的取值空間是 882 組公開字串，字典攻擊一秒跑完。）

**二、既有的自發行金鑰完全不遷移。** legacy tag 原封保留，新卡才走新命名空間。
Keychain 沒有 rename，改 tag 等於刪了重建，而重建就是換金鑰——那張卡已經發出去、
已經被出示過，換 DID 會讓查驗方手上的紀錄對不起來。

**三、出示用哪一把金鑰，不存對應表，由憑證裡的公鑰反查。**
憑證本身就是那份對應表（TWDIW 的 `cnf.jwk`、自發行卡的 `credentialSubject.id`）。
再存一份 id→tag 的側表就是第二個真相來源，會漂移，而漂移的表現是簽出一個
查驗方會拒收的東西。側表本身也會是一份「哪張卡對哪把鑰匙」的清冊。

**四、`IdentityReset` 向 Keychain 列舉，不維護「我們記得建了哪些」的清單。**
清單漏一把，那把就永遠刪不掉，而使用者以為已經丟掉——這正是 M1 那個
「身分活得比抹除久」。列舉的真相來源是 Keychain 自己。

## C. 三件在寫第一行程式之前必須先解決的

**一、⚠️ 整套列舉的地基是一條沒有量過的假設。**
「`SecItemCopyMatching` + `kSecMatchLimitAll` 看得見 Secure Enclave 金鑰，
且 attributes 帶得回 tag 與 `kSecAttrCreationDate`」——現行程式從來沒做過這種查詢
（`DeviceKey.loadPrivateKey` 一律是 `kSecMatchLimitOne` 加 tag 等值比對）。
token-backed item 的 attribute 集合與一般 item 不同是已知的坑，
而**漏看一把的後果是靜默的**：掃描刪 0 把、再列舉為空、驗證通過、
使用者被告知已清除。

> 本專案的規矩是先量再決定。**閘門：在真機上建一把 SE 金鑰與一把 software
> fallback 金鑰，各自量列舉看不看得到、tag 與建立時間回不回得來。量完再寫。**

**二、裝置鎖定時的半殘狀態還沒關掉。**
`IdentityReset.perform` 目前是「金鑰步驟失敗仍無條件刪憑證」。
所有金鑰是 `WhenUnlockedThisDeviceOnly`，鎖定時列舉直接看不到；
而憑證檔案是 `.completeUnlessOpen`，鎖定時仍刪得掉。
於是鎖定時的真實結果是**檔案沒了、金鑰活著**——正是 `IdentityReset` 檔頭
列為否決的那個順序。而且 liveness 探針放在掃描**之前**，掃到一半螢幕上鎖
一樣中招。

**三、殘留的定義會把 App 自己的產物算成殘留。**
`…selfcheck.` 與 `…tests.` 兩段依定義都「不符正式前綴」，
而 SelfCheck 每跑一次就建探針金鑰、任何中斷都會留下。
結果是一個**使用者無法自行修復、而且是診斷功能自己製造的永久紅燈**
——正是「一個永遠失敗的東西會訓練使用者忽略它」那條理由被搬到隔壁畫面。

## D. 先做的不是金鑰，是卡片層（已完成）

完整性審查的排序結論：**不要先寫 `HolderKeyring` 的任何一行。**
先在 `CredentialStore` 之上長出「這是哪一種卡」，因為那已經是一個活著的缺陷：

`HolderPresentation.storedCredentialID()` 是 `store.allIDs().first`。
自發行卡的 id 是 `national-id`，TWDIW 的識別碼以數字開頭，數字排在字母前面。
**第一張 TWDIW 卡存進來的那一刻，「出示證件」會靜默改指它**，
而這條路是拿本專案自己的格式建 `VerifiablePresentation` 的。

已於 2026-08-16 修掉（`StoredCardSource`，1,073 測試通過），
連帶修掉 `DiagnosticsViewController` 那個存在很久的自相矛盾：
函式上方註解寫「觀測；絕不建立」，函式裡呼叫的是 `loadOrCreate()`。

---

# 十二、實機量測：一卡一金鑰的紅線清掉了（2026-08-16）

§十一.C 把整個 `HolderKeyring` 擋在一條沒量過的假設前面。量完了，
iPhone 14（實體，非模擬器）：

```
環境：實機
SecItemCopyMatching(kSecMatchLimitAll) → OSStatus 0，共 3 個 item
  · tag=…measurement.software  backing=keychain        cdat=2026-08-16 08:07:49  tokenID=nil
  · tag=…measurement.enclave   backing=SecureEnclave   cdat=2026-08-16 08:07:49  tokenID=com.apple.setoken

一、列舉看得到 software 金鑰嗎？          → 看得到
二、列舉看得到 Secure Enclave 金鑰嗎？    → 看得到
三、attributes 帶得回 tag 嗎？             → 全部帶得回
四、attributes 帶得回 kSecAttrCreationDate？→ 全部帶得回
五、用 kSecValueRef 刪得掉嗎？             → 刪掉 2 把，掃完剩 0 把
```

五題全部是好消息，所以 §十一.B 那四個設計決定全部成立：

- **列舉可以當真相來源**，不必維護一份會漂移的清單。
- **`kSecAttrCreationDate` 回得來**，所以 `reapUnclaimed` 用建立時間當護欄
  （避免刪掉領卡流程中途正在用的那把）是可行的，不必處理「拿不到日期怎麼辦」
  那個兩邊都很難看的分支。
- **`kSecValueRef` 刪得掉 Secure Enclave 金鑰**，不必退回 tag 等值比對。

⚠️ **模擬器不能拿來回答這一題。** 同一支測試在模擬器上跑，五題也全部「通過」
——包括第二題，因為模擬器會回報 `com.apple.setoken` 而那裡根本沒有 SEP。
測試裡因此有一支 `aSimulatorRunDoesNotAnswerTheSecureEnclaveQuestion`，
在模擬器上印出警告，免得一次綠燈被當成答案。

順帶一個對照：實機上這個 App 總共只有 **3 把** EC 金鑰（其中 2 把是這次量測建的），
模擬器上是 6 把。實機那多出來的一把就是既有的裝置金鑰——數字對得上。

**還沒解決的仍然是 §十一.C 的第二與第三條**（裝置鎖定時的半殘狀態、
殘留定義會把自家探針算成殘留）。那兩條不是量測問題，是設計問題。
