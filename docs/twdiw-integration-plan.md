# 把台灣數位憑證皮夾（TWDIW）整合進來：完整規劃

2026-08-16。回答「做一個第三方皮夾 App，讓官方認證的發行者、驗證者都能跑完整流程，
皮夾裡除了我們自己的『身分證』還有電子卡、數位駕照，藉此證明**最理想的皮夾長什麼樣子**」。

一手來源：<https://docs.denkeni.org/twdiw>（denkeni 的 TWDIW: The Missing Manual
與其 Related Personal Notes）、官方開源專案 `moda-gov-tw/TWDIW-official-app`（MIT）。
本文所有數字與行號都是我自己抓下來對過的，不是引述。

---

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

    name           陳籍玲
    id_number      A2345678901
    roc_birthday   0570605      ← 民國 57-06-05 = 1968-06-05
    type           普通小型車
    controlnumber  40104020914 45
    gDate          1020701

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
