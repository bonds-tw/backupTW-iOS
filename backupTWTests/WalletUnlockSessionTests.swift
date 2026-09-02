//
//  WalletUnlockSessionTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

@Suite("皮夾解鎖工作階段")
struct WalletUnlockSessionTests {

    @Test func aColdLaunchAlwaysRequiresDeviceOwnerAuthentication() {
        let clock = UptimeStub(100)
        let session = WalletUnlockSession(uptime: { clock.now })

        #expect(session.requiresAuthentication)
    }

    @Test func oneAuthenticationCoversBriefAppSwitchesForTenMinutes() {
        let clock = UptimeStub(100)
        let session = WalletUnlockSession(uptime: { clock.now })
        session.recordAuthentication()

        clock.now = 699.999
        #expect(!session.requiresAuthentication)

        clock.now = 700
        #expect(session.requiresAuthentication)
    }

    @Test func theGracePeriodIsMemoryOnlyAndCanBeInvalidated() {
        let clock = UptimeStub(100)
        let session = WalletUnlockSession(uptime: { clock.now })
        session.recordAuthentication()
        #expect(!session.requiresAuthentication)

        session.invalidate()
        #expect(session.requiresAuthentication)
    }

    @Test func aClockAnomalyCannotExtendAnUnlockedSession() {
        let clock = UptimeStub(100)
        let session = WalletUnlockSession(uptime: { clock.now })
        session.recordAuthentication()

        clock.now = 99
        #expect(session.requiresAuthentication)
    }
}

private final class UptimeStub: @unchecked Sendable {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}
