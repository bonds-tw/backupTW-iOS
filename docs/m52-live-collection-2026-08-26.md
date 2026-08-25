# M5.2 領卡實測（2026-08-26，demo.wallet.gov.tw）

承 `twdiw-integration-plan.md` §三 M5.2 與 §八.F「領卡本身沒有跑」。這一份是把它跑起來的紀錄。
全部針對 `demo.wallet.gov.tw` 的訪客領卡（不需帳號、不碰 UAT），填的是測試 persona 王小明、A123456789，
非任何真人資料。

## 〇、一句話

**皮夾端（`backupTW` 的 collector）完整實作並運作——閘門、URLSession 過 Cloudflare、fetch offer、
token 請求格式全對，App 實機跑到 token 步驟拿到 issuer 的真實業務回應；領卡最終卡在 demo/sandbox
環境的一個結構問題：offer-object 端點回的 `pre-authorized_code` 在 token 端查不到（HTTP 400
`resp_code 11007`）。已排除 TTL——curl 毫秒級連續 GET→token 同樣 not found。因此 client_id
是不是回音的最終判定還沒拿到，它被擋在 pre-auth code 驗證之前的一步。**

## 〇.5、App 端決定性量測（2026-08-26 02:23，實機路徑）

把 DEBUG 版 App 裝進模擬器，用 `openid-credential-offer://?credential_offer_uri=<真實 offer_uri>`
餵給它，讓它當**唯一** dereference offer 的角色（等同官方 App 掃 QR 那一下）。結果 alert：

    領取數位皮夾卡片
    badStatus(step: OID4VCICollectionError.Step.token, code: 400)

這一個畫面同時證明了三件事，逐一拆開：

1. **閘門過了。** issuer host `issuer-oid4vci.wallet.gov.tw` 經 DEBUG-only 的 `TWDIWIssuer.sandboxDemo`
   放行，gate 1 與 gate 2 都通過，才走得到 token。
2. **App 的 `URLSession` 過了 Cloudflare。** 若被 1010 擋，錯誤會是 network/403 而非 issuer 的
   `code: 400`。這回頭證實 §四 的推論：原生 URLSession 的 UA 指紋不被 Cloudflare 擋，curl 要偽裝、
   瀏覽器被 CORS 擋，只有 App 這條路天生通。
3. **collector 的請求格式對。** issuer 收下了 token 請求並回以業務層錯誤（pre-auth code），
   而不是 4xx 格式錯誤，代表 form 欄位、grant_type、authorization_details 都被接受。

**副產品：閘門在 App 端真實攔截了 prefix 攻擊 host。** 同一輪測試中，稍早一個
`issuer-sandbox.wallet.gov.tw.evil.tw` 的 offer 被 App 以
`refused(...notOnTheTrustList(host:))` 擋下，零請求出門——host 全等比對擋住了「合法前綴＋惡意後綴」。

## 一、demo 訪客領卡跑通了（到 offer 為止）

`demo.wallet.gov.tw/getcard` 是一張表單。選卡別、填欄位、按「提交卡片資料」，
右側就長出一個 QR 與「開啟數位憑證皮夾」按鈕，狀態列說「卡片已產生，並已建立數位憑證」。

「開啟數位憑證皮夾」的 href 是：

    https://frontend-uat.wallet.gov.tw/api/moda/vcqrcode?mode=vc01&deeplink=<base64url>

`deeplink` 解出來是**官方 App 的自訂 scheme**，不是 OID4VCI 標準的 `openid-credential-offer://`：

    modadigitalwallet://credential_offer?
      credential_offer_uri=https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000
        /credential-offer-object?nonce=<uuid>&sub=<64 hex>

`sub` 每次提交都一樣（`4f1e21bf…1264`，64 hex＝32 bytes，像是填入資料的雜湊）；`nonce` 每次不同。

## 二、offer 的真實結構——與我們的 parser 吻合

`GET credential-offer-object?nonce=…&sub=…`（帶 iOS UA，見 §四）回：

```json
{"grants":{"urn:ietf:params:oauth:grant-type:pre-authorized_code":
  {"pre-authorized_code":"ZMMZncv1kmr-L6UWe7vDKvuhFeCjDjTeauEOCCILPAs"}},
 "credential_configuration_ids":["00000000_demo_drivinglicense_202504251418"],
 "credential_issuer":"https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/"}
```

- `credential_issuer` **結尾帶斜線**——這正是 `OID4VCICollection.proofJWT` 為 `aud` 補斜線的來源，量到了證實。
- 三個欄位（grants / configuration_ids / credential_issuer）與 `CredentialOffer.parse` 一一對上，**不用改 parser**。

## 三、offer-object 是一次性的

同一個 `nonce` GET 第二次，回應裡就**沒有 `grants` 了**。這對安全模型是好消息——一張 QR 的 offer
不能被重放領第二次——但也意味著：**唯一該 dereference 這個 offer_uri 的角色是皮夾 App**（掃 QR 那一下），
任何在 App 之前先 GET 過它的工具都會把那一次性的機會用掉。

## 四、Cloudflare 用 User-Agent 擋，iOS 的 URLSession 會過

`issuer-oid4vci.wallet.gov.tw` 前面有 Cloudflare。
- `curl` / Python `urllib` 預設 UA → `POST /token` 回 **HTTP 403 `error code: 1010`**（Cloudflare 瀏覽器指紋封鎖），
  根本到不了 issuer。
- 換成 `User-Agent: backupTW/1.0 CFNetwork/1568 Darwin/24.0.0` → 1010 消失，拿到的是 issuer 的**業務回應**。
- 從 `demo.wallet.gov.tw` 頁面 `fetch()` 跨源到 issuer → `TypeError: Failed to fetch`（無 CORS header，API 是給原生 App 的）。

**結論：這條路只有原生 App 的 `URLSession` 走得通**——curl 要靠偽裝 UA、瀏覽器被 CORS 擋。
官方 App 能領卡正是因為它是 URLSession。這也回頭確認 `backupTW` 的 collector 是對的載體。

## 五、token 卡在 pre-authorized_code

帶正確 UA、拿剛 GET 到的 code 立刻 `POST /token`，回：

    HTTP 400 {"resp_message":"Pre-authorized_code not found","resp_code":11007,"error":"invalid_grant"}

**已排除 TTL 與「別人先消耗」兩個假設**：
- **TTL**：curl 在同一行、毫秒級連續 GET→token（`nonce=d74c8e2a`），一樣 not found。不是過期。
- **別人先消耗**：App 端當唯一 dereferencer（§〇.5）同樣 400。offer 一次性沒有被別人搶。

剩下的機制指向**結構問題**，最可能的一個：**offer 與 token 分屬不同環境/儲存**。
demo 顯示 QR 用的是 `frontend-uat.wallet.gov.tw/api/moda/vcqrcode?deeplink=…`，deeplink 裡的
offer_uri 卻指向 `issuer-oid4vci.wallet.gov.tw`。若 code 實際登記在 UAT 那邊，而 token 打的是
production-ish 的 issuer-oid4vci 實例，token 端自然查不到。另一個可能是 offer-object 是「預覽」端點，
真正登記 code 的動作發生在官方 App 掃 QR 後某個未觀察到的呼叫。兩者都需要 UAT 帳號或官方文件才能定論。

**因此 M5.2 的核心問題「送 `tw.bonds.backupTW` 會不會被 token 端收下」目前仍無法回答**：流程在 client_id
被鑑別之前就停在 pre-auth code not found。但已經確定**這不是皮夾端的 bug**——collector 走完了整條鏈，
拿到的是 issuer 對這條 demo 路徑的伺服器端限制。下一步是拿 UAT 帳號走 `frontend-uat` / `issuer-sandbox`
完整流程，或用 mitmproxy 觀察官方 App 掃這張 QR 時多打了哪個登記端點。

## 六、電信卡與超商取貨——目標路徑的實測

使用者的目標：官方皮夾收得到電信卡，且電信卡可做超商取貨。實測：

- issuer metadata（`issuer-oid4vci.wallet.gov.tw/api/issuer/00000000`，883 組設定）裡**存在**這三張：
  - `00000000_universal_telecom_card`「萬用電信卡」— `credentialSubject.phone`（手機號碼）
  - `00000000_convenience_store`「便利商店取貨卡」— `name`（姓名）＋ `Phone_number_last3`（手機末三碼）
  - `00000000_demo_drivinglicense_202504251418`「駕照電子卡」— 六欄（前已驗）
- **但 demo `/getcard` 訪客領卡下拉只有 5 種**：訪客電子卡、駕照電子卡、114年所得資料卡、學生證、
  陽明交通大學畢業證書。**電信卡與超商取貨卡不在訪客可無條件領取之列**——它們要走官方 App 的真實門號 / 帳號驗證。
- **超商取貨的核銷機制因此清楚了**：便利商店取貨卡出示 `name` ＋ `Phone_number_last3`，
  就是超商櫃檯比對取貨人的兩個欄位。`Phone_number_last3` 這個欄名大小寫混合（非全小寫），
  值的型別待領到真卡才能確認——若非字串，會踩到 `twdiw-integration-plan.md` §八 記的
  「`SelectiveDisclosure` 對非字串揭露拒整張卡」那個坑。

## 七、demo issuer 不在 production 信任清單

`issuer-oid4vci.wallet.gov.tw` **不在** `frontend.wallet.gov.tw/api/did` 那 43 筆裡
（那些是 `<taxId>.wallet.gov.tw`、`moda.wallet.gov.tw`、`dcert.wallet.gov.tw`、`chtmecard.wallet.gov.tw` 等）。
所以 `IssuerAuthorization` 用 production 清單當閘門時，**會正確地拒絕 demo 領卡**。

這是真實的張力，不是 bug：demo/sandbox 自成一個信任域。要在 App 裡跑 demo 領卡，需要一個
**明確標記、與 production 閘門分離的 demo 模式**把 sandbox issuer host 列入允許，而不是弱化 production 那條路。

## 八、對 backupTW 的待辦（由本次實測產生）

1. **收 `modadigitalwallet://` 的 offer**（QR / 貼上入口）——但**不註冊**這個 scheme（會與官方 App 搶 deep link）。
   標準 `openid-credential-offer://` 仍是我們註冊的 scheme；`modadigitalwallet://` 只在解析層理解。
2. **demo/sandbox 信任模式**：DEBUG-only 把 `issuer-oid4vci.wallet.gov.tw` 列入閘門允許，
   讓 App 能當唯一 dereference offer 的角色跑完 token → credential，取得 client_id 的最終量測。
3. `Phone_number_last3` 的非字串揭露處理——決定「拒整張卡」還是「收下並標記欄位無法顯示」。
