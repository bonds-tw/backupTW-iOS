//
//  CredentialStore.swift
//  backupTW
//

import Foundation

enum CredentialStoreError: Error, Equatable {
    /// The identifier is empty, or too long to survive being encoded into a
    /// file name. Both are programming errors rather than anything the user did.
    case invalidIdentifier
    /// A file exists but its bytes are not valid UTF-8, so it cannot be the
    /// compact JWS we wrote. Reported instead of silently returning nil so the
    /// caller can tell "you never had this credential" from "it is damaged".
    case corruptedCredential(id: String)
}

extension CredentialStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return NSLocalizedString("The credential identifier is not usable.", comment: "")
        case .corruptedCredential:
            return NSLocalizedString("A stored credential is damaged and cannot be read.", comment: "")
        }
    }
}

protocol CredentialStoring {
    func save(jws: String, id: String) throws
    func load(id: String) throws -> String?
    func allIDs() throws -> [String]

    /// Empties the store. Scope is exactly the credentials: the device signing
    /// key is untouched, so credentials issued after this are issued under the
    /// same `did:key` as the ones removed. To become a different holder, see
    /// `IdentityReset`, which does this *and* destroys the key.
    func deleteAll() throws
}

/// On-disk home for issued credentials, one compact JWS per file.
///
/// Not the Keychain, deliberately: a credential is a signed public document of
/// several kilobytes, not a secret, and Keychain items are restored from an
/// iCloud/iTunes backup onto a *different* device and can outlive an app
/// deletion. Both of those defeat the promise this app makes. The Keychain's
/// job in this project is the signing key (see `DeviceKey`); the credential it
/// signed belongs in a file, where Data Protection gives it the same
/// hardware-backed AES and where deleting the file really is the end of it.
///
/// The class is safe to hand between threads: every filesystem call is taken
/// under one lock, so a "delete everything" tap cannot interleave with a
/// credential being written by an in-flight issuance.
final class CredentialStore: CredentialStoring, @unchecked Sendable {

    /// The directory this instance owns. Exposed for tests, which must never be
    /// pointed at the real Application Support directory.
    let directory: URL

    private let lock = NSLock()

    private static let fileExtension = "jws"

    /// APFS caps a file name at 255 UTF-8 bytes. Hex doubles the identifier and
    /// the extension costs four more, so 125 bytes of identifier is the ceiling.
    /// Credential identifiers in this app are short constants or DIDs, nowhere
    /// near this — the check exists so an unexpected identifier fails loudly at
    /// the call site instead of as an errno deep inside Foundation.
    private static let maximumIdentifierUTF8Count = 125

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? Self.defaultDirectory()
        try prepareDirectory()
    }

    // MARK: - Location

    /// Application Support, *not* Documents.
    ///
    /// This target's Info.plist sets `UISupportsDocumentBrowser`, which
    /// publishes the app's Documents directory to the Files app (and, with file
    /// sharing, to Finder). A signed national-ID credential sitting there would
    /// be one long-press away from being copied off the device by anyone holding
    /// the unlocked phone — including at a border or a checkpoint, which is
    /// exactly the moment this app is for. Application Support is not published,
    /// and is Apple's documented home for files the app creates and manages on
    /// the user's behalf.
    ///
    /// Note that iOS does not create Application Support for us the way it
    /// creates Documents, hence `create: true`.
    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent("Credentials", isDirectory: true)
    }

    /// Creates the directory if needed and re-asserts the two properties that
    /// have to hold every launch, not just the first one.
    private func prepareDirectory() throws {
        var directory = self.directory

        // `.completeUnlessOpen` (Data Protection class B) over the two obvious
        // alternatives:
        //
        // - Not `.completeUntilFirstUserAuthentication` (the OS default): that
        //   leaves the file readable from the moment the passcode is entered
        //   once after boot until the next reboot. A phone that has been taken
        //   away from its owner is almost always in exactly that state — powered
        //   on, locked, already unlocked once — so the default protects against
        //   very little of what this app is meant to protect against.
        //
        // - Not `.complete`: class A additionally forbids *creating* a file
        //   while locked. Issuing a credential involves a round trip out to
        //   another app and back, and the screen can auto-lock in the middle of
        //   it; with class A the write that lands on return fails outright. Class
        //   B lets a new file be created while locked (the contents are sealed to
        //   a key only unlocking can recover) and lets an already-open handle
        //   keep writing across a lock.
        //
        // The price is the same for both A and B and is worth naming: while the
        // device is locked, nothing here can be *read*. So there is no lock
        // screen widget and no background presentation of a credential — showing
        // one always costs a Face ID or a passcode first. For an "emergency, show
        // it now" app that is a real cost, and we are accepting it, because the
        // failure it prevents (a seized locked phone yielding a full national-ID
        // record) is worse than the friction it adds.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])

        // Excluding the directory excludes everything under it, so this does not
        // need repeating per file. If it fails we refuse to construct the store
        // at all: quietly syncing an identity credential to iCloud is worse than
        // the feature being unavailable, and this app's whole claim is that the
        // data stays on the phone.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    // MARK: - CredentialStoring

    func save(jws: String, id: String) throws {
        let url = try fileURL(for: id)

        lock.lock()
        defer { lock.unlock() }

        // `.atomic` gives overwrite-in-place semantics: a second save for the
        // same identifier either fully replaces the old credential or leaves it
        // untouched, never a half-written file that fails to verify.
        try Data(jws.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func load(id: String) throws -> String? {
        let url = try fileURL(for: id)

        lock.lock()
        defer { lock.unlock() }

        do {
            let data = try Data(contentsOf: url)
            guard let jws = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.corruptedCredential(id: id)
            }
            return jws
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Only a genuinely absent file becomes nil. Anything else — most
            // importantly "the device is locked so this file is unreadable" —
            // propagates, because reporting that as "you have no credential"
            // would send the user off to re-issue one they already hold.
            return nil
        }
    }

    func allIDs() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        // Anything that does not decode is not ours; skip it rather than fail
        // the whole listing over one stray file.
        return names.compactMap(Self.identifier(fromFileName:)).sorted()
    }

    /// The protection class the filesystem actually reports for a stored
    /// credential, or nil if there is no such credential.
    ///
    /// This exists because the diagnostics screen used to work the path out for
    /// itself — `directory` plus the identifier — and identifiers are not
    /// filenames. `fileURL(for:)` hex-encodes them, so the screen was reading
    /// the attributes of a path that does not exist, getting nothing back, and
    /// reporting on real hardware that the user's credential was stored
    /// unprotected. It was not; the check was wrong.
    ///
    /// A self-check that raises a false alarm is worse than one that is absent,
    /// because it sends whoever reads it to repair something that works. So the
    /// encoding stays private and the answer comes from the type that owns it.
    func reportedFileProtection(for id: String) throws -> FileProtectionType? {
        let url = try fileURL(for: id)

        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.protectionKey] as? FileProtectionType
    }

    /// Removes every credential. Deliberately *not* an identity reset — this
    /// clears what the device signed, not what it signs with, and the `did:key`
    /// a re-issued credential carries afterwards is the one it carried before.
    ///
    /// The separation is a layering decision as much as a product one. This type
    /// owns a directory; reaching into the Keychain from here would mean a store
    /// pointed at a temporary directory (every test constructs one) could delete
    /// the real device key as a side effect of cleaning up after itself.
    /// `IdentityReset` composes the two instead, in the order that makes a
    /// partial failure visible.
    func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }

        // Removing the directory wholesale rather than walking it: that also
        // takes any temp file an interrupted atomic write left behind, which a
        // "*.jws" sweep would miss and which can hold a complete credential.
        //
        // We do not overwrite the bytes first. On flash the controller is free
        // not to reuse the same cells, so zeroing is theatre. What actually makes
        // this unrecoverable is Data Protection: the contents are encrypted under
        // a per-file key kept in the file's own metadata, and unlinking the file
        // discards that key.
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }

        // Rebuild it immediately so the store stays usable — and so the backup
        // exclusion, which lived on the directory we just deleted, comes back.
        try prepareDirectory()
    }

    // MARK: - Identifier ↔ file name

    /// Maps an identifier onto a file inside `directory`.
    ///
    /// The identifier is hex-encoded rather than sanitised. Blocklisting "../"
    /// and friends means reasoning about every escape a caller might spell —
    /// separators, "....//", NUL truncation, Unicode that normalises into a
    /// separator on the way to the filesystem. Encoding sidesteps all of it: the
    /// output alphabet is `[0-9a-f]` plus a fixed extension, so a path separator
    /// is not representable and traversal cannot be expressed at all. It is also
    /// reversible, which `allIDs()` needs, and single-case, so two identifiers
    /// can never collide into one file on a case-insensitive volume.
    private func fileURL(for id: String) throws -> URL {
        let bytes = Data(id.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumIdentifierUTF8Count else {
            throw CredentialStoreError.invalidIdentifier
        }
        let name = Self.encodeHex(bytes) + "." + Self.fileExtension
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func identifier(fromFileName name: String) -> String? {
        let suffix = "." + fileExtension
        guard name.hasSuffix(suffix) else { return nil }
        let hex = String(name.dropLast(suffix.count))
        guard let bytes = decodeHex(hex) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private static func encodeHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase only, to match `encodeHex`. Being strict here means a file we
    /// did not write is ignored rather than decoded into a second alias for an
    /// identifier we already hold.
    private static func decodeHex(_ string: String) -> Data? {
        let characters = Array(string.utf8)
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }

        var data = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]),
                  let low = nibble(characters[index + 1]) else { return nil }
            data.append((high << 4) | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }
}
