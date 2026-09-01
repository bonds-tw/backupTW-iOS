# 電子公文接收站 Phase 7：實體自然人憑證開發簽章

- 狀態：**iPhone 14 與實體自然人憑證完整往返已通過**
- 日期：2026-09-01
- 範圍：DEBUG-only 一次性同意請求、配對 USB 往返、實體自然人憑證 SIGN 私鑰簽章、
  MOICA 憑證鏈與確切 consent 驗章、本機證據保存
- 不代表：App Attest 通過、行動自然人憑證 ATH-01／ATH-02 通過、政府 G2C 註冊、正式收件
  地址、來源機關簽章、ESW 解密、收文確認或法定送達

## 為什麼可以先做這條路

目前手機診斷為 `endpoint=unconfigured`／`configuration_missing`，只說明安裝中的開發版沒有
App Attest signing broker URL；`identity_data_sent=false` 與 `signing_started=false` 也證明該次
沒有送出身分資料或開始簽章。這不妨礙另一條完全本機的實體卡開發路徑。

兩條路共用相同的密碼學收尾：對
`bonds-tw-official-document-consent-v1:<SHA-256 hex>` 的 UTF-8 bytes 做
RSASSA-PKCS1-v1_5-SHA256，回傳 holder certificate 與 signature，再由 App 驗 MOICA trust
anchor、憑證效期與確切簽章。差別只在私鑰操作發生於行動自然人憑證服務，或實體卡。

因此，Phase 7 能驗到：

1. 持卡者控制實體自然人憑證的 `SIGN` 私鑰並輸入正確 PIN。
2. iPhone 與 Mac 對同一份 version／scope／timestamp／32-byte nonce 重建出相同 TBS。
3. 換 request、nonce、certificate 或 signature 會被 App 拒絕。
4. 通過 MOICA chain 與 signature 驗證後，receipt 會記錄
   `physicalNaturalPersonCertificate`，證據畫面不會誤稱為行動自然人憑證。

它不能驗到行動自然人憑證的 app-to-app callback、內政部服務紀錄、App Attest 或任何 G2C
交換契約；這些門檻仍各自保留。

## 2026-09-01 真機結果

- 裝置：iPhone 14、iOS 27.0、DEBUG `1.0 (1)`；以 USB 連接 Mac。
- 讀卡環境：macOS 系統 CCID driver `1.5.1`，讀卡機由 PC/SC 顯示為
  `Generic Smart Card Reader Interface`；`open-gpki-pkcs11` 成功辨識一張 GPKI 卡。
- Mac 從 iPhone App data container 拉取一次性 request，重建並顯示確切 TBS digest；PIN
  僅在終端機隱藏提示輸入一次，簽章成功後 response 以 `0600` 權限推回同一 container。
- iPhone 顯示「驗證實體卡簽章」，並成功通過 request 對應、MOICA 憑證鏈與 RSA 簽章驗證；
  最終 receipt 的 `signingChannel` 為 `physicalNaturalPersonCertificate`。
- 驗證後的只讀稽核確認 `physical-card-request.json` 與
  `physical-card-response.json` 均已被消耗，只留下 `prototype-consent.json`；原有合成
  EN／DI／ESW 測試套件未被刪除。

目前 helper 不輸出卡片世代，所以本次結果只證明這張實卡與上述 reader 組合通過，不能外推為
所有第一代／第二代卡片與讀卡機皆已驗證。

## PIN 與個資邊界

- App 產生的 request 不含姓名、身分證統一編號、憑證或 signature。
- PIN 只由 Mac 終端機的隱藏提示讀取；工具沒有 `--pin`、PIN 環境變數或 PIN 檔案介面。
- PIN 錯誤會消耗卡片重試次數，所以一次錯誤立即停止，不自動重試。
- holder certificate 與 signature 只存在於工具的 `mktemp` 目錄及 iPhone App data
  container；腳本退出即刪 Mac 暫存，不寫入 repo、iCloud 或一般文件資料夾。
- transport JSON 被推回後仍不是證據；App 必須重建 request、比對完整 response、驗憑證鏈與
  RSA signature，全部通過才保存 receipt。

## 操作

1. 安裝 DEBUG build，在「資料保險箱 → 電子公文」點「使用實體自然人憑證測試」。
2. 確認範圍後建立一次性 request，保持 iPhone 解鎖並接上 Mac。
3. 插入讀卡機與自然人憑證，在 repo 根目錄執行：

   ```sh
   ./scripts/physical-card-consent.sh --device mashbean14
   ```

4. 只在不顯示輸入內容的終端機提示中輸入 PIN。
5. 工具完成後回 App，再點一次實體卡測試列；只有驗證通過才會出現簽署證據。

若 Mac 同時辨識到多張 GPKI 卡，工具會停止，要求明確加上 `--slot <number>`，不會任選卡片。

## 開源 driver 與平台依賴

工具鎖定 [`chouhsiang/open-gpki-pkcs11`](https://github.com/chouhsiang/open-gpki-pkcs11)
commit `4684289400322b892e2c9ebcd8d56c1e852aefd2`（v0.1.1，LGPL-2.1-or-later）。
上游明確標示非政府官方實作；README 列出 macOS、第一／二代自然人憑證、`SIGN`／`KEYX`、
`SHA256-RSA-PKCS` 與實卡測試狀態。Mac 端使用系統 `PCSC.framework`；目前本機系統 CCID
reader driver 與插卡 reader 均可用，本次 `SIGN` 實卡往返已完成；未測的 reader／卡片世代
組合仍不可視為通過。

平台參考：

- [open-gpki-pkcs11](https://github.com/chouhsiang/open-gpki-pkcs11)
- [Apple CryptoTokenKit](https://developer.apple.com/documentation/cryptotokenkit)
- [內政部自然人憑證 HiCOS 操作手冊](https://moica.nat.gov.tw/download/File/HiCOS.pdf)

## 自動化證據

- Rust：request canonicalization、15 分鐘期限、target tamper、命令列拒收 `--pin`。
- Swift：request 無身分欄位、target tamper、response/request 一致性、RSA-2048 簽章驗證、
  physical signing channel、archive transport files 成功後刪除、已有 receipt 不可覆寫。
- 正體中文：所有新增使用者文案納入 string catalog 與既有 localization gate。

## 下一個完成門檻

1. 另外修正或安裝有 `BONDS_SIGNING_BROKER_BASE_URL` 的 TestFlight/Release build，再做 App
   Attest UAT；不能拿本階段成功代替它。
2. 未向主管機關申請以前，正式 G2C 地址、來源簽章、ESW 解密與收文確認維持不可用，畫面與
   model 繼續 fail closed。
