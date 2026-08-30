//
//  MyDataVaultArchive.swift
//  backupTW
//

import CryptoKit
import Foundation

enum MyDataVaultArchiveError: Error, Equatable {
    /// The identifier was empty or too long to make a filename from.
    case invalidIdentifier
}

/// The persistent, on-device-only home for the **raw original file** MyData hands
/// back for a vault document — kept as evidence (「存證」) rather than destroyed.
///
/// This deliberately reverses, **for vault documents only**, the destroy-everything
/// contract that `MyDataScratch` enforces for the national ID. The holder chose to
/// keep their MyData originals (財力／投保 records) so a self-issued credential can
/// later be checked against — or re-derived from — the file it actually came from.
/// The national ID is *not* archived here: its household-registration PDF still
/// lives and dies inside `MyDataScratch`, because it is the single most sensitive
/// artefact the app touches and nothing asked to keep it.
///
/// Same protection posture as `CredentialStore`, and for the same reasons:
/// - **Application Support**, never Documents (which is published to the Files app).
/// - Data Protection **`.completeUnlessOpen`** (class B): unreadable while locked,
///   but creatable while locked so a write that lands after an auto-lock succeeds.
/// - **Excluded from every backup**, so the raw record never leaves the device.
///
/// Each stored original is paired with a `.meta` sidecar recording the lowercase-hex
/// SHA-256 of the bytes as written, so a later credential can bind to the original
/// by hash and the file can be checked for tampering.
final class MyDataVaultArchive {

    /// What is known about one archived original besides its bytes.
    struct Entry: Codable, Equatable {
        /// Lowercase hex SHA-256 over exactly the bytes stored.
        let sha256: String
        /// The original file's extension (e.g. `zip`, `pdf`), lowercased, for
        /// re-processing later. Empty when the download had none.
        let fileExtension: String
    }

    /// The directory this instance owns. Exposed for tests, which must never be
    /// pointed at the real Application Support location.
    let directory: URL

    private static let maximumIdentifierUTF8Count = 256
    private static let originalExtension = "original"
    private static let metaExtension = "meta"

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? Self.defaultDirectory()
        try prepareDirectory()
    }

    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent("MyDataVaultArchive", isDirectory: true)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = self.directory
        try directory.setResourceValues(values)
    }

    // MARK: - Store / read

    /// Keeps the raw original for a vault document, replacing any earlier one under
    /// the same id, and returns what was recorded about it.
    ///
    /// The bytes are read from `src` and rewritten here under this store's
    /// protection — copying the file item would inherit whatever protection the
    /// download destination had, which is the temporary scratch's, not ours.
    @discardableResult
    func store(originalAt src: URL, id: String, fileExtension: String) throws -> Entry {
        let fileURL = try fileURL(for: id, ext: Self.originalExtension)
        let data = try Data(contentsOf: src)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = Entry(sha256: digest, fileExtension: fileExtension.lowercased())

        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        let metaURL = try self.fileURL(for: id, ext: Self.metaExtension)
        let metaData = try JSONEncoder().encode(entry)
        try metaData.write(to: metaURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        return entry
    }

    /// The URL of the stored original, or `nil` if none is archived for this id.
    func originalURL(id: String) -> URL? {
        guard let url = try? fileURL(for: id, ext: Self.originalExtension),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// What was recorded when the original was stored, or `nil` if none is.
    func entry(id: String) -> Entry? {
        guard let url = try? fileURL(for: id, ext: Self.metaExtension),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func has(id: String) -> Bool { originalURL(id: id) != nil }

    /// Removes the whole archive — every original and its metadata — for the
    /// "erase everything on this phone" path (`LocalDataEraser`). Unlinking the
    /// directory discards the per-file Data Protection keys its contents were
    /// sealed under, so the originals become unrecoverable, not merely unlisted.
    func purge() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Removes the archived original and its metadata for one id. Idempotent: an
    /// already-absent file is the outcome delete promises. Unlinking the file
    /// discards the per-file Data Protection key its contents were sealed under.
    func delete(id: String) throws {
        for ext in [Self.originalExtension, Self.metaExtension] {
            let url = try fileURL(for: id, ext: ext)
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone is success.
            }
        }
    }

    // MARK: - Naming

    /// The identifier is hex-encoded so an id is never itself a path component —
    /// the same discipline `CredentialStore` uses, so the two stores address a
    /// document the same way.
    private func fileURL(for id: String, ext: String) throws -> URL {
        let bytes = Data(id.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumIdentifierUTF8Count else {
            throw MyDataVaultArchiveError.invalidIdentifier
        }
        let name = bytes.map { String(format: "%02x", $0) }.joined() + "." + ext
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
