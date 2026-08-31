//
//  WalletIdentity.swift
//  backupTW
//

import Foundation

/// The installation-level identity of 有備而來 itself.
///
/// This is deliberately not a credential key. A national-ID card and every
/// collected TWDIW card each use their own key, so showing one card does not
/// reveal the identifier shown by another. The wallet identity is for places
/// where the app installation itself needs to be named (diagnostics, future
/// wallet-to-wallet relationships, and an explicit user-visible identity page).
enum WalletIdentity {

    static let keyTag = "tw.bonds.backupTW.walletIdentityKey"

    static func key(defaults: UserDefaults = .standard) throws -> DeviceKey {
        try DeviceKey.loadOrCreate(tag: keyTag, installRecord: defaults)
    }

    static func existingKey(defaults: UserDefaults = .standard) throws -> DeviceKey? {
        try DeviceKey.load(tag: keyTag, installRecord: defaults)
    }

    static func did(defaults: UserDefaults = .standard) throws -> String {
        try DIDKey.did(fromP256PublicKeyX963: key(defaults: defaults).publicKeyX963)
    }
}
