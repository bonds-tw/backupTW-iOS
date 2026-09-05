# 有備而來（Bonds）設計系統 v1.0

2026-09-01 建立，同日完成 P0–P3 首輪實作。依據同日的全面 UI/UX 審計（見 `~/Developer/output/有備而來-施工/UI-UX-全面審計-2026-09-01.md`）。

## 0. 名稱與定位

設計系統與產品同名：「**有備而來**」（Bonds）。程式碼命名空間用 `Bonds`，token 層在 `backupTW/BondsDesign.swift`——全 app 唯一的來源。

一句定調：**已經備妥的鄰居**。把民防的沉重做成日常的安心；視覺上冷靜、誠實、可快速判讀，不慶祝過頭、不恐嚇、不裝可靠。

適用範圍：backupTW-iOS 全部使用者可見畫面。官網（bond-website）的繪本視覺是另一套語言，兩者共享的是語氣與七色錨點，不共享版式。

## 1. 設計原則

1. **誠實是版式，不只是文案。**「不確定」「部分支援」「離線無法確認」是一等公民狀態，永遠有自己的顏色、符號與措辭，絕不可與成功態混淆。`.partial` 看起來絕不能像 `.supported`（符號＋色彩＋措辭三重承載，缺一不可）。
2. **離線是預設，不是降級。** 不依賴任何遠端資源（字體、圖片）；每個列表區分「空」與「讀不到」；網路失敗的畫面必須自帶重試，不能叫使用者重開畫面。
3. **一眼可判讀。** 查驗結果服務的是櫃檯與檢查哨：大字、高對比、色彩之外必有符號與文字。判定卡是全 app 視覺份量最重的元件，其他一切讓路。
4. **儀式感取代裝飾。** 動態與觸覺只用在「有證據支撐的時刻」（對方確認收到、簽章完成、新卡入夾）。沒有 confetti，沒有裝飾性動畫；但該有的時刻不能空白。
5. **系統件優先。** SF 字體、SF Symbols、UIKit 現代 API（`UIButton.Configuration`、list layout、semantic colors）。唯一例外是卡面（WalletCardView）：它模擬實體證件，擁有自己的封閉規格（§9.1）。

## 2. 色彩

### 2.1 決策：主色是靛，不是綠

現況病灶：AccentColor 空殼（全 app 掉回預設藍），解鎖頁與超商流程卻用 systemIndigo——「主色」同時是藍與靛。而品牌最強的視覺資產是墨綠卡面。

為什麼互動主色不能用綠：**綠已經被「驗證通過」佔用**。查驗結果的紅綠燈是安全關鍵語意，互動色若也是綠，按鈕會被誤讀成通過狀態。橙、紅同理不可用。靛既有（解鎖頁）、與所有判定色都拉得開、civic-tech 氣質成立——正式化它。

### 2.2 Token 表

| Token | Light | Dark | 用途 |
|---|---|---|---|
| `Bonds.Color.accent` | `#4B4ED6`（以 systemIndigo 微調沉穩） | `#7D7AFF` | 全域 tint：按鈕、連結、進度條、tab 選中。**寫進 AccentColor.colorset**，個別畫面不再手指定 systemBlue/systemIndigo |
| `Bonds.Color.brandInk` | `#0D5B48` | `#0D5B48` | 品牌識別色（墨松綠）：卡面、app icon、行銷面。**不做互動元件**，不隨深淺色變 |
| `Bonds.Color.verdictPass` | systemGreen | systemGreen | 判定：通過 |
| `Bonds.Color.verdictCaution` | systemOrange | systemOrange | 判定：注意／部分／離線未知 |
| `Bonds.Color.verdictFail` | systemRed | systemRed | 判定：拒絕／錯誤 |
| 中性色 | 全用系統 semantic（`.label`、`.secondaryLabel`、`.systemGroupedBackground` 系列） | 同左 | 禁止新增硬編碼灰階 |

判定色的使用規格固定為 **「0.14 alpha 色底＋SF Symbol tint＋`.label` 文字」**（VerifierViewController 實測過對比的做法）。裸色文字（綠字、橙字直接當 label 色）禁用——實測 1.99:1，這是已付過學費的教訓。

### 2.3 規則

- 同一語意只有一種色。信任狀態在 TrustCenter 顯示綠、在 TrustRecordDetail 顯示橙是**語意 bug**，不是風格差異，最優先修。
- `.secondaryLabel` 只能用於 subheadline 以下的輔助字，**禁止用於 body 級整段文字**（light mode 實測 3.44:1，不過 AA）。整段說明文用 `.label`。
- 卡面 36 個字面色全部收進 `Bonds.CardPalette`，並明文註記「卡面模擬實體證件，刻意不隨深淺色模式變化」。
- 新增顏色一律先問：這是哪個語意 token？沒有對應 token 就不新增。

## 3. 字體排印

全 app 只有六個角色，全部 Dynamic Type：

| 角色 | 規格 | 用途 |
|---|---|---|
| `pageTitle` | `.title2` + bold | 頁內大標（取代現況五種做法：title2／title3／largeTitle／34pt／22pt） |
| `sectionTitle` | `.headline` | 區塊標題（現況已一致，明文化） |
| `body` | `.body` | 說明文，一律 `.label` 色 |
| `secondary` | `.subheadline` | 輔助說明、副標 |
| `caption` | `.footnote` | 註腳、時間戳 |
| `mono` | `.body` monospaced，包 `UIFontMetrics` | 識別碼、指紋、DID |

- 頁面層級標題交給 navigation bar：第一層畫面 `prefersLargeTitles = true`，push 進去的畫面 `.never`——由全域 `UINavigationBarAppearance` 統一設定，個別畫面不再自行開關。
- 固定 pt 只允許出現在卡面（§9.1）。卡面之外現存三處未包 `UIFontMetrics` 的 mono 字（ZKProof 1139、TrustCenter 82、TrustRecordDetail 51）要補。
- LicenseViewController 要設 `title`（現況導覽列空白）。

## 4. 間距與網格

4pt 網格，token 只有七個：`4 / 8 / 12 / 16 / 20 / 24 / 32`。

- 頁面左右邊距：**20**（現況大宗，維持）。
- 卡片容器內距：**16**。
- 卡面內距：**20**（收斂現況 18／21／22 三種——同一個檔案內三種卡三種內距）。
- stack spacing 現況 12 種值、31% 不在網格上（10、6、14、18）→ 就近吸附到 token。
- 42 這類 outlier（解鎖頁）改 40（= 8×5）或明文豁免。

## 5. 形狀與高度

| Token | 值 | 用途 |
|---|---|---|
| `radius.container` | 16 | 頁面級卡片容器（收斂現況 14／16） |
| `radius.card` | 12 | 巢狀卡、caveat 卡（PresentationUI 現值，維持） |
| `radius.walletCard` | 20 | 皮夾卡面（現值，維持） |
| 按鈕 | `.capsule` | 主次按鈕一律 capsule（現況七處 capsule、一處 .large、其餘預設——統一 capsule） |

**所有圓角一律 `cornerCurve = .continuous`**（現況只有 4 處是）。

陰影只有一套：`Bonds.Shadow.card`（black 0.18、radius 22、offset (0,12)）——合併現況兩套相近參數。深色模式下陰影自然弱化，不另調。

## 6. 動態

| Token | 值 | 用途 |
|---|---|---|
| `motion.quick` | 0.18s | 狀態切換、按壓回饋 |
| `motion.standard` | 0.25s | 版面變化、進出場 |
| `motion.flip` | 0.5s | 卡片翻面 |
| spring | damping 0.7 | 按壓縮放（現值） |

- 收斂現況六個 magic number（0.18／0.22／0.3／0.34／0.5）。
- Reduce Motion 三規則明文化（現況已做對，寫下來）：翻面直接換面不翻、QR 輪播幀間隔加倍、傾斜特效不啟動。
- WalletMotionCoordinator（陀螺儀反光）已停用：若確定不回歸，連同 applyTilt 管線一併退役；若保留，改名 `CardTiltFeed`——它不是動畫協調器，名字會誤導後人。

## 7. 觸覺

維持「只有證據支撐的時刻才震」的紀律，但把清單補完整：

| 時刻 | Haptic | 現況 |
|---|---|---|
| 對方裝置確認收到（證件出示） | `.success` | ✅ 已有（全 app 唯一） |
| 對方裝置確認收到（ZK 傳送） | `.success` | ❌ 缺——同語意時刻，一條規則兩種行為，必補 |
| 領卡成功（新卡入夾） | `.success` | ❌ 缺 |
| 查驗判定出爐（查驗方裝置） | 通過 `.success`／拒絕 `.error` | ❌ 缺 |
| 解鎖失敗 | `.error` | ❌ 缺 |
| QR 掃描鎖定 | `.light` impact | ❌ 缺 |

裝飾性 haptic（翻卡、展開）維持不做。

## 8. 狀態設計

### 8.1 四態矩陣

每個有資料的畫面在 PR 時要能回答四格：Loading／Empty／Error／Success。規格：

- **Loading**：按鈕內建 spinner（`showsActivityIndicator`）為預設；整頁等待用置中 spinner＋一句話說明在等什麼。**禁止凍結畫面當等待**（現況：領卡掃描後相機凍格、零回饋直到 alert）。
- **Empty**：圖示＋一句話＋**直達動作按鈕**。空狀態叫使用者「去首頁建立」卻不給按鈕，是死路（現況：離線出示的 nothingToShow）。「空」與「讀不到」是兩種狀態，分開做（首頁已示範，推廣）。
- **Error**：inline 狀態字＋重試按鈕是預設（Verifier 的 unavailableLabel + retryButton 是範本）。**Alert 只用於「確認一個有後果的動作」，不用於通報結果。**「請重開畫面」禁用。
- **Success**：結果用畫面或 inline 卡呈現，**不用 alert**。現況領卡成功與失敗共用同一顆 alert、唯一差別是內文——成功要至少視覺分流；理想是回首頁後新卡動畫入場＋haptic＋VoiceOver announcement，把 app 唯一的獎勵時刻做出來。

### 8.2 Alert 政策

現況 52-57 處 UIAlertController。收斂規則：

- 保留：破壞性動作確認（刪卡、清除全部——現有文案是模範等級，不動）、不可逆的個資送出確認。
- 改全頁：連續同意鏈（ZK 的「下載 2GB → 身分證字號 → 外部簽章」三連 alert 改成流程內的同意頁——重要決定不該在慣性點擊裡被吃掉）。
- 移除：結果通報 alert（改 inline／結果頁）、工程計時資訊（出示成功 alert 裡的「請求擷取與驗證：x.xx 秒」移到診斷頁，那裡本來就有完整版）。
- 密碼錯誤遞迴 alert（MyData 解壓）改 inline 重試。

### 8.3 顯示但停用

功能不可用時**顯示列但停用＋一句原因**（ZK 已有先例），取代現況「憑空出現／消失」（出示列只在有卡時出現、更新備份入口在首頁與設定間搬家）。使用者上次按過的按鈕不可以不見。

## 9. 元件庫

### 9.1 卡面（WalletCard）——封閉規格

卡面模擬實體證件，是唯一豁免 Dynamic Type 與深淺色的元件（**2026-09-02 拍板**：淺色模式下卡面維持原色、不出淺色變體——一張證件不會因為房間變亮而換色，Apple Wallet 的卡片亦然）。條件：

- 全部色值收進 `Bonds.CardPalette`（現況 38 個字面色散在檔內）。
- 內距統一 20；圓角 20 continuous；描邊、guilloche、specular 維持現規格。
- **必補 accessibility**（現況零程式碼，核心物件 F 級）：整張卡聚合為單一元素，label＝「卡名，狀態」；遮罩號碼用讀法友善格式（逐段，不逐字元）；翻面、詳情、出示、刪除做成 custom actions。

### 9.2 判定卡（VerdictCard）——最重要的元件

統一現況兩套視覺（emoji ✅／⚠️ 色底卡 vs SF Symbol tint）為一套：

- SF Symbol（`checkmark.seal.fill`／`exclamationmark.triangle.fill`／`xmark.seal.fill`）＋0.14 alpha 色底＋`.label` 大字（`.title2` bold scaled）。
- 三向語彙：通過／注意（含離線未知、部分）／拒絕。**沒有判定就不出卡**（ZKVerify 現規則，推廣）。
- 附 `spokenLabel`（VerdictSymbol 現有機制）＋`.layoutChanged` announcement＋判定自動移到摺上（ZKVerify 的 liftTheVerdictAboveTheFold，推廣到 Verifier 結果頁）。
- Caveat 列表直接掛在判定卡下方，一句一 label（VoiceOver 可逐條導航），排序沿用 `VerifiedResultSection.order`（它是安全性質，有測試）。

### 9.3 其他元件

| 元件 | 規格 | 現況對應 |
|---|---|---|
| `BondsButton` | Configuration 四型：primary（filled+accent）／secondary（gray）／quiet（plain）／destructive（filled+red）；一律 capsule、`buttonSize = .large`（廢除手動 heightAnchor 54） | 23 處 Configuration 收斂；2 處舊 API 改寫 |
| `ListCard` | r16、`secondarySystemGroupedBackground`、內距 16 | 收斂五套卡片容器 |
| `NestedCard` | r12、`tertiarySystemGroupedBackground` | PresentationUI 現值 |
| `StatusRow` | 支援／部分／不支援，◐ 三重承載模式 | Capability 頁現規格，元件化 |
| `SensitiveContent` | 「點按顯示」遮罩＋背景自動收合＋app switcher 隱私盾 | StoredCredential/GovernmentCard 現行為，元件化 |
| `EmptyState` | 圖示＋一句話＋CTA 按鈕 | 首頁邀請卡經驗推廣 |
| `ScannerBanner` | 掃描器頂部語境條：說明→進度→**拿錯 QR 提示** | §10.3 |
| 列表 | `.insetGrouped` list layout＋CellRegistration（現況已一致）；MyDataProfile、OfficialDocumentInbox 兩檔 legacy tableView 改寫 | |

### 9.4 圖示

段落標題的 emoji（🪪🏛️🗂️）全部改 SF Symbols＋`accent` tint。emoji 只保留在判定卡以外的零處——判定卡也已改 SF Symbol（§9.2）。國旗等證件元素屬卡面規格，不受此限。

## 10. 導覽與流程規範

### 10.1 Modal 政策

- **一次最多一層 modal。** 流程內的多步驟一律是同一個 navigation container 裡的 push 序列。現況 MyData 是 modal 疊 modal 疊 sheet 疊 alert（四層），整條改為單一 nav 的 push 流。
- Settings 從兩個入口進去必須同一種 presentation（現況 Home fullScreen、Use pageSheet，同一畫面兩種關法）。Settings 內深導覽到第三層，改成 push 或壓平。
- 長流程進度 sheet（ZK 傳送）`isModalInPresentation = true`——30 秒運算不可以被隨手下滑丟掉，除非有明確恢復路徑。

### 10.2 「出示」單一入口

現況「出示」四分裂（線上出示／離線出示／超商條碼／ZK 傳送），初次使用者在查驗現場幾秒內選不對。收斂為：

- Use 分頁一個「**出示**」入口 → 掃描 → **依 payload 自動分流**（`OID4VPAuthorizeLink` 與 `PresentationRequest` 已可辨別，程式碼支援這個設計）。
- 超商條碼保留獨立入口（它是「產生條碼」不是「掃碼出示」，心智模型不同）。
- 首頁長按卡片的「出示」依卡片來源決定路徑（現況一律走線上，連主要用途是離線的自發身分證也是——語意錯誤）。

### 10.3 掃描器互斥提示

App 內至少五種 QR。拿 A 流程的碼進 B 流程，現況掃描器完全沉默，看起來像壞掉。規則：**每個掃描語境都要認得其他四種格式，掃到就提示「這是○○用的 QR，請改用○○」**（PresentCredential 與 ZK 端已有先例，補領卡與線上出示端）。

### 10.4 入口穩定

- MyDataOnboard 六個入口收斂：建立入口留在首頁，更新入口固定在卡片詳情頁，Settings 的「更新備份」移除或改為跳轉。
- 刪除卡片同時存在於長按選單**與詳情頁**（現況只在長按選單，詳情頁反而不能刪）。
- 卡片 tap 的第一優先是進詳情；翻面改為明確控制（卡角翻面鈕或詳情頁內切換）。「tap 翻面→背面按鈕→詳情」三步才到內容，且 tap 在疊卡狀態下又變成展開——同一手勢三種行為。

## 11. 文案系統

### 11.1 Voice & tone 五條

1. **先講結論與代價，再講原因。** 標題說發生了什麼；第一句說你損失／送出了什麼、還能不能重來；機制與哲學收進「瞭解更多」。**單一 label 超過 60 字即觸發拆層**（現況 13 則超過 80 字的文字牆全部照此重寫；ZKProof 的逐項 caveat 卡是對的做法，推廣到所有 alert）。
2. **按鈕寫代價，不寫客套。**「傳送號碼給內政部」「刪除卡片」；純知悉一律「好」；「確認」只用在按下去會發生事情的地方（現況四處「已複製」提示用「確認」，改「好」）。破壞性操作必附復原路徑或明言「無法復原」。
3. **對人說「你」，用台灣的日常詞。** 全面「你」（現況僅一處「您」，OfflineVerifier.swift:523）；密碼學名詞不進句子主幹，SHA-256／DID／OIDC4VP 只能以括號註記存在；「忘記」這種直譯改「清除」。
4. **誠實優於安撫，但不轉嫁焦慮。** 可以說「這個 App 無法確認清單是完整的」，不可以說「請放心」；驚嘆號維持 0；「那是一個承諾，不是一個性質」是全 app 最好的句子，當範本。
5. **開發者文案物理隔離。** 指令、路徑、raw error、assertion 字樣走 `#if DEBUG` 或獨立 catalog；「（開發用）」後綴不算隔離。（現況：公文匣實體卡測試列 157 字含 repo 路徑與 `--device mashbean14`。）

### 11.2 詞彙表（vocabulary tokens）

| 統一用 | 淘汰 |
|---|---|
| 查驗方 | 驗證端 |
| 持卡人 | 持有人、持證人 |
| 這個 App | 本 App、這支 App |
| 這支手機 | 這支 iPhone（僅與 Mac 對舉時可用） |
| 卡片（查驗端 zh-Hant 禁用「文件」——既有硬規則） | |
| bonds.tw（擇定一種寫法） | bonds-tw |
| 零知識證明（首次附白話同位語）→ 其後「數學證明」擇一 | 兩詞混用 |

詞彙表照 `WallCopy` 的模式落成測試——這個 repo 已證明文案規則可以被測試守住。

### 11.3 標點

全形逗號句號（現況 11 則半形逗號集中在卡片讀取錯誤區，修）；「——」是 house style（70 則），保留；驚嘆號禁用；引號用「」。

### 11.4 修 InfoPlist

`NSCameraUsageDescription` 補 zh-Hant 條目（現況中文塞在 en locale 底下，靠 fallback 僥倖）。

## 12. 無障礙

- 對比 AA（4.5:1）是底線；量測過的三個安全範本寫進規範：判定色 0.14 底＋`.label` 字、巢狀卡用 `tertiarySystemGroupedBackground` 隔層、整段文字不用 `.secondaryLabel`。
- 卡片 accessibility 規格見 §9.1——這是核心物件的最大缺口。
- Announcement 清單：判定出爐（`.layoutChanged`＋游標停泊，ZKVerify 已有）、藍牙送達（**出示端 21.7 秒進度現況寫進沒人聽得到的 label**）、新卡入夾（`.screenChanged`）。
- Dynamic Type 維持現況紀律（139 處 preferredFont），卡面豁免。
- 色彩之外必有符號與文字（現況判定與 partial 已做對，明文化為規則）。

## 13. Token 層實作

Token 層已落地為 `backupTW/BondsDesign.swift`（`Bonds.Color` / `Font` / `Space` / `Radius` / `Shadow` / `Motion` / `Haptic`，以及 `Bonds.round(_:_:)` 與 navigation bar 政策註記）。`AccentColor.colorset` 已寫入 light `#4B4ED6`／dark `#7D7AFF`。`PresentationUI`（VerifierViewController.swift）保留原名，內部已改走 token 並升格為判定卡的唯一實作。

## 14. 治理

- Token 唯一來源是 `Bonds.swift`＋`AccentColor.colorset`。code review 檢查點：新 PR 出現字面 duration／圓角／間距／`systemBlue`／`systemIndigo` 即退回。
- 文案規則落成測試（詞彙表、半形標點、「您」、60 字上限），掛進現有的 LocalizationCoverageTests 旁邊。
- 對比測試（TextContrastTests 已存在）擴充涵蓋判定卡與 consent 條款文。
- 本文件與程式碼同步演進；改 token 先改這裡。

## 15. 導入路線

**P0（一天內，全是小工）**：AccentColor.colorset 落地＋十餘處 systemBlue/systemIndigo 改 accent；TrustCenter vs TrustRecordDetail 信任狀態矛盾修正；ZK 送達 haptic 一行；TrustCenter 重試按鈕（照抄 Verifier 現有 pattern）；「您」→「你」；11 則半形逗號；四處「確認」→「好」；「忘記」→「清除」；NSCameraUsageDescription 補 zh-Hant；LicenseViewController 補 title。

**P1（一週）**：`Bonds.swift` 落地、PresentationUI 升格；標題階層收斂為 pageTitle；圓角／間距吸附 token；判定卡統一（emoji → SF Symbol）；卡片 accessibility；全域 UINavigationBarAppearance。

**P2（二到四週）**：出示單一入口＋payload 分流；MyData 流程壓平成單一 nav push 序列＋密碼錯誤 inline 化；掃描器互斥提示補領卡／線上出示端；領卡成功時刻（新卡入場動畫＋haptic＋announcement）；空狀態補 CTA；13 則文字牆兩層化改寫；ZK 同意鏈 alert 改全頁。

**P3（有餘裕再做）**：兩檔 legacy tableView 改寫；動態 polish（新卡入場、判定卡進場的 0.25s 過場）；正式 app icon（現況是 Apple 範例佔位圖）；WalletMotionCoordinator 去留決定。


## 16. 2026-09-01 首輪實作紀錄

P0 全數完成；P1–P3 完成如下。**未做**（含理由）：

- OfficialDocumentInboxViewController 的 legacy `textLabel` API 改寫——該檔有進行中的未 commit 修改（公文匣 WIP），避免踩到，留待該工作收斂後再做。
- MyDataProfileViewController 的 modern list 改寫——同屬 P3 技術債，功能無恙，延後。
- MyDataOnboard 六入口收斂與首頁卡片 tap 行為——卡片 tap＝翻面是 2026-08 使用者拍板的設計，不動；入口收斂需要產品決策，僅在文件保留建議。
- ZK 傳送進度 sheet 維持可下滑——檔內註解論證「下滑＝叫停電波」是刻意的控制，尊重原設計。
- WalletMotionCoordinator 保留停用狀態——使用者先前明確要求保留以便日後恢復。

已完成的重點：AccentColor 落地與藍靛統一（含 Settings/Use 圖示改單一 accent tint、去 emoji 區塊圖示）；信任狀態矛盾修正（含測試改寫）；判定卡統一為 SF Symbol 版（emoji 簽名保留、8 呼叫點不動）；查驗結果頁 VoiceOver 停泊＋判定 haptic；皮夾卡片 accessibility（單一元素＋custom actions）；出示單一入口（payload 自動分流、長按選單改走統一入口）；MyData 流程壓平為 push；掃描器互斥提示與領卡進行中回饋；領卡成功時刻（haptic＋切回首頁＋announcement，失敗才用 alert）；出示成功 alert 去計時；ZK 下載同意改全頁；空狀態／失敗態補 CTA 與重試；文字牆 top 9 改寫；「您／半形逗號／本 App／確認當知悉鈕／忘記」全數修正；相機權限文案補 zh-Hant；正式 app icon（scripts/make-brand-icon.swift，墨松綠盾形勾記）。

### 2026-09-02 實機回饋修正

1. **保險箱卡面**：文件名稱移到卡面頂部露條內（一行、可截斷），鎖頭與 meta 移到卡底——疊卡時每張都認得出來。
2. **疊卡順序**：hero 改為資料序最後一張（置底、最前 z）；收合的上下視覺順序＝展開的清單順序，展開是攤開、收合是聚攏，最前面那張永遠留在最下（Apple Wallet 式連續性），不再翻面。GovernmentStackTests 鎖住此性質。
3. **信任狀態（使用者拍板，推翻 09-01 的橙色 partial）**：官方 API 載到就給綠勾；盾牌是「區塊鏈也相符」的加成，不是門檻；紅色只留給真衝突（mismatch）。兩畫面共用同一對照的原則不變。

### 2026-09-02 實機回饋修正・第二批

4. **展開動畫 header 重影**：`setCollectionViewLayout` 交換整個 layout 時新舊 header 同時在場。改為單一 layout 就地 `invalidateLayout()`（section provider 讀 live 狀態），只有 frame 在動。
5. **匯入列巨大化**：裝置上 self-sizing pass 沒跑、卡在 estimated 220pt。mydata-actions section 改走 `NSCollectionLayoutSection.list`（UIKit 可靠的自量測路徑）。
6. **保險箱標題被通用化**：檔名隱私過濾器只放行 registry 標題，真實文件（綜所稅清單）全變「MyData 文件」。改為 registry 優先、否則保留去副檔名＋UntrustedText 消毒後的檔名——持有人自己的皮夾上，可辨識勝過遮名。既有的通用名條目需重新匯入一次才會帶到正式名稱。
7. **發卡者離線名冊**（IssuerNameBook）：每次抓到信任清單（領卡、開信任中心）就把 DID→機關名稱寫進本地名冊；卡面上型別對照表不認得的卡，改顯示信任清單的機關名稱＋readable 卡別，而不是截斷的 DID。清除全部資料時一併清除。
8. **關於有備而來**：設定列原本點不開（看起來可點的死控制）。補 About 頁：一句定位、版本、官網與原始碼連結。

### 2026-09-02 第二輪打磨

9. **公文匣 Detail 兩層化**：EN/DI/ESW 解析狀態與 EN 指紋收進「顯示技術細節」揭示列（預設收合）；公文內文改全墨（body 級文字不用 secondaryLabel）。
10. **出示端藍牙送達 VoiceOver 播報**：與查驗端同級——只在有證據的那一刻播一次，不逐百分比。
11. **查驗畫面命名**：ZKVerify 標題改全名「查驗零知識證明」——「查驗證件／查驗證明」在檢查哨一瞥只差一個字。
12. **文案規則測試化（CopyGuideTests）**：你／全形逗號／這個 App／bonds.tw／90 字文字牆預算（兩則 DEBUG 作業指示列入具名 allowlist），掛在編譯後的 zh-Hant 資源上逐句掃。
13. **可讀寬度 token（Bonds.readableHorizontal）**：出示／查驗／ZK 兩端／結果頁五處，窄螢幕滿版、寬版面（iPad 查驗方）置中封頂 640pt。
14. **MyData 申請區塊（實機截圖回饋）**：①網頁步驟推入後補 `.never`＋文件名標題，消除頂部大片黑色空區；②導引條標題可換行不再截斷；③步驟列改用 shouldSelect 而非停用 cell——停用態把整個精靈畫成灰色；④流程完成後收起「接下來會發生什麼」與「記住常用資料」，完成頁只講完成的事。
15. **文字牆清尾**：ZK 建立頁開頭說明 102→72 字；>90 字的使用者文案歸零（測試守住）。

### 2026-09-02 第三輪

16. **入口收斂落地（§10.4）**：「更新備份」唯一入口固定在身分證詳情頁的「管理」群組（設定頁的搬家入口移除）；「刪除卡片」同時存在於長按選單與兩個詳情頁（同一份確認文案，兩個門不會漂移）。
17. **公文匣三頁 legacy `textLabel` API 全面現代化**（UIListContentConfiguration；測試同步改讀 contentConfiguration，斷言強度不變）；ConsentEvidence 指紋群組同樣收進「顯示證據指紋」揭示列。
18. **MyData 精靈細修（實機回饋）**：封面 icon 34pt/52 框改 title1 scale/40 框；`.tintColor` 在無視圖脈絡烘圖會變灰——改解析 AccentColor named color；封面邊距吸附 token。導引條重構為兩列（標題＋X／說明＋個人文件鈕），按鈕永不壓縮、文字換行。
19. **App icon v2**：盾面改紙質垂直漸層＋內縮壓邊 hairline、地色補卡面語言的右上柔光、58% 光學置中。產生器 `scripts/make-brand-icon.swift`。
