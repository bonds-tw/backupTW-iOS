# 提案：查驗單一入口（協定層變更，待拍板）

2026-09-02。設計系統 §10.2 把「出示」收成單一入口後，查驗端仍是兩個入口
（查驗他人證件／查驗零知識證明），各出一個語意不同的 QR。UI 層能做的
（全名標題、互斥提示）已做完；真正合併需要動協定，所以停在這份提案。

## 現況為什麼分裂

- 證件查驗：查驗方出示**一次性挑戰 QR**（`PresentationRequest`：nonce、
  目的、藍牙 service UUID），持卡人簽章回應。
- ZK 查驗：查驗方出示**配對 QR**（`ZKLinkEngagement`：只有藍牙位址），
  proof 事先做好、挑戰由持卡人自鑄（`challengeNotBoundToVerifier`）。

兩個 QR 不能直接互換，查驗方必須先知道對方要給哪一種——這正是分裂的根源。

## 提案

`PresentationRequest` 增加一個**選填**欄位 `zkLinkServiceID`（或沿用現有
`linkServiceID` 加類型標記）：

1. 查驗方只開一個「查驗」畫面，出示一張挑戰 QR，同時在藍牙上聽兩種回應
   （既有的 presentation payload、以及 ZK proof package——兩者格式可辨識，
   `ZKPackageVerifier` 與 `OfflineVerifier` 已各自嚴格解析）。
2. 持卡人端不變：出示證件掃到挑戰照舊簽章回應；ZK 傳送掃到同一張 QR 時，
   從 `zkLinkServiceID` 取藍牙位址傳 proof（取代今天要求對方切到另一個
   畫面出示另一張 QR）。
3. 收到哪種回應就渲染哪種判定卡，caveat 照各自路徑（ZK 維持
   `challengeNotBoundToVerifier` 的誠實聲明——挑戰仍未綁定，這個提案
   **不**改變 ZK 的重放性質，只改變「找到對方」的方式）。

## 安全與相容性檢核（實作前需過的清單）

- [ ] 挑戰 QR 增加 ~40 bytes：確認密度仍在現場掃描可靠範圍（現規格 89
      modules／EC Q）。
- [ ] 舊版持卡人掃到新欄位：`PresentationRequest.decode` 對未知欄位的
      行為（應忽略；需測試釘住）。
- [ ] 新版持卡人掃到舊查驗方（無 `zkLinkServiceID`）：ZK 傳送端要有
      明確的「這位查驗方不收 ZK proof」提示，不是沉默。
- [ ] 查驗方同時聽兩個 BT service 的電力與併發（`BluetoothLinkCentral`
      現為單一 service 生命週期）。
- [ ] 一次性挑戰的消費規則：ZK 回應是否消耗挑戰（建議：是，與證件回應
      同一規則，防同場混用）。
- [ ] `UntrustedText`／caveat 排序等安全性質測試延伸到合併畫面。

## 不做的話

維持現狀可接受：兩入口已用全名區分、互斥提示已補。這份提案的價值在
檢查哨場景——查驗方不必預判對方手機上是哪種證明。

拍板選項：A. 照此提案實作（估 2–3 天含安全測試）；B. 維持現狀結案；
C. 只做持卡人端「這位查驗方不收 ZK」提示（半天，無協定變更）。
