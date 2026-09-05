# 網頁零知識證明查驗（verifier.mashbean.net/zkp）與 ZKP／SD-JWT-VC 計時比較

2026-09-04。本文記錄「有備而來」下一階段的三件事怎麼接起來：網頁端的零知識證明（ZKP）查驗頁、App 內兩種卡片都能建立 ZKP、以及測試時比較 ZKP 與 SD-JWT-VC 出示的時間差。

## 已經有的東西（本分支併入 main 後）

- **年齡述詞 ZKP**：`AgePredicateProof.swift`／`AgePredicateCredential.swift`／`Native/OpenACAge`。以 ethereum/zkID（commit `b395e09`）的 OpenAC `jwt_2k`＋`show` 電路（Spartan2/Hyrax、P-256），對一張 ES256 SD-JWT 證明「隱藏的出生日期不晚於查驗方給的 cutoff」，也就是「已滿 N 歲」。查驗方先給 nonce（verifier-first），Show 證明綁定持卡人金鑰對 nonce 的簽章，Prepare 證明綁定發卡者簽章；兩個證明以共享承諾連結。
- **兩種卡片來源**：
  - 政府卡片（TWDIW SD-JWT-VC）：直接拿卡片的 SD-JWT 與 `roc_birthday`／`birthdate` 等揭露。發卡者必須在收卡時留下的 API＋Arbitrum 信任快照裡（`OfflineIssuerTrustStore`）。
  - MyData 自發身分證：`SelfIssuedMyDataAgeCredential` 用同一把每卡金鑰派生一份只含 `birthdate` 的 SD-JWT，結果永遠標示「自發、非政府背書」。
- **限制**：卡片沒有出生日期欄位就不能建立（`noBirthDate`）。實測的公路局駕照電子卡沒有揭露 `roc_birthday`，所以目前能做年齡 ZKP 的政府卡是「有生日欄位的卡」；沒有的卡在 App 會直接得到誠實的錯誤。
- **兩機流程**：iPad 顯示一次性請求 QR → iPhone 建立證明 → Bluetooth 傳回 iPad 驗證（矩陣格 G3／G4）。

## 這次新增：網頁查驗路徑

```
iPhone 有備而來 ──掃 QR── verifier.mashbean.net/zkp（Cloudflare Worker）
      │                          │  建立 session：nonce、cutoff、來源、最低年齡
      │  POST 證明包 (JSON) ──▶  │  核對陳述、解析 issuer did:key、政府卡查官方信任清單
      │                          ├──▶ openac-age-verifier（Rust，Mac 上，Cloudflare 隧道）
      │                          │       載入 432 MB + 4.8 MB 驗證金鑰、verify_linked、比對 156＋6 個公開值
      │  ◀── 判定＋計時 ─────────┤
```

- Worker 放不下 432 MB 的 Prepare 驗證金鑰，所以密碼學驗證在 `twdiw-vp-verifier-lite/native/openac-age-verifier`（Rust axum 服務）進行；Worker 只轉送證明、拿回是非與秒數。金鑰以 `openac-age-v1` release 的 SHA-256 釘死，不符就拒絕啟動。
- **請求 QR** 就是 `AgePredicateProofRequest` 的線上格式，多一個 `u`（回應網址）：
  `{"a":18,"b":"<UUID>","c":"<nonce>","d":"2008-09-04","p":"<用途>","s":"g"|"s","t":<秒>,"u":"https://verifier.mashbean.net/api/zkp/response/<id>","v":1}`
- App 只會把證明送到允許清單上的網站（`AgePredicateProofRequest.trustedResponseHosts`：`verifier.mashbean.net`；DEBUG 另加 workers.dev 別名），而且只接受 https、無帳密、無 fragment。掃到別的網址會顯示「不信任的網站，沒有送出任何東西」。
- 證明包裡只有兩個證明、陳述（claim 名稱、格式、cutoff、最低年齡、來源）與發卡者 DID。沒有出生日期、沒有任何欄位。自發卡的發卡者 DID 是持卡人自己的每卡金鑰，是一個穩定假名——這也是允許清單存在的理由。
- 同意畫面會多一句「完成的證明會送到 verifier.mashbean.net」。

## 計時：怎麼比較 ZKP 與 SD-JWT-VC

每次流程 App 都自動寫一筆 `VerificationRunRecord`（只有封閉列舉與毫秒數，沒有個資）。網頁路徑的矩陣格：

| 格 | 流程 | 卡片 |
|---|---|---|
| A2 | OIDC4VP 出示 SD-JWT-VC 到 verifier.mashbean.net | 政府卡 |
| G1 | OIDC4VP 出示自發證件（vc+moica）到同一網站 | 自發 |
| **W1** | 私密年齡 ZKP 送到 /zkp | 政府卡 |
| **W2** | 私密年齡 ZKP 送到 /zkp | 自發 |

欄位對應：`preparationMilliseconds`＝Prepare＋Show（只有 ZKP 有）、`proofPrepareMilliseconds`／`proofShowMilliseconds`、`transportMilliseconds`＝HTTPS 往返、`verificationMilliseconds`＝網站後端 `verify_linked` 秒數（隨判定帶回）、`endToEndMilliseconds`＝掃碼到收到判定。

看結果的三個地方：

1. **App 設定 → 診斷**：「網頁查驗：零知識證明 vs SD-JWT-VC」把同一種卡最近一次成功的兩條路徑並排，含差異秒數。
2. **網頁**：/zkp 結果卡顯示 Prepare／Show／傳輸／後端驗證／Worker 全程；「與 SD-JWT-VC 出示比較」讀同一個瀏覽器裡首頁剛跑過的 OIDC4VP 計時（sessionStorage，只存秒數）。
3. **報告**：`scripts/collect-verification-runs.sh <輸出目錄>` 從接線的裝置拷出 `verification-runs.json`，`summarize-verification-runs.py` 產生 `verification-matrix.md`，新增「網頁查驗：零知識證明 vs SD-JWT-VC」表（median／max、ZKP 建立與網站驗證 median、筆數）。五筆以內只報 raw、median、max，不叫 p95。

建議的測試順序（同一支手機、同一張卡、同一個瀏覽器分頁）：先在首頁跑一次「核對姓名」或「成年」的 SD-JWT-VC 出示，再到 /zkp 對同一種卡建立 ZKP；各做冷／暖各一次以上。第一次 ZKP 會先下載約 76 MB 的證明素材（不計入秒數）。

## 誠實邊界

- 網頁後端目前跑在開發用 Mac，經 Cloudflare quick tunnel 對外；網址每次重啟會變，`native/openac-age-verifier/scripts/run-local.sh --publish` 會順手更新 Worker secret。要長期用得換成具名隧道或雲端主機。
- 網頁只知道「是否至少 N 歲」與秒數；但 Worker 營運者能看到證明包與發卡者 DID。這比 SD-JWT-VC 出示少很多，仍不是零。
- 自發 MyData 證件的年齡證明是持卡人自己簽的派生證件，不是政府背書；頁面與 App 都會標示。
- 沒有生日欄位的政府卡（例如駕照電子卡）不能做年齡 ZKP；「持有證明」（零揭露、只證明持有某發卡者的卡）需要改電路輸入並重建 XCFramework，不在這次範圍。
