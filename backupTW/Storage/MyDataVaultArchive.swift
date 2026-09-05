//
//  MyDataVaultArchive.swift
//  backupTW
//

import CryptoKit
import Foundation
import PDFKit

enum MyDataVaultArchiveError: Error, Equatable {
    /// The identifier was empty or too long to make a filename from.
    case invalidIdentifier
}

/// The persistent, on-device-only home for the **raw original file** MyData hands
/// back for a vault document — kept as evidence (「存證」) rather than destroyed.
///
/// This deliberately reverses, **for vault documents only**, the destroy-everything
/// contract that `MyDataScratch` enforces for the national ID. The holder chose to
/// keep their MyData originals (財力／投保 records) so they can reopen the
/// agency-produced document itself and verify that its bytes have not changed.
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
        /// When this phone imported/replaced the original. Optional so metadata
        /// written by the first vault build (which had only the two fields above)
        /// continues to decode instead of making a stored document disappear.
        let importedAt: Date?
        /// Human-readable document kind for imports that did not come through
        /// the small shortcut registry. Optional for every older sidecar.
        let displayName: String?

        init(sha256: String, fileExtension: String, importedAt: Date? = Date(),
             displayName: String? = nil) {
            self.sha256 = sha256
            self.fileExtension = fileExtension
            self.importedAt = importedAt
            self.displayName = displayName
        }
    }

    /// One original that is actually present in the archive.
    ///
    /// The filename is the durable index. `entry` is optional because a crash
    /// after the original's atomic write but before the metadata write — or an
    /// older damaged sidecar — must not turn the most sensitive file into an
    /// invisible orphan the holder cannot inspect or delete.
    struct Document: Equatable {
        let id: String
        let entry: Entry?
        /// Filesystem fallback for metadata created before `importedAt` existed.
        let fileModifiedAt: Date?

        var importedAt: Date? { entry?.importedAt ?? fileModifiedAt }
    }

    enum Integrity: Equatable {
        case verified
        case mismatch
        case metadataMissing
        case fileMissing
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
    func store(originalAt src: URL, id: String, fileExtension: String,
               displayName: String? = nil) throws -> Entry {
        try store(data: Data(contentsOf: src), id: id,
                  fileExtension: fileExtension, displayName: displayName)
    }

    /// Stores already-normalised bytes. MyData commonly wraps one PDF in a ZIP;
    /// callers can safely unpack that quarantine and keep the PDF rather than the
    /// transport wrapper. CSV-only items may still retain their original format.
    @discardableResult
    func store(data: Data, id: String, fileExtension: String,
               displayName: String? = nil) throws -> Entry {
        let fileURL = try fileURL(for: id, ext: Self.originalExtension)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = Entry(sha256: digest, fileExtension: fileExtension.lowercased(),
                          displayName: displayName)

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

    /// Every original this archive currently holds, including one whose metadata
    /// cannot be decoded. The original files are enumerated rather than the
    /// sidecars: a metadata-only remnant contains no personal document, while an
    /// original-only remnant is exactly the thing the UI must never hide.
    func documents() throws -> [Document] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])

        return urls.compactMap { url -> Document? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                            .isRegularFileKey])
            guard url.pathExtension == Self.originalExtension,
                  let id = Self.identifier(fromEncodedFilename: url.deletingPathExtension().lastPathComponent),
                  values?.isRegularFile == true else {
                return nil
            }
            return Document(id: id, entry: entry(id: id), fileModifiedAt: values?.contentModificationDate)
        }.sorted { left, right in
            if left.importedAt != right.importedAt {
                return (left.importedAt ?? .distantPast) > (right.importedAt ?? .distantPast)
            }
            return left.id < right.id
        }
    }

    /// Repairs the neutral title used by the first Personal-documents importer.
    /// Identification stays entirely on-device: only page one of an already
    /// stored PDF is inspected, no text is logged or retained, and metadata is
    /// rewritten only when it maps to the bounded registry above. A successful
    /// repair is naturally one-shot because the display name stops being generic.
    @discardableResult
    func repairGenericDisplayNames() throws -> Int {
        let genericTitles: Set<String> = [
            "MyData document",
            "MyData 文件",
            NSLocalizedString("MyData document", comment: "generic MyData document"),
        ]
        var repaired = 0
        for document in try documents() {
            guard let entry = document.entry,
                  entry.fileExtension.lowercased() == "pdf",
                  entry.displayName.map(genericTitles.contains) == true,
                  let original = originalURL(id: document.id),
                  let pdf = PDFDocument(url: original),
                  let heading = pdf.page(at: 0)?.string,
                  let type = MyDataDocumentRegistry.knownDocument(in: heading) else { continue }

            let updated = Entry(sha256: entry.sha256,
                                fileExtension: entry.fileExtension,
                                importedAt: entry.importedAt,
                                displayName: type.title)
            let metaURL = try fileURL(for: document.id, ext: Self.metaExtension)
            try JSONEncoder().encode(updated).write(
                to: metaURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            repaired += 1
        }
        return repaired
    }

    /// Recomputes the fingerprint over the bytes currently stored. This is done
    /// only on the detail screen, never while building Home: a MyData PDF can be
    /// large, and opening the wallet must not hash every document before drawing.
    func integrity(id: String) throws -> Integrity {
        guard let original = originalURL(id: id) else { return .fileMissing }
        guard let entry = entry(id: id) else { return .metadataMissing }

        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == entry.sha256 ? .verified : .mismatch
    }

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

    /// Inverse of `fileURL`'s hex encoding, used only for files already inside
    /// this archive. A malformed or non-UTF-8 name is ignored rather than turned
    /// into a path or a UI string.
    private static func identifier(fromEncodedFilename value: String) -> String? {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let id = String(bytes: bytes, encoding: .utf8),
              !id.isEmpty, id.utf8.count <= maximumIdentifierUTF8Count else { return nil }
        return id
    }
}
