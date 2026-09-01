//
//  TrustCenterPresentationTests.swift
//  backupTWTests
//

import Testing
@testable import backupTW

@MainActor
@Suite("信任清單狀態圖示")
struct TrustCenterPresentationTests {

    @Test func anAvailableAPIRecordAlwaysGetsThePlainGreenCheck() {
        #expect(TrustCenterViewController.verificationAppearance(nil).symbol == "checkmark.circle.fill")
        #expect(TrustCenterViewController.verificationAppearance(.unavailable).symbol == "checkmark.circle.fill")
        #expect(TrustCenterViewController.verificationAppearance(.notAnchored).symbol == "checkmark.circle.fill")
    }

    @Test func aTwoSourceMatchGetsTheStrongerShield() {
        let verified = TWDIWOnChainVerification.verified(blockNumber: "1", transactionHash: "0x01")
        #expect(TrustCenterViewController.verificationAppearance(verified).symbol == "checkmark.shield.fill")
    }

    @Test func aSourceMismatchNeverLooksSuccessful() {
        #expect(TrustCenterViewController.verificationAppearance(.mismatch).symbol == "exclamationmark.shield.fill")
    }
}
