//
//  WalletUnlockSession.swift
//  backupTW
//

import Foundation

/// A short, process-local grace period after device-owner authentication.
///
/// Nothing is persisted: terminating the app always requires a new Face ID,
/// Touch ID, or passcode check. While the process remains alive, brief trips to
/// another app, Control Centre, or the camera do not immediately ask again.
/// `systemUptime` is monotonic, so changing the wall clock cannot extend access.
final class WalletUnlockSession {

    static let defaultLifetime: TimeInterval = 10 * 60

    private let lifetime: TimeInterval
    private let uptime: () -> TimeInterval
    private var authenticatedAt: TimeInterval?

    init(lifetime: TimeInterval = WalletUnlockSession.defaultLifetime,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(lifetime > 0)
        self.lifetime = lifetime
        self.uptime = uptime
    }

    var requiresAuthentication: Bool {
        guard let authenticatedAt else { return true }
        let elapsed = uptime() - authenticatedAt
        return elapsed < 0 || elapsed >= lifetime
    }

    func recordAuthentication() {
        authenticatedAt = uptime()
    }

    func invalidate() {
        authenticatedAt = nil
    }
}
