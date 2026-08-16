//
//  HolderKeyring.swift
//  backupTW
//
//  One key per card, and a way to find them all again.
//

import CryptoKit
import Foundation
import Security

enum HolderKeyringError: Error, Equatable {
    /// The Keychain is not answering. On a locked device every key in this
    /// namespace is invisible, and an enumeration that returns nothing then is
    /// indistinguishable from an empty namespace — see `destroyAll`.
    case keychainUnavailable
    case keychain(OSStatus)
    /// A sweep finished with keys still in the namespace.
    case sweepIncomplete(remaining: Int)
    /// No key on this device matches the public key the credential is bound to.
    case noKeyForCredential
}

/// Per-credential signing keys, and the only honest way to find them again.
///
/// # What this buys, stated exactly
///
/// **It severs one link and only one: between two different cards.** A verifier
/// who sees card A and a verifier who sees card B cannot tell from the keys that
/// both belong to one person.
///
/// It does **not** make a card unlinkable to its own issuer, and cannot. A
/// TWDIW credential carries `cnf.jwk` — the public key the holder proved
/// possession of during collection — fixed by the issuer at that moment and
/// unchangeable for the life of the card. That is the same key every verifier
/// sees on every presentation. Per-credential keys do not touch this.
///
/// Nor is it the strongest link that exists. A TWDIW driving licence discloses a
/// name and a national ID number; this app's own credential travels with a MOICA
/// certificate whose Subject CN *is* the legal name. **Two cards shown to one
/// verifier are joined by the name before they are ever joined by a key.** Doing
/// the key properly is worth it because it removes an avoidable link, not
/// because it removes the linking.
///
/// Anything on a card face that says 「這張卡與你其他的卡不可連結」 is therefore
/// wrong. What is true: this card will not reveal, through its key, that you
/// hold others.
///
/// # Why enumeration rather than a remembered list
///
/// `IdentityReset` used to delete one known tag. With many keys the obvious
/// replacement is a stored list of the tags we created — and a stored list
/// drifts. A key missing from it can never be deleted, while the person who
/// asked for deletion is told it is gone. This app has shipped that exact defect
/// once already ("身分活得比抹除久").
///
/// So the Keychain is the source of truth. Measured on an iPhone 14 on
/// 2026-08-16, because the design rests on it and nobody had checked:
/// `SecItemCopyMatching` with `kSecMatchLimitAll` returns Secure Enclave keys
/// (`kSecAttrTokenID = com.apple.setoken`), their `kSecAttrApplicationTag` and
/// `kSecAttrCreationDate` both come back, and `SecItemDelete` by
/// `kSecValueRef` removes them. **The simulator answers "yes" to all of that
/// while having no Secure Enclave at all**, which is why the measurement is a
/// device test and says so.
struct HolderKeyring {

    /// Where this keyring's keys live.
    ///
    /// Three namespaces exist under the bundle prefix and they are **mutually
    /// exclusive as strings**, not by convention:
    ///
    ///     tw.bonds.backupTW.key.        this, in production
    ///     tw.bonds.backupTW.tests.      test keys
    ///     tw.bonds.backupTW.selfcheck.  the diagnostics probe
    ///
    /// A single `tw.bonds.backupTW.` prefix with a blacklist would put test keys
    /// inside production's sweep, and Swift Testing runs concurrently — one test
    /// forgetting to inject would delete another's keys, or a developer's real
    /// credential key on the device the tests run on.
    let namespace: String

    /// Tags that predate this scheme and must survive it untouched.
    ///
    /// The self-issued credential already in people's wallets was signed under
    /// `DeviceKey.defaultTag`, and its DID is inside a document that has been
    /// presented. Rotating it would make a verifier's record disagree with the
    /// device, and `VerifiablePresentation`'s holder-binding check would refuse
    /// the app's own card. There is no rename in the Keychain — only delete and
    /// recreate, which is rotation — so the answer is to leave it alone.
    let legacyTags: [String]

    /// Distinguishes keys this install created from ones an app deletion
    /// orphaned, matching `DeviceKey`'s existing marker behaviour.
    let installID: String

    /// The record the **legacy** key was created under.
    ///
    /// `DeviceKey.load` consults an install marker and reports a key absent when
    /// the marker is missing, which is correct — it is how an app deletion
    /// retires an identity. But it means a key created with one record and read
    /// with another is invisible, so the record has to travel with the keyring
    /// rather than be assumed. Production passes `.standard` because that is what
    /// created the key already in people's wallets; tests pass `nil`.
    var legacyInstallRecord: UserDefaults?

    static let productionNamespace = "tw.bonds.backupTW.key."
    static let installIDDefaultsKey = "tw.bonds.backupTW.keyring.installID"

    /// The wiring the app uses. Tests must construct their own.
    static func app(defaults: UserDefaults = .standard) -> HolderKeyring {
        HolderKeyring(namespace: productionNamespace,
                      legacyTags: [DeviceKey.defaultTag],
                      installID: installID(from: defaults),
                      legacyInstallRecord: defaults)
    }

    static func installID(from defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: installIDDefaultsKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(value, forKey: installIDDefaultsKey)
        return value
    }

    // MARK: - What is on the device

    struct Entry: Equatable {
        let tag: String
        let created: Date?
        let backing: DeviceKey.Backing
        let publicKeyX963: Data
        let isLegacy: Bool
        /// False for a key this namespace owns that a previous install created.
        let belongsToThisInstall: Bool
    }

    /// Every key this keyring is responsible for.
    ///
    /// Filtering happens in this process, not in the query: the Keychain only
    /// does equality on `kSecAttrApplicationTag`, so there is no prefix search to
    /// ask for.
    func entries() throws -> [Entry] {
        try Self.allKeys().compactMap { item in
            guard let tag = Self.tag(of: item) else { return nil }
            let isLegacy = legacyTags.contains(tag)
            guard isLegacy || tag.hasPrefix(namespace) else { return nil }
            guard let reference = item[kSecValueRef as String],
                  let publicKey = Self.publicKeyX963(of: reference as! SecKey) else { return nil }
            let tokenID = item[kSecAttrTokenID as String] as? String
            return Entry(
                tag: tag,
                created: item[kSecAttrCreationDate as String] as? Date,
                backing: tokenID == (kSecAttrTokenIDSecureEnclave as String) ? .secureEnclave : .keychain,
                publicKeyX963: publicKey,
                isLegacy: isLegacy,
                belongsToThisInstall: isLegacy || tag.hasPrefix("\(namespace)\(installID)."))
        }
    }

    /// Keys under this app that neither the namespace nor the legacy list claims.
    ///
    /// Reported, never swept. Sweeping would mean an uninjectable delete-by-class
    /// that a misconfigured test could point at a developer's real key.
    ///
    /// The diagnostics and test namespaces are excluded, and that exclusion is
    /// load-bearing rather than tidy: the self-check builds probe keys and any
    /// interruption leaves one behind, so counting them as residue would produce
    /// a permanently red row that the diagnostics screen created itself and the
    /// user cannot clear. A check that is always failing teaches people to ignore
    /// checks.
    func residue() throws -> Int { try residueTags().count }

    /// The tags behind that number.
    ///
    /// Exposed for tests, which cannot use a count: Swift Testing runs
    /// concurrently and another test's sweep creating its erasure probe would
    /// move the total between two reads. Membership is stable; a count is not.
    func residueTags() throws -> [String] {
        let ours = Set(try entries().map(\.tag))
        // Namespaces this app creates on purpose and cleans up itself. Counting
        // them would mean a diagnostics row that goes red because the
        // diagnostics ran — and `erasureprobe` is the sharpest case, because it
        // is created *by the erase* whose result the row is reporting.
        let ownTransient = [
            "tw.bonds.backupTW.selfcheck.",
            "tw.bonds.backupTW.tests.",
            "tw.bonds.backupTW.measurement.",
            "tw.bonds.backupTW.erasureprobe.",
        ]
        return try Self.allKeys().compactMap(Self.tag(of:)).filter { tag in
            guard tag.hasPrefix("tw.bonds.backupTW.") else { return false }
            if ours.contains(tag) { return false }
            return !ownTransient.contains { tag.hasPrefix($0) }
        }
    }

    // MARK: - Making one

    /// A new key under an opaque handle.
    ///
    /// The tag carries no card type, no issuer, no credential identifier.
    /// `kSecAttrApplicationTag` is item metadata, not protected key material —
    /// the same level as `CredentialStore`'s hex file names — so a tag reading
    /// `…key.twdiw.00000000_demo_drivinglicense_…` would announce, to anyone who
    /// can list this app's Keychain items, that its owner holds a government
    /// driving licence. Hashing the credential id would not help: the menu of
    /// configuration ids is public and 882 entries long.
    func newKey() throws -> DeviceKey {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HolderKeyringError.keychainUnavailable
        }
        let handle = bytes.map { String(format: "%02x", $0) }.joined()
        return try DeviceKey.loadOrCreate(tag: "\(namespace)\(installID).\(handle)",
                                          installRecord: nil)
    }

    // MARK: - Finding the right one

    /// The key a credential is bound to, found by its public key.
    ///
    /// No side table mapping credential identifiers to tags: a second record of
    /// the same fact drifts from the first, and the way it shows up is a
    /// presentation signed with a key the verifier will reject. The credential
    /// already states its binding — TWDIW in `cnf.jwk`, this app's own in
    /// `credentialSubject.id` — so the binding is read from the document and
    /// matched against what the device actually holds.
    func key(matchingPublicKeyX963 wanted: Data) throws -> DeviceKey {
        for entry in try entries() where entry.publicKeyX963 == wanted && entry.belongsToThisInstall {
            // `load` returns an optional and can also throw, so the `try?`
            // produces `DeviceKey??`. Flattened rather than force-unwrapped: a
            // key that vanished between enumeration and load is a real race
            // (an erase on another thread), and the honest answer is to keep
            // looking rather than to crash at a counter.
            if let key = (try? DeviceKey.load(tag: entry.tag,
                                              installRecord: entry.isLegacy ? legacyInstallRecord : nil)) ?? nil {
                return key
            }
        }
        throw HolderKeyringError.noKeyForCredential
    }

    // MARK: - Removing all of them

    /// Deletes every key in this namespace, or refuses.
    ///
    /// # The probe, and why it is not paranoia
    ///
    /// All of these keys are `WhenUnlockedThisDeviceOnly`. On a locked device
    /// `SecItemCopyMatching` simply does not see them, so the sweep would
    /// enumerate nothing, delete nothing, verify that nothing remains, and
    /// report success — while credential *files* are `completeUnlessOpen` and do
    /// get deleted. That combination is the exact half-erased state
    /// `IdentityReset`'s own header rejects: the documents gone, the identity
    /// alive, and the user told it was all cleared.
    ///
    /// So a probe key is created and looked for first. Not seeing it means the
    /// Keychain is not readable and nothing here may proceed. The probe is
    /// checked **again after the sweep**, because a device can lock in the
    /// middle: without the second check, a sweep interrupted by the screen
    /// locking ends with an empty enumeration that reads as success.
    @discardableResult
    func destroyAll() throws -> Int {
        try probeKeychainIsReadable()

        var deleted = 0
        for entry in try entries() where !entry.isLegacy {
            if Self.delete(tag: entry.tag) { deleted += 1 }
        }

        // Locked mid-sweep looks identical to finished, so ask again.
        try probeKeychainIsReadable()

        let remaining = try entries().filter { !$0.isLegacy }.count
        guard remaining == 0 else { throw HolderKeyringError.sweepIncomplete(remaining: remaining) }
        return deleted
    }

    /// Creates a throwaway key in its own namespace, confirms it is visible, and
    /// removes it.
    ///
    /// Its own namespace — not `…selfcheck.`, which the diagnostics screen uses —
    /// so that a user tapping "erase everything" and a self-check running cannot
    /// delete each other's probes.
    private func probeKeychainIsReadable() throws {
        let tag = "tw.bonds.backupTW.erasureprobe.\(UUID().uuidString)"
        defer { _ = Self.delete(tag: tag) }
        guard (try? DeviceKey.loadOrCreate(tag: tag, installRecord: nil)) != nil else {
            throw HolderKeyringError.keychainUnavailable
        }
        let visible = try Self.allKeys().compactMap(Self.tag(of:)).contains(tag)
        guard visible else { throw HolderKeyringError.keychainUnavailable }
    }

    // MARK: - Keychain plumbing

    private static func allKeys() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw HolderKeyringError.keychain(status)
        }
        return items
    }

    private static func tag(of item: [String: Any]) -> String? {
        guard let data = item[kSecAttrApplicationTag as String] as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func publicKeyX963(of key: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) else { return nil }
        return data as Data
    }

    @discardableResult
    private static func delete(tag: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
