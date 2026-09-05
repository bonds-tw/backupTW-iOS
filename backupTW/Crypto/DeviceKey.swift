//
//  DeviceKey.swift
//  backupTW
//

import CryptoKit
import Foundation
import os
import Security

enum DeviceKeyError: Error {
    /// No key could be produced at all. The payload is a diagnostic string from
    /// the Security framework, never key material.
    case unavailable(String)
    case keychain(OSStatus)
    case signFailed(String)
}

/// The long-lived P-256 key that identifies this installation.
///
/// Everything the app issues to the holder — the self-issued national ID
/// credential above all — is signed by this key, and the `did:key` derived from
/// it is the holder's identifier. That makes two properties non-negotiable: the
/// key never leaves the device (no iCloud Keychain, no restore onto a second
/// phone), and it survives every relaunch, because a rotated key silently
/// invalidates every credential already issued.
///
/// "Survives every relaunch" is the whole story only *within one install*. The
/// key must not outlive the app, and that is not something the Keychain does on
/// its own: a Keychain item stays on the device after the app that wrote it is
/// deleted, so a naive `loadOrCreate` hands a reinstalled app the previous
/// install's key and therefore the previous install's `did:key`. That is
/// disqualifying rather than untidy — the whitepaper's §5.2 unlinkability floor
/// says two presentations must not be provably the same holder, and a DID the
/// user cannot change except by erasing the whole phone breaks it. Two things
/// follow, both implemented here: `loadOrCreate` refuses to adopt a key it
/// cannot attribute to the running install (see `installRecord`), and
/// `IdentityReset` gives the user a deliberate way to become someone else.
struct DeviceKey {

    static let defaultTag = "tw.bonds.backupTW.deviceKey"

    /// Where the private key actually lives.
    ///
    /// Worth exposing rather than hiding behind a bool, because which one you get
    /// is not a constant: an Intel simulator has no Enclave and always takes the
    /// software path, an Apple silicon simulator does vend one, and a real phone
    /// that falls back to software has something wrong with it. A caller that
    /// assumed hardware backing would be wrong on the first, right on the second,
    /// and dangerously wrong on the third. Pair with `secureEnclaveIsAvailable`
    /// to tell those apart.
    enum Backing {
        case secureEnclave
        case keychain
    }

    let backing: Backing

    /// Whether this hardware has a Secure Enclave at all.
    ///
    /// The distinction `backing` alone cannot express: software backing on a
    /// simulator is the only thing that *can* happen, while software backing on
    /// an iPhone means the Enclave was there and refused. Reported by CryptoKit
    /// rather than by `#if targetEnvironment(simulator)` because the answer is a
    /// runtime property — simulators on Apple silicon do vend an Enclave, and a
    /// compile-time guess is wrong on exactly the machines developers use.
    static var secureEnclaveIsAvailable: Bool {
        SecureEnclave.isAvailable
    }

    var isHardwareBacked: Bool {
        backing == .secureEnclave
    }

    /// The state the user deserves to be told about: an extractable software key
    /// on a device that was supposed to make extraction impossible.
    ///
    /// This is deliberately a property of the *stored* key rather than of the
    /// generation attempt, so it still answers truthfully on the tenth launch,
    /// long after the fallback that produced it. `hasUnexpectedSoftwareBacking`
    /// on a real phone means the private key sits in the Keychain where a
    /// jailbreak or a Keychain dump can lift it, and every credential it signed
    /// should be understood as forgeable by whoever lifts it.
    var hasUnexpectedSoftwareBacking: Bool {
        backing == .keychain && Self.secureEnclaveIsAvailable
    }

    /// X9.63 uncompressed, `0x04 || X || Y`, 65 bytes.
    ///
    /// Resolved once at load time so that reading it cannot fail later — callers
    /// deriving a DID mid-flow have no useful recovery from "the public key went
    /// away".
    let publicKeyX963: Data

    private let privateKey: SecKey

    /// Serialises the check-then-create window. Two callers racing on first
    /// launch would otherwise each see "no key" and each generate one; the
    /// keychain accepts both (they differ by public key hash) and every
    /// subsequent lookup would return an arbitrary one of the two.
    private static let generationLock = NSLock()

    private static let log = Logger(subsystem: "tw.bonds.backupTW", category: "DeviceKey")

    // MARK: - Lifecycle

    /// Idempotent *within an install*: the first call generates and persists a
    /// key, every later call from the same install returns that same key. A call
    /// from a fresh install discards whatever the Keychain kept and starts over.
    ///
    /// - Parameter installRecord: Where the "this key belongs to the install
    ///   that is running now" marker is kept. `UserDefaults` is not an arbitrary
    ///   choice: it is the store whose lifetime is the one we need to borrow.
    ///   The app container — Preferences included — is destroyed when the user
    ///   deletes the app, while the Keychain item is not, so a missing marker
    ///   beside a present key means exactly one thing, that the key predates
    ///   this install. Pass `nil` to opt out of the check and take the Keychain
    ///   at face value.
    ///
    ///   Nothing is lost by discarding that key. Everything it ever signed lived
    ///   in the app container and went with it, so a surviving key cannot
    ///   restore a single credential — its only remaining power is to prove that
    ///   the person onboarding today is the person who onboarded before. That is
    ///   the property we are trying not to have, which is why this is automatic
    ///   rather than a prompt.
    ///
    ///   The one cost worth naming: `UserDefaults` writes are flushed by the
    ///   system, not synchronously here, so a crash in the moments between
    ///   generating the first key and that flush would make the next launch read
    ///   this install's own key as an orphan and rotate it. The user re-onboards;
    ///   nothing is silently wrong. That failure direction is the deliberate one
    ///   — this marker is allowed to cost an identity, and not allowed to
    ///   preserve one it should have dropped.
    static func loadOrCreate(tag: String = defaultTag,
                             installRecord: UserDefaults? = .standard) throws -> DeviceKey {
        let tagData = Data(tag.utf8)

        generationLock.lock()
        defer { generationLock.unlock() }

        if let existing = try loadPrivateKey(tag: tagData) {
            // No record to consult means the caller opted out, which is the
            // pre-existing "trust the Keychain" behaviour.
            let belongsToThisInstall = installRecord
                .map { $0.bool(forKey: installMarkerKey(tag: tag)) } ?? true
            if belongsToThisInstall {
                return try DeviceKey(privateKey: existing)
            }
            // Orphaned by an app deletion. Destroy it before generating, so the
            // Keychain never holds two keys under this tag and a later lookup
            // cannot resurrect the old identity.
            try deleteKeyLocked(tag: tag, installRecord: installRecord)
        }

        let key = try DeviceKey(privateKey: createPrivateKey(tag: tagData))
        // Marked only after generation succeeded. Marking first would, on a
        // failed generation, leave the next launch believing a stale key was
        // ours — the precise mistake this marker exists to prevent.
        installRecord?.set(true, forKey: installMarkerKey(tag: tag))
        return key
    }

    /// Returns the key this install already owns, or `nil`. **Never creates one.**
    ///
    /// `loadOrCreate` is the wrong call on any path that is *using* an existing
    /// identity rather than establishing one, and presentation is the sharpest
    /// case: a missing install marker makes `loadOrCreate` destroy the stored key
    /// and mint a fresh identity, and it would do that at a verification counter,
    /// one line before the holder-binding check rejects the credential it had
    /// just orphaned. The user would be told their document belongs to an
    /// identifier the device no longer has — while the device was the thing that
    /// threw it away, a second ago, because they tapped 「出示證件」.
    ///
    /// The marker is honoured rather than ignored: a key that predates this
    /// install is reported absent, exactly as `loadOrCreate` treats it, because
    /// answering with it would resurrect the identity an app deletion retired.
    /// The difference is only that this call leaves it alone instead of replacing
    /// it — the caller cannot present anything under it either way, and a screen
    /// that reads state must not rewrite it (the same rule
    /// `DiagnosticsViewController.signingGroup` had to learn).
    ///
    /// Takes `generationLock` so the answer cannot be "no key" because a reset
    /// was halfway through.
    static func load(tag: String = defaultTag,
                     installRecord: UserDefaults? = .standard) throws -> DeviceKey? {
        generationLock.lock()
        defer { generationLock.unlock() }

        guard let existing = try loadPrivateKey(tag: Data(tag.utf8)) else { return nil }
        let belongsToThisInstall = installRecord
            .map { $0.bool(forKey: installMarkerKey(tag: tag)) } ?? true
        guard belongsToThisInstall else { return nil }
        return try DeviceKey(privateKey: existing)
    }

    /// Removes the key. Deleting a key that was never created leaves the device
    /// in the state the caller asked for, so `errSecItemNotFound` is a success.
    ///
    /// Takes the same lock as `loadOrCreate` so that a reset cannot land between
    /// another thread's "no key exists" check and its `SecKeyCreateRandomKey` —
    /// an interleaving that would delete nothing and leave a brand-new key
    /// behind, reporting success while the identity survived.
    static func deleteKey(tag: String, installRecord: UserDefaults? = .standard) throws {
        generationLock.lock()
        defer { generationLock.unlock() }

        try deleteKeyLocked(tag: tag, installRecord: installRecord)
    }

    /// The body of `deleteKey`, for callers that already hold `generationLock`
    /// (`NSLock` is not recursive, so re-entering would deadlock).
    private static func deleteKeyLocked(tag: String, installRecord: UserDefaults?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyError.keychain(status)
        }

        // Clear the marker only once the item is really gone. Clearing it first
        // and then failing the delete would leave a key that this install owns
        // but no longer claims, which the next launch would throw away for the
        // wrong reason.
        installRecord?.removeObject(forKey: installMarkerKey(tag: tag))
    }

    /// Answers "what is protecting the key we already have?" without generating
    /// one and without holding a `DeviceKey`.
    ///
    /// The instance property is useless to the screens that need this: issuance
    /// creates the key deep inside a background closure and drops it, so a
    /// Settings row asking "is this identity hardware-backed?" has nothing to
    /// read. `nil` means no key exists yet, which is a third answer, not an
    /// error — before onboarding there is nothing to characterise.
    static func storedKeyBacking(tag: String = defaultTag) throws -> Backing? {
        generationLock.lock()
        defer { generationLock.unlock() }

        guard let key = try loadPrivateKey(tag: Data(tag.utf8)) else { return nil }
        return backing(of: key)
    }

    /// The static counterpart of `hasUnexpectedSoftwareBacking`, for the same
    /// callers `storedKeyBacking` exists for. `false` when no key exists: a
    /// device that has not onboarded has nothing to warn about.
    static func storedKeyHasUnexpectedSoftwareBacking(tag: String = defaultTag) throws -> Bool {
        try storedKeyBacking(tag: tag) == .keychain && secureEnclaveIsAvailable
    }

    /// Namespaced by tag so the test tags and the shipping tag cannot mark each
    /// other as present.
    private static func installMarkerKey(tag: String) -> String {
        "tw.bonds.backupTW.deviceKey.install.\(tag)"
    }

    private init(privateKey: SecKey) throws {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DeviceKeyError.unavailable("private key has no public key")
        }

        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw DeviceKeyError.unavailable(Self.describe(&error))
        }

        // Security returns X9.63 for EC keys. Assert the shape rather than trust
        // it: `DIDKey` and the JWS header both depend on this being exactly
        // 0x04 || X || Y over P-256.
        guard representation.count == 65, representation.first == 0x04 else {
            throw DeviceKeyError.unavailable("unexpected public key encoding")
        }

        self.privateKey = privateKey
        self.publicKeyX963 = representation
        self.backing = Self.backing(of: privateKey)
    }

    // MARK: - Signing

    /// ECDSA over P-256 with SHA-256, returned as raw `r || s`, 64 bytes.
    ///
    /// - Parameter data: The message to sign — for JOSE that is the ASCII signing
    ///   input `BASE64URL(header) || "." || BASE64URL(payload)`. It is hashed
    ///   here; do not pass a digest.
    ///
    /// The raw form matters: JOSE ES256 (RFC 7518 §3.4) is fixed-width `r || s`,
    /// while `SecKeyCreateSignature` speaks X9.62 DER. Handing the DER blob
    /// straight to a JWS produces a signature that no verifier accepts.
    func signature(for data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCreateSignature(privateKey,
                                              .ecdsaSignatureMessageX962SHA256,
                                              data as CFData,
                                              &error) as Data? else {
            throw DeviceKeyError.signFailed(Self.describe(&error))
        }
        return try Self.rawSignature(fromDER: der)
    }

    /// Converts X9.62 DER (`SEQUENCE { INTEGER r, INTEGER s }`) to JOSE's fixed
    /// 32 + 32 layout.
    ///
    /// Both normalisations here fire on a minority of signatures, which is
    /// exactly why they are easy to miss: DER INTEGERs are signed, so a component
    /// whose top bit is set gains a leading 0x00 (≈50% of the time), and a
    /// component that happens to begin with zero bytes is encoded short (≈1 in
    /// 256). Skipping either produces a signature that verifies almost always.
    static func rawSignature(fromDER der: Data) throws -> Data {
        let bytes = [UInt8](der)
        var index = 0

        func next() throws -> UInt8 {
            guard index < bytes.count else {
                throw DeviceKeyError.signFailed("truncated DER signature")
            }
            defer { index += 1 }
            return bytes[index]
        }

        func length() throws -> Int {
            let first = try next()
            guard first & 0x80 != 0 else { return Int(first) }
            // A P-256 signature is ~70 bytes, so a long form beyond two octets
            // means this is not the structure we think it is.
            let octets = Int(first & 0x7F)
            guard octets >= 1, octets <= 2 else {
                throw DeviceKeyError.signFailed("malformed DER length")
            }
            var value = 0
            for _ in 0..<octets {
                let octet = try next()
                value = value << 8 | Int(octet)
            }
            return value
        }

        func integer() throws -> [UInt8] {
            guard try next() == 0x02 else {
                throw DeviceKeyError.signFailed("expected DER INTEGER")
            }
            let count = try length()
            guard count > 0, index + count <= bytes.count else {
                throw DeviceKeyError.signFailed("truncated DER INTEGER")
            }
            var value = Array(bytes[index..<(index + count)])
            index += count

            while value.first == 0x00 {
                value.removeFirst()
            }
            guard value.count <= 32 else {
                throw DeviceKeyError.signFailed("oversized ECDSA component")
            }
            return [UInt8](repeating: 0, count: 32 - value.count) + value
        }

        guard try next() == 0x30 else {
            throw DeviceKeyError.signFailed("expected DER SEQUENCE")
        }
        let declared = try length()
        guard declared == bytes.count - index else {
            throw DeviceKeyError.signFailed("DER length does not match payload")
        }

        let r = try integer()
        let s = try integer()
        guard index == bytes.count else {
            throw DeviceKeyError.signFailed("trailing bytes after DER signature")
        }
        return Data(r + s)
    }

    // MARK: - Keychain

    private static func loadPrivateKey(tag: Data) throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
                throw DeviceKeyError.keychain(errSecInvalidItemRef)
            }
            return (item as! SecKey)
        case errSecItemNotFound:
            return nil
        default:
            throw DeviceKeyError.keychain(status)
        }
    }

    /// Generation strategies, best first.
    private enum Generation: CaseIterable {
        /// What we actually want: the private key is generated inside the Secure
        /// Enclave and cannot be extracted, only used.
        case secureEnclave
        /// No Enclave (simulator). Same access control, software key.
        case software
        /// `.privateKeyUsage` is documented as an Enclave-only constraint, so a
        /// platform that enforces that literally rejects the previous attempt.
        /// Drop to a plain accessibility attribute, which still pins the key to
        /// this device and this device only.
        case softwareWithoutAccessControl
    }

    private static func createPrivateKey(tag: Data) throws -> SecKey {
        var lastError: Error = DeviceKeyError.unavailable("key generation was not attempted")

        for generation in Generation.allCases {
            do {
                var error: Unmanaged<CFError>?
                let attributes = try attributes(tag: tag, generation: generation)
                guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                    throw DeviceKeyError.unavailable(describe(&error))
                }
                return key
            } catch {
                if generation == .secureEnclave, secureEnclaveIsAvailable {
                    // An Enclave that exists and still refuses is a hardware or
                    // provisioning fault, not a configuration we support. It is
                    // logged as such — at fault level, so it lands in a
                    // sysdiagnose — because the alternative is that the single
                    // most important security property of this app degrades with
                    // no trace anywhere. The payload is the Security framework's
                    // own message; it is marked public because it contains no
                    // key material and no holder data, and a redacted diagnostic
                    // is not a diagnostic.
                    // `String(describing:)` rather than `localizedDescription`:
                    // the localized text is the reassuring sentence we show the
                    // user, which is worthless in a log. This keeps the case and
                    // its diagnostic payload.
                    log.fault("Secure Enclave key generation failed on a device that has one; falling back to a software key: \(String(describing: error), privacy: .public)")
                }
                // Degrade one step rather than fail: a device with no Enclave
                // still needs a working credential, and this is an app for the
                // worst day of someone's life — refusing to issue anything at
                // all would be a worse outcome than issuing something weaker.
                // What must not happen is the weaker outcome being invisible,
                // hence the fault above and `hasUnexpectedSoftwareBacking`.
                lastError = error
            }
        }

        throw lastError
    }

    private static func attributes(tag: Data, generation: Generation) throws -> [String: Any] {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
        ]
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]

        switch generation {
        case .secureEnclave:
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            privateAttributes[kSecAttrAccessControl as String] = try accessControl()
        case .software:
            privateAttributes[kSecAttrAccessControl as String] = try accessControl()
        case .softwareWithoutAccessControl:
            privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        attributes[kSecPrivateKeyAttrs as String] = privateAttributes
        return attributes
    }

    private static func accessControl() throws -> SecAccessControl {
        // `.privateKeyUsage` only, deliberately: no biometry, no passcode prompt.
        // This app is for the day the user is standing in a queue after an
        // earthquake with a cracked screen — a Face ID gate on reading your own
        // ID is a failure mode, not a safeguard. Biometric binding belongs on
        // presentation to a relying party, later.
        //
        // `ThisDeviceOnly` keeps the key out of iCloud Keychain and out of
        // encrypted backups, so a restored phone gets a *new* identity rather
        // than a silent clone of the old one.
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage],
                                                           &error) else {
            throw DeviceKeyError.unavailable(describe(&error))
        }
        return access
    }

    private static func backing(of key: SecKey) -> Backing {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let token = attributes[kSecAttrTokenID as String] as? String,
              token == (kSecAttrTokenIDSecureEnclave as String) else {
            return .keychain
        }
        return .secureEnclave
    }

    private static func describe(_ error: inout Unmanaged<CFError>?) -> String {
        guard let failure = error?.takeRetainedValue() else {
            return "unknown Security framework failure"
        }
        error = nil
        return (failure as Error).localizedDescription
    }
}

// SecKey documents its cryptographic operations as thread-safe, and this value
// exposes only immutable public metadata plus signing. Marking the wrapper lets
// the native proof actor keep all circuit and Secure Enclave work off the main
// actor without making the private key extractable or copying it.
extension DeviceKey: @unchecked Sendable {}

/// Discards this device's identity: the signing key, and everything it signed.
///
/// Why this is its own operation and not what `CredentialStore.deleteAll()` does
/// —
///
/// The two are different requests. "Delete my documents" is a housekeeping act
/// with an obvious sequel: re-issue. Re-issuing under the same `did:key` is not
/// a bug, it is the point — the holder is still the same person and their new
/// credential should chain to the identifier they already showed. "Reset my
/// identity" is the opposite request: make the next credential unattributable to
/// the last one. Folding the second into the first would mean every routine
/// clear-out silently threw away the identifier, and there would then be no way
/// left to express the ordinary case at all. It would also put a Keychain call
/// inside a type whose stated contract is a directory of files, so a store
/// created for tests would delete the real device key.
///
/// The dangerous default is the other way round, and this is the part worth
/// being careful about: a user who taps a button labelled "delete everything"
/// and keeps their DID has been misled. That is a naming and UI obligation on
/// whoever wires this up — a destructive control must say which of the two it
/// does — not a reason to collapse them into one function.
enum IdentityReset {

    /// Key first, then credentials. The order is the whole design.
    ///
    /// Either step can fail (locked Keychain, I/O error) and leave a half-reset
    /// device, so the question is which half-state is survivable:
    ///
    /// - Credentials first: the credentials are gone and the key lives. The next
    ///   launch looks exactly like a fresh install and re-derives the *same*
    ///   DID. Nothing on the device records that a reset was ever attempted, and
    ///   the user has been told they are anonymous while they are not. Silent,
    ///   and precisely the defect this type exists to close.
    /// - Key first: the key is gone and credentials remain. The next launch
    ///   mints a new DID, under which those leftover files are self-evidently
    ///   stale — they name an issuer this device can no longer sign for. Visible,
    ///   and repairable by running the reset again.
    ///
    /// So: key first. The credential sweep then runs unconditionally, because a
    /// Keychain failure is no reason to also keep the files; if both fail the
    /// Keychain error is the one reported, since that is the one that means the
    /// identity survived.
    static func perform(credentialStore: CredentialStoring,
                        keyTag: String = DeviceKey.defaultTag,
                        installRecord: UserDefaults? = .standard) throws {
        var keyFailure: Error?
        do {
            try DeviceKey.deleteKey(tag: keyTag, installRecord: installRecord)
        } catch {
            keyFailure = error
        }

        do {
            try credentialStore.deleteAll()
        } catch {
            if let keyFailure { throw keyFailure }
            throw error
        }

        if let keyFailure { throw keyFailure }
    }
}

extension DeviceKeyError: LocalizedError {

    /// The associated values are diagnostics — an `OSStatus`, a CFError string —
    /// and are deliberately kept out of the user-facing text. Nothing here is
    /// derived from the key or from the holder's data.
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return NSLocalizedString("This device could not create a signing key.", comment: "")
        case .keychain:
            return NSLocalizedString("The device's signing key could not be read.", comment: "")
        case .signFailed:
            return NSLocalizedString("The document could not be signed on this device.", comment: "")
        }
    }
}
