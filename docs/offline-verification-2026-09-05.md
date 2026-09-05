# 離線驗證第二階段：iPhone 持卡、iPad 查驗

2026-09-05。基於 main `8cb6a06`，開發分支 `codex/offline-verification`。MyData 在本次範圍明確指「數位身分證」，不包含其他資料保險箱文件。

## 本次交付

- 使用 → 離線查驗準備：兩台連網時獨立核對公開發卡者 API 與 Arbitrum 現行紀錄，原子保存完整信任名單。iPad 不必收卡，也不從 iPhone 複製卡片。完整名單更新會排除已不相符的舊發卡者；網路失敗保留原日期，不冒充更新成功。
- 準備介面分開下載 iPhone 證明素材與 iPad 驗證金鑰，以既有 `openac-age-v1` SHA-256 檢查。iPhone 約 77 MB 下載／1.25 GB 安裝；iPad 約 24 MB 下載／437 MB 安裝（十進位，未含壓縮暫存與執行期空間）。
- 使用 → 查驗年齡（ZKP／SD-JWT-VC）：iPad 選來源、格式，顯示一次性 QR；iPhone 在「回應年齡查驗」掃碼，同意後以 BLE 回傳。
- 新增 S1（政府）／S2（MyData 數位身分證）SD-JWT 年齡比較：只選生日 disclosure，使用 KB-JWT 綁定完整要求衍生的 audience、nonce、iat、sd_hash、cnf 持有人公鑰。不是 OID4VP direct_post，也不宣稱 SD-JWT-VC／OIDF 完整規範認證；憑證承襲 TWDIW 的巢狀 vc 格式。
- S2 與 G4 使用同一張數位身分證、同一把每卡金鑰派生的年齡 SD-JWT；每次派生有新時間與 salt，ZKP 又可能重用 Prepare，所以不是逐位元相同的憑證。結果均為「自發、非政府背書」。
- ZKP 離線回答與收到證明後的查驗不再補下載素材；缺檔先停止。查驗要求在消耗、完成時重新檢查期限，舊查驗被替換／離開畫面時不顯示遲到結果。
- 診斷加上實際 Prepare 快取命中與 payload bytes。cold/warm 原本只表示 App 行程的第一筆／後續筆，現在不再拿它推定快取是否命中。
- 修正雙機收集的 zsh 陣列拆分，部分收集以 exit 2 明示；只統計當次成功拷出的檔案，避免拿舊 iPad 檔冒充新證據。重複紀錄按 id 去重；相同 id 不同內容直接拒絕。
- 離線成功統計只取 verifier；失敗耗時與成功耗時分開。A1／G1 原有 MyData vc+moica／JWT 封套不再誤稱 SD-JWT-VC。

## 測試矩陣與起訖點

| 格 | 來源／出示格式 | 查驗條件 | 本階段用途 |
|---|---|---|---|
| A1 | MyData 數位身分證原有 vc+moica／JWT | 使用 → 查驗他人證件 | 原有離線路徑回歸 |
| G2 | 政府 SD-JWT 包在 VP-JWT | 同上，選政府來源 | 原有離線路徑回歸 |
| S2 | 數位身分證派生 SD-JWT + KB-JWT | 揭露生日，iPad 算成年 | G4 的主要比較基準 |
| G4 | 數位身分證派生 SD-JWT 的 OpenAC | 不揭露生日的成年證明 | 主要 ZKP 目標 |
| S1 | 政府 SD-JWT + KB-JWT | 有支援的生日 disclosure | G3 的比較基準 |
| G3 | 政府 SD-JWT 的 OpenAC | ES256、相容欄位／格式及素材 | 政府 ZKP 目標 |

沒有生日的政府卡記「不支援年齡測試」，不是造一個生日，也不是驗證失敗。現有政府來源供應器取儲存順序第一張政府卡；若多張卡，須先記錄當次實際選到的卡別，完整逐卡選取仍待補齊。這限制不得隱藏在彙總數據中。

離線全程採 iPad 顯示 QR → iPad 判定。`transportMilliseconds` 是顯示 QR → 收到完整 payload，含掃碼、同意、iPhone 建立與 BLE，不能叫純藍牙速度，也不能再加 Prepare／Show。iPad 驗證毫秒是本機查驗；ZKP 此欄是 native verify_linked，SD-JWT 則包含解析、簽章、信任與年齡檢查，微觀操作並不完全相同。Prepare／Show／快取旗標由持卡端提供，作為測試遙測，不參與信任判定。

舊網頁 A2／G1 的 endToEnd 是按下送出 → HTTP 提交完成；W1／W2 從同意後的建立畫面 → 網站結果。兩者不能當成相同的掃碼全程，更不能用舊資料計算 SD-JWT 與 ZKP 的速度倍率。

## 實機操作與取數

1. 兩台解鎖、開啟測試版；iPhone 原有卡片保留。連網到「使用 → 離線查驗準備」，兩台各儲存發卡者信任資料，iPhone 準備證明檔、iPad 準備驗證檔。先完成下載，再開始計時。
2. 兩台開啟飛航模式；在「設定」關閉 Wi-Fi、開啟藍牙。兩台繼續接 Mac 方便取匿名紀錄；不要共享網路。記錄裝置／App 版號、斷網設定、開始時間、卡別。
3. 首輪先做 S2：iPad「查驗年齡」選 SD-JWT-VC／MyData；iPhone「回應年齡查驗」掃碼，確認會揭露生日後送出，以 iPad 判定為準。
4. 再做 G4：同一來源切 ZKP，建立新 QR，再掃碼；記錄冷啟動與實際 Prepare cache。不得為製造冷樣本而刪除數位身分證或清除個資；本次不清除既有 Prepare；若已命中快取，就誠實歸為暖快取，受控冷快取採樣另外安排。
5. 各 S2、G4 至少五次；符合生日條件的政府卡再各 S1、G3 至少五次。每次建立新要求，不重用 QR。A1／G2 至少各一次回歸。
6. 挑戰重播、竄改、未知發卡者、年齡未達、信任／素材缺失列在負向測試，不混入正常成功耗時。自動化合成資料與真實卡分開。

```sh
./scripts/collect-verification-runs.sh ~/Developer/research/offline-verification-2026-09-05/field-run
python3 scripts/summarize-verification-runs.py \
  ~/Developer/research/offline-verification-2026-09-05/field-run/*/verification-runs.json \
  --build 2026090502 --since 2026-09-05T14:00:00Z \
  --markdown ~/Developer/output/有備而來-離線驗證/field-matrix.md \
  --csv ~/Developer/research/offline-verification-2026-09-05/field-run/filtered-runs.csv
```

未實際確認飛航模式／Wi-Fi 狀態時，只能寫「BLE 本機路徑」，不能寫「兩台完全斷網驗收」。樣本少時只報 n、raw、median、max，不叫 p95。樣本需依裝置、build、卡別、格式、傳輸、快取分組；holder／verifier 以一次性匿名關聯碼配對，不用證件號碼或生日。

## 尚未獲得的保證

- 安裝、模擬器測試、單次網頁成功都不能替代兩台實機斷網證據。2026-09-05 取得 iPhone 舊匿名紀錄 46 筆，以及解鎖後讀到的 iPad 舊版自發卡 BLE 查驗成功 1 筆（驗證 21 ms）。後者沒有斷網條件與本次矩陣格，不能當成新版 SD-JWT／ZKP 年齡驗收。
- 既有 OpenAC public input 綁定 issuer key、nonce 與生日條件，但沒有把完整有效期限或撤銷根作為查驗者可獨立驗證的公開條件。native 證明建立前的 expiry 檢查不等於電路／查驗端已證明當下未過期。現階段只報年齡述詞／簽章證明，不稱「證件仍有效」。
- 政府來源表示發卡者曾與本機 API＋鏈上快照相符；不代表所有卡別具有相同身分保證，也不代表目前未撤銷。
- BLE 自訂傳輸未提供應用層加密，查驗方未經身分認證，不能排除轉送要求。SD-JWT 會揭露生日與固定簽署資訊；ZKP 自發 issuer DID 也仍是穩定假名。
- 本機核心與流程檢查使用合成向量；沒有真實政府生日卡、iPad 原生證明效能、兩機斷網成功率之前，完整目標仍未驗收。

規範背景：[RFC 9901](https://www.rfc-editor.org/rfc/rfc9901.html)、[OpenAC Core](https://github.com/ethereum/zkID/blob/main/specs/1-openac/README.md)。本實作以 repository 中 `openac-age-v1` 原生碼與釘選素材為準。

## 首輪實機阻塞修復（build 2026090502）

兩台按「儲存發卡者信任資料」後，build 2026090501 顯示通用的恢復連線訊息。以正確公開名單重現：43 個發卡者中 41 個具鏈上紀錄，舊程式一次送出 123 筆 RPC，公共服務回覆 HTTP 429。每批 3 個發卡者、9 筆 RPC 依序核對，批次間隔 0.5 秒後可完成。

修正版保留每個發卡者的交易、收據、最新合約狀態三項核對，不改信任條件。全程失敗不回傳部分結果供更新；重複 RPC id 拒絕，避免不可信回覆導致字典崩潰。介面顯示完成進度，HTTP 429、名單 API 錯誤、鏈上逾時與素材／空間錯誤分別顯示；已完成或取消後的延遲進度不覆蓋結果。

以實際 App 的 Swift 來源在 Mac 連線驗證：41 個相符、2 個沒有鏈上紀錄、0 個 unavailable，耗時 11.62 秒。這是公開信任準備的 Mac 測量，不是 iPad 年齡證明驗證耗時；兩台仍需以修正版重按儲存後確認成功。

公共 RPC 端點與可用性說明：[Arbitrum 官方文件](https://docs.arbitrum.io/arbitrum-essentials/reference/node-providers)。
