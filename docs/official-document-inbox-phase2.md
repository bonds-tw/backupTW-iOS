# 電子公文接收站 Phase 2：合成交換套件與本機狀態

- 狀態：**App 端合成垂直切片已實作**
- 日期：2026-08-31
- 範圍：EN／DI／ESW 解析邊界、SHA-256 完整性、冪等收文、受保護原始檔、本機未讀／已查看、Release signing broker intent／session seam
- 不代表：G2C 已介接、機關來源已驗證、ESW 已解密、正式收件地址已核發、收文確認已送出或法定送達成立

## 採用的官方語意

依檔案管理局《文書及檔案管理電腦化作業規範》：

- DI（Document Instance）是公文本文 XML。
- EN（Envelop）是記載收發文機關、主旨與檔案清單／雜湊的信封 XML。
- ESW（Encryption Switch）記載收文憑證卡號與加密資訊；它不是本文。
- 交換系統接收文件時應檢核雜湊；同一文書重複收受且雜湊相同時，不再進行後續作業。
- 系統要求包含收文確認訊息、自動狀態顯示、對稱／非對稱式加解密與憑證註冊。這些不能用「App 讀到 XML」代替。

官方參考：

- [文書及檔案管理資訊化法令彙編](https://www.archives.gov.tw/tw/arctw/82-1025.html)
- [文書及檔案管理電腦化作業規範](https://www.archives.gov.tw/tw/arctw/173-1632.html)
- [機關公文電子交換作業辦法](https://www.archives.gov.tw/tw/arctw/155-1741.html)

《機關公文電子交換作業辦法》第十三條另指出，收件人為私人、法人或非法人團體時，機關可依業務需要另訂規定。因此 App 不能自行把「查看」定義為法定收文或送達完成。

## 已實作的資料流

```text
合成 EN／DI／ESW
  → 單檔 2 MiB 上限、拒絕內部 ENTITY、停用外部 entity
  → 解析 EN 的 sender／service ID／application ID／subject／file list
  → 以 EN 所列 SHA-256 比對收到的 DI／ESW
  → 相同 application ID + 相同 EN bytes：冪等，保留第一次時間與已讀狀態
  → 相同 application ID + 不同 EN bytes：拒絕，不覆寫
  → Application Support/OfficialDocumentInbox/packages/<encoded-id>/
     保存原始 EN／DI／ESW 與 metadata.json
  → 本機 unread → viewedLocally
```

任何雜湊不符的套件在寫入前即被拒絕。`viewedLocally` 只描述這支手機的畫面狀態；沒有回傳交換確認訊息，也沒有法定效果。

metadata 刻意不收錄 ESW 的收件憑證卡號或 CipherData。原始 ESW 只留在受 Data Protection 保護、排除備份的 feature archive 內，不經 Files、Quick Look 或分享表單。

## 來源驗證與加密邊界

目前只能證明「收到的 DI／ESW 位元組符合這份 EN 自己列出的雜湊」，不能證明 EN 是哪個機關發出。Phase 2 固定標記 `notVerifiedSynthetic`，UI 同時顯示：

1. 檔案完整性：符合 EN SHA-256。
2. 發文者驗證：未完成，沒有正式地址簿／交換簽章證據。
3. 法定收文回執：未建立，查看不會送出資料。

ESW-only 套件固定進入 `encryptedContentUnavailable`；在官方介接契約、收件憑證與金鑰生命週期確定前，不嘗試以行動自然人憑證的 SIGN 功能冒充解密功能。

## Release signing broker 接點

`SigningBrokerIntent` 已把現有三條簽章路徑收斂成 allowlist：

- `zk_holding_proof_v1`
- `national_id_credential_v1`
- `official_document_inbox_consent_v1`

電子公文 consent intent 傳結構化 version／scope／建立時間／nonce，broker 必須自行重建 TBS；App 不傳任意 digest。`SigningBrokerSignSession` 接回既有 `TWFidOSignSession`，但具體 `SigningBrokerTransport` 仍須完成 App Attest、canonical request assertion、HTTPS、冪等與 broker API，沒有匿名 fallback。

## 下一個完成門檻

1. 取得 G2C／G2B2C 正式介接窗口、現行 DTD／標籤集、測試地址簿與合成測試資格。
2. 釐清私人收件適用的收件地址、同意版本、收文確認時點、撤回與紙本 fallback。
3. 取得 ESW 收件憑證／解密介面規格；確認行動自然人憑證是否提供所需 decrypt 能力。未確認前維持 fail closed。
4. 建立 `bonds-signing-broker` private repo，先完成 App Attest challenge/register/assertion，再接 ATH-01／ATH-02。
5. 用官方 sandbox fixture 驗 DTD、來源簽章、地址簿、雜湊、解密、重複收文、錯投／漏附件與確認訊息；真機完成後才能把 `syntheticFixtureOnly` 擴成新環境。
