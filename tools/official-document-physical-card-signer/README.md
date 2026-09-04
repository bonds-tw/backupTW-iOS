# 實體自然人憑證開發簽章工具

這是電子公文個人接收站的 **DEBUG-only** 開發工具。它從 iPhone 的一次性請求重建固定
`local-prototype-only` 同意內容，使用實體自然人憑證的 `SIGN` 私鑰做
`SHA256-RSA-PKCS`，再把憑證與簽章交回 App 驗證。

它不會申請或核發 G2C 收件地址、不會建立法定電子公文接收站、不會呼叫內政部服務，也不會
測到行動自然人憑證的 ATH-01／ATH-02 app-to-app 往返。PIN 只從不顯示輸入內容的終端提示
讀取；沒有 `--pin` 參數，也不從環境變數或檔案讀取 PIN。錯一次不會自動重試。

## 上游與授權

卡片通訊固定使用
[`chouhsiang/open-gpki-pkcs11`](https://github.com/chouhsiang/open-gpki-pkcs11)
commit `4684289400322b892e2c9ebcd8d56c1e852aefd2`（v0.1.1，LGPL-2.1-or-later）。
它是非政府官方、依 ISO 7816／PKCS#15 與實卡行為完成的開源實作；此工具只供開發測試，
驗證結果仍由 iOS App 內附的 MOICA trust anchor 與收到的 holder certificate 完成。

一般操作請從 repo 根目錄執行：

```sh
./scripts/physical-card-consent.sh --device mashbean14
```

腳本會在 `mktemp` 目錄中用 `xcrun devicectl` 拉取 request、執行本工具、再把 response 推回
同一個 App data container；退出時刪除 Mac 端暫存。它不使用 iCloud、Dropbox 或 repo
工作樹保存 holder certificate。

