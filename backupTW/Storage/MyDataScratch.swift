//
//  MyDataScratch.swift
//  backupTW
//

import Foundation
import Zip

enum MyDataScratchError: Error, Equatable {
    /// The archive's own table of contents could not be read. Reported rather
    /// than shrugged off: an archive we cannot inspect is an archive we cannot
    /// vouch for, and the only safe thing to do with it is refuse it.
    case unreadableArchive
    /// An entry inside the archive names a path that would put the extracted
    /// file somewhere other than the directory we chose for it.
    case unsafeArchiveEntry(name: String)
    /// The archive unpacked, but did not contain the single PDF we came for.
    case noPDFInArchive
}

/// A quarantine for the plaintext that MyData hands us.
///
/// The MyData flow produces, in order: a zip, a directory unpacked from it, and
/// a PDF of the user's household registration — full name, national ID number,
/// address, household members. That PDF is the most sensitive artefact this app
/// ever touches, more so than the credential `CredentialStore` guards, because
/// the credential is a selective-disclosure document and this is the raw record.
///
/// Two things follow, and this type exists to enforce both.
///
/// **Not Documents.** The app's Documents directory is published to the Files
/// app, so anything written there is browsable, AirDroppable and copyable by
/// anyone holding the unlocked phone, and lands in every iCloud backup. The
/// temporary directory is published to nothing, is excluded from backups by the
/// OS, and is the documented home for files with no reason to outlive the task
/// that made them — which is exactly these.
///
/// **Not for long.** Even quarantined, the plaintext should only exist for the
/// few hundred milliseconds it takes to unpack and read it.
/// `pdfData(fromArchiveAt:)` hands back bytes rather than a URL precisely so the
/// caller can `purge()` before it does anything slow or interactive with them:
/// by the time the app asks the user for their ID number, there is nothing left
/// on disk to protect.
///
/// Nothing here is mutable, so unlike `CredentialStore` this needs no lock to be
/// safe to hand between threads — `purge()` racing a download only ever means
/// the download finds its directory gone and fails, never that half a PDF is
/// left behind.
final class MyDataScratch: Sendable {

    static let directoryName = "MyDataScratch"

    /// The directory this instance owns, and the only place it writes. Exposed
    /// for tests, which must never be pointed at the real scratch location.
    let directory: URL

    /// Not `throws`: constructing one of these is just naming a directory, and
    /// a caller that only wants to `purge()` should not have to handle a failure
    /// to create something it is about to delete. Every method that actually
    /// needs the directory creates it first.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    // MARK: - Handing a destination to WKDownload

    /// Where the MyData zip should land.
    ///
    /// The name is ours, not the server's. `WKDownloadDelegate` offers a
    /// `suggestedFilename` taken from the response's `Content-Disposition`, and
    /// that string is chosen by whoever is on the other end of the connection:
    /// `../../Library/Application Support/Credentials/…` is a legal value for it.
    /// Sanitising it would mean reasoning about every separator, encoding and
    /// normalisation that could survive the trip to the filesystem; generating a
    /// UUID instead means the attacker-controlled string never reaches a path at
    /// all. Nothing is lost — the file is deleted seconds later and never shown
    /// to the user, so its name has no audience.
    ///
    /// The `.zip` extension is not decoration: `Zip.unzipFile` refuses any path
    /// that does not carry a recognised archive extension.
    func downloadDestination() throws -> URL {
        try prepare()
        return directory.appendingPathComponent(UUID().uuidString + ".zip", isDirectory: false)
    }

    // MARK: - Unpacking

    /// Unpacks `archive` and returns the bytes of the PDF inside it.
    ///
    /// Returns `Data` rather than a URL so the plaintext never has to stay on
    /// disk for the caller's benefit; see the type's documentation.
    func pdfData(fromArchiveAt archive: URL) throws -> Data {
        // Before extracting, not after: an entry that escapes has already
        // overwritten whatever it aimed at by the time we could notice.
        try Self.rejectUnsafeEntries(inArchiveAt: archive)

        let destination = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.createProtectedDirectory(at: destination)
        try Zip.unzipFile(archive, destination: destination, overwrite: true, password: nil)

        let contents = try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil)
        guard let pdf = contents.first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
            throw MyDataScratchError.noPDFInArchive
        }
        return try Data(contentsOf: pdf)
    }

    // MARK: - Cleanup

    /// Deletes the zip, the directory it unpacked into and the PDF, in one blow.
    ///
    /// Removing the directory wholesale rather than the files we remember
    /// creating: a download that was interrupted, an extraction that threw
    /// halfway, or a previous run of the app that was killed mid-flow all leave
    /// files whose names we no longer know, and each of them is a complete
    /// household registration record.
    ///
    /// The directory is not recreated afterwards. `deleteAll()` on
    /// `CredentialStore` does recreate, because that store must stay usable; this
    /// one is rebuilt on demand by the next download, and "nothing at all on
    /// disk" is the stronger post-condition to be able to state.
    func purge() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Directory

    private func prepare() throws {
        try Self.createProtectedDirectory(at: directory)
    }

    private static func createProtectedDirectory(at url: URL) throws {
        // `.completeUnlessOpen` (Data Protection class B), matching
        // `CredentialStore`, and for the same reason: class A would refuse to
        // create a file while the screen is locked, and a download can easily
        // still be running when the phone auto-locks. Class B lets the file be
        // created and written while locked but sealed against being read.
        //
        // This has to be set on the directory, not the file: WKDownload and
        // minizip both create their files themselves, with no option for us to
        // pass, and a new file inherits its directory's protection class.
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])

        // The temporary directory is already outside backups, so this is
        // belt-and-braces — but it is one line, it is asserted in tests, and it
        // means the guarantee travels with the directory if anyone ever moves it
        // somewhere that *is* backed up.
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

// MARK: - Archive inspection

extension MyDataScratch {

    /// Throws unless every entry in the archive will land inside the directory
    /// we extract into.
    ///
    /// This is a check the unzip library does not make. `Zip` 2.1.2 builds each
    /// output path as `destination.appendingPathComponent(entryName)` and opens
    /// it with `fopen`, which resolves `..` — so an archive containing an entry
    /// literally named `../../Library/Application Support/Credentials/x.jws`
    /// writes there. That is the classic "zip slip", and the archive here comes
    /// off the network, so we cannot assume it is well-meaning.
    ///
    /// We therefore read the archive's central directory ourselves and refuse
    /// the whole thing if any name looks like an escape, rather than extracting
    /// first and inspecting the damage afterwards.
    static func rejectUnsafeEntries(inArchiveAt url: URL) throws {
        for name in try entryNames(inArchiveAt: url) where !isSafeEntryName(name) {
            throw MyDataScratchError.unsafeArchiveEntry(name: name)
        }
    }

    /// Whether an entry name is one we are willing to extract.
    ///
    /// `Zip` rewrites backslashes to forward slashes before joining the path, so
    /// both count as separators here.
    static func isSafeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\") else { return false }
        let components = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !components.isEmpty else { return false }
        return !components.contains("..")
    }

    /// The names in the archive's central directory.
    ///
    /// The central directory is the right place to read them from: it is the
    /// same table minizip walks when it extracts, so what we vet is what it will
    /// act on, and not the local headers, which a crafted archive can disagree
    /// with.
    ///
    /// Every parse failure is a refusal rather than a best guess. The archive we
    /// expect is a few kilobytes holding one PDF, written by an ordinary server
    /// -side zip library; anything this cannot make sense of — truncation, a
    /// ZIP64 record, deliberate malformation — is not that, and guessing at a
    /// hostile archive's structure is how the check gets bypassed.
    static func entryNames(inArchiveAt url: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw MyDataScratchError.unreadableArchive
        }
        return try entryNames(inArchive: data)
    }

    static func entryNames(inArchive data: Data) throws -> [String] {
        let bytes = [UInt8](data)

        // "End of central directory" record: 22 fixed bytes, then an optional
        // comment of up to 65535. Scan backwards for its signature and accept
        // only a position where the comment length accounts for exactly the rest
        // of the file, so bytes that merely happen to spell the signature (in
        // compressed data, or in a comment) are not mistaken for the real one.
        let trailerSize = 22
        guard bytes.count >= trailerSize else { throw MyDataScratchError.unreadableArchive }

        var trailer: Int?
        let lowest = max(0, bytes.count - trailerSize - 0xFFFF)
        var index = bytes.count - trailerSize
        while index >= lowest {
            if read32(bytes, index) == 0x06054b50,
               index + trailerSize + read16(bytes, index + 20) == bytes.count {
                trailer = index
                break
            }
            index -= 1
        }
        guard let trailer else { throw MyDataScratchError.unreadableArchive }

        let count = read16(bytes, trailer + 10)
        let size = read32(bytes, trailer + 12)
        let offset = read32(bytes, trailer + 16)
        // These sentinels mean "the real value is in a ZIP64 record". We do not
        // read ZIP64, so we stop here rather than parse the placeholder.
        guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else {
            throw MyDataScratchError.unreadableArchive
        }

        let start = Int(offset)
        let end = start + Int(size)
        guard end <= bytes.count else { throw MyDataScratchError.unreadableArchive }

        var names: [String] = []
        var cursor = start
        for _ in 0..<count {
            // 46 fixed bytes per header, then the name, extra field and comment.
            guard cursor + 46 <= end, read32(bytes, cursor) == 0x02014b50 else {
                throw MyDataScratchError.unreadableArchive
            }
            let nameLength = read16(bytes, cursor + 28)
            let extraLength = read16(bytes, cursor + 30)
            let commentLength = read16(bytes, cursor + 32)
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= end else { throw MyDataScratchError.unreadableArchive }

            // Lossy UTF-8 on purpose: bytes that are not valid UTF-8 become
            // U+FFFD, which cannot be mistaken for a separator or for "..", so a
            // name we cannot decode can only ever be rejected, never smuggled
            // past `isSafeEntryName`.
            names.append(String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self))
            cursor = next
        }
        return names
    }

    private static func read16(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }
}
