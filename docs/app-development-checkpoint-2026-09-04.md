# 有備而來 App 開發階段註記（2026-09-04）

這份文件記錄目前已推到 GitHub 的 App 開發成果、實機證據與分支整合狀態。它是下一階段接手用的檢查點，不代表所有卡片、裝置及正式環境都已驗收完成。

## GitHub 分支狀態

- `main` 目前為 `276f5db`，已合併 PR #58 的實體卡／電子公文開發成果。
- `codex/711-pickup-qr` 目前為 `88d78a5`，包含超商取貨、驗證矩陣與匿名自動計時，對應 PR #56。
- `codex/mydata-vault-flow` 目前以 `codex/711-pickup-qr` 為基底，包含 MyData 保險箱、批次匯入與後續 UI 修正，對應 PR #57。本文件也放在這條整合度最高的開發線。

PR #56 目前與更新後的 `main` 有衝突；PR #57 則以 PR #56 為 base。合併模擬顯示衝突同時跨及在地化、驗證計時、MyData 模型、首頁、出示／查驗畫面及測試，後續應逐檔整合並跑完整測試，不應直接選擇整份 ours 或 theirs。

## 本階段已完成

- App 安裝識別 `did:key`、每張證件獨立 holder key，以及 Face ID／裝置密碼解鎖與十分鐘 grace period。
- 政府卡、本人自發國民身分證與 MyData 資料保險箱的首頁分區、卡片堆疊、欄位中文化及詳情介面。
- 官方 API 與 Arbitrum 信任紀錄的分層呈現，保留 API、鏈上紀錄及狀態不明的差異。
- 電信卡產生超商取貨 QR Code、五分鐘倒數與重新產生流程；使用者已回報以有備而來完成一次實際超商取貨。
- OIDC4VP／離線查驗流程的匿名自動計時記錄，可輸出 JSON、Markdown 與 CSV，不保存姓名、DID、憑證識別碼或揭露內容。
- MyData 個人文件的受保護本機 archive、PDF／ZIP 正規化、SHA-256 指紋、批次連續匯入、預覽、更新及刪除介面。

## 已取得的驗證證據

- 驗證計時功能的 focused regression 曾通過 7 個 suites、43 項測試，並完成 iPhone arm64 安裝。
- MyData 開發線曾完成 1,562 passed、6 skipped、0 failed；PR #57 的 Build and test 已通過。
- 使用者已回報 iPhone 與 iPad 可連線，並以有備而來的電信卡 QR Code 完成一次門市取貨。

這些證據只對應當時的 commit、裝置與測試情境。單次超商成功不能推論所有電信卡、所有欄位或所有 OIDC4VP 組合均已通過。

## 下一階段仍待完成

- 逐檔整合 PR #56 與目前 `main` 的衝突，再把 PR #57 更新到新的共同基底；完成前不宣稱功能已進入 `main`。
- 重新驗收新版自發國民身分證的姓名、成年、國籍及身分證字號選擇性揭露。
- 用真實 MyData 帳號逐項完成連續下載、延遲文件、重新啟動、更新、刪除、原始檔預覽及 PDF 簽章檢查。
- 完成線上／離線、iPhone／iPad、自發／政府卡、OIDC4VP／ZKP 的測試矩陣與秒數報告。
- 補完收卡後建立零知識證明、公開訊號、challenge binding、nullifier 與撤銷 root 驗證；目前骨架不等於完整 ZKP 產品。
- Passkey 仍只有帳號／復原架構評估，尚未實作 AASA、Associated Domains、WebAuthn backend 或跨裝置復原。
- Release 簽章後端、TestFlight／App Store 上架與官方註冊／介接仍未完成，不應以 DEBUG build 或實驗站代替。

## 個資與測試資料界線

- 自動計時最多保留 500 筆本機技術紀錄，不收集揭露內容及可直接識別持卡人的欄位。
- MyData 原始文件只存於 App 的受保護 Application Support，排除備份並提供刪除；仍須以實機確認鎖定、刪除與保存必要性。
- 測試報告只應輸出匿名 pairing code、流程、傳輸方式、階段耗時及結果，不應提交真實 QR、presentation、憑證內容或個資到 repository／issue。

