//
//  TrustCenterPresentationTests.swift
//  backupTWTests
//

import Testing
import UIKit
@testable import backupTW

@MainActor
@Suite("信任清單狀態圖示")
struct TrustCenterPresentationTests {

    /// 2026-09-02 使用者拍板：官方 API 載到就給綠勾——區塊鏈是加成
    /// （盾牌），不是門檻。一個在官方名單上的發行者，不可以因為鏈上
    /// 查不到或查不了而戴警告色。
    @Test func anAvailableAPIRecordAlwaysGetsThePlainGreenCheck() {
        for state in [TWDIWOnChainVerification?.none, .unavailable, .notAnchored] {
            let appearance = TrustCenterViewController.verificationAppearance(state)
            #expect(appearance.symbol == "checkmark.circle.fill")
            #expect(appearance.colour == .systemGreen)
        }
    }

    @Test func aTwoSourceMatchGetsTheStrongerShield() {
        let verified = TWDIWOnChainVerification.verified(blockNumber: "1", transactionHash: "0x01")
        #expect(TrustCenterViewController.verificationAppearance(verified).symbol == "checkmark.shield.fill")
        #expect(TrustCenterViewController.verificationAppearance(verified).colour == .systemGreen)
    }

    /// 真衝突（API 與鏈上不符）是唯一的紅色——這才是警告色該站的地方。
    @Test func aSourceMismatchNeverLooksSuccessful() {
        #expect(TrustCenterViewController.verificationAppearance(.mismatch).symbol == "exclamationmark.shield.fill")
        #expect(TrustCenterViewController.verificationAppearance(.mismatch).colour == .systemRed)
    }

    /// 曾經的語意 bug：同一個狀態在信任清單與詳情頁戴相反的紅綠燈。
    /// 詳情頁現在委派到同一個對照，這裡鎖住「不可再分岔」這個性質。
    @Test func sandboxStaysAmberAndOffTheGreenPath() {
        let appearance = TrustCenterViewController.verificationAppearance(.developmentSandbox)
        #expect(appearance.symbol == "hammer.fill")
        #expect(appearance.colour == .systemOrange)
    }
}
