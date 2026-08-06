//
//  MyDataScratchTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// Every test runs against its own throwaway directory nested one level inside
/// `root`, so "did anything land outside where it was supposed to?" can be
/// answered by listing `root` — which only this test writes to.
///
/// A `final class` suite rather than a struct so `deinit` can clean up; Swift
/// Testing makes a fresh instance per test, so the sandbox is per-test too.
final class MyDataScratchTests: Sendable {

    /// Not a real PDF. Nothing under test parses it — `MyDataScratch` only moves
    /// the bytes, and PDFKit is the view controller's problem.
    private static let pdfBytes = Array("%PDF-1.4 pretend household registration\n%%EOF\n".utf8)

    private let root: URL
    private let directory: URL
    private let scratch: MyDataScratch

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDataScratchTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent(MyDataScratch.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratch = MyDataScratch(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Where the plaintext lives

    /// The defect this type was written for: the download, the unpacked folder
    /// and the decrypted household-registration PDF all went to Documents, which
    /// `UISupportsDocumentBrowser` published to the Files app and which is part
    /// of every iCloud backup.
    @Test func theDefaultLocationIsNotSomewhereTheFilesAppOrABackupCanReach() throws {
        let defaultScratch = MyDataScratch()
        let documents = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)

        #expect(!defaultScratch.directory.standardizedFileURL.path
            .hasPrefix(documents.standardizedFileURL.path))
        #expect(defaultScratch.directory.standardizedFileURL.path
            .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
    }

    /// Merely naming the directory must not create it. The app constructs one of
    /// these on every visit to the MyData screen, including visits where nothing
    /// is ever downloaded, and an empty folder that keeps reappearing is a folder
    /// nobody trusts to be meaningful.
    @Test func constructingOneDoesNotCreateAnythingOnDisk() {
        let unused = root.appendingPathComponent("never-used", isDirectory: true)
        _ = MyDataScratch(directory: unused)

        #expect(!FileManager.default.fileExists(atPath: unused.path))
    }

    @Test func theScratchDirectoryIsExcludedFromBackup() throws {
        _ = try scratch.downloadDestination()

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - Download destination

    /// `WKDownloadDelegate` hands us a `suggestedFilename` chosen by the server.
    /// The destination must not be derived from it — and the way to be sure of
    /// that is that the destination is a fresh UUID inside our own directory,
    /// every time, with no input at all.
    @Test func everyDownloadDestinationIsAFreshFileDirectlyInsideTheScratchDirectory() throws {
        var seen = Set<String>()
        for _ in 0..<20 {
            let destination = try scratch.downloadDestination()
            #expect(destination.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL)
            // Zip refuses to open an archive whose path lacks a known extension.
            #expect(destination.pathExtension == "zip")
            #expect(seen.insert(destination.lastPathComponent).inserted)
        }

        // A destination is a promise, not a file: nothing is written until the
        // download actually lands.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    // MARK: - Unpacking

    @Test func unpackingReturnsThePDFBytesFromInsideTheArchive() throws {
        let archive = try scratch.downloadDestination()
        try ZipFixture.archive(entries: [("household-registration.pdf", Self.pdfBytes)])
            .write(to: archive)

        #expect(try scratch.pdfData(fromArchiveAt: archive) == Data(Self.pdfBytes))
    }

    /// The whole point of returning `Data`: once the caller has the bytes, every
    /// intermediate product — the zip, the folder it unpacked into, and above all
    /// the decrypted PDF — can be gone before the user is even asked for their ID
    /// number. This is the assertion the old code could not have passed: it left
    /// all three in Documents forever.
    @Test func purgingAfterUnpackingLeavesNoTraceOfTheHouseholdRegistration() throws {
        let archive = try scratch.downloadDestination()
        try ZipFixture.archive(entries: [("household-registration.pdf", Self.pdfBytes)])
            .write(to: archive)
        _ = try scratch.pdfData(fromArchiveAt: archive)

        // Before the purge the archive and the unpacked folder are both real.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)

        try scratch.purge()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(Self.files(under: root).isEmpty)
    }

    @Test func purgingSomethingThatIsNotThereIsNotAnError() throws {
        try scratch.purge()
        try scratch.purge()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func anArchiveWithoutAPDFIsRejected() throws {
        let archive = try scratch.downloadDestination()
        try ZipFixture.archive(entries: [("readme.txt", Array("nothing here".utf8))])
            .write(to: archive)

        #expect(throws: MyDataScratchError.noPDFInArchive) {
            _ = try self.scratch.pdfData(fromArchiveAt: archive)
        }
    }

    // MARK: - Hostile archives

    /// `Zip` 2.1.2 joins the entry name onto the destination and opens the result
    /// with `fopen`, which resolves `..` — so without this check an archive from
    /// the network could write anywhere in the app container, including over the
    /// credentials in Application Support.
    @Test(arguments: [
        "../escaped.pdf",
        "../../escaped.pdf",
        "../../../../../../escaped.pdf",
        "sub/../../escaped.pdf",
        "/etc/escaped.pdf",
        "..\\escaped.pdf",
        "..",
    ])
    func archiveEntriesThatWouldEscapeTheDestinationAreRefused(name: String) throws {
        let archive = try scratch.downloadDestination()
        try ZipFixture.archive(entries: [(name, Self.pdfBytes)]).write(to: archive)

        #expect(throws: MyDataScratchError.unsafeArchiveEntry(name: name)) {
            _ = try self.scratch.pdfData(fromArchiveAt: archive)
        }

        // Refused before extraction, not extracted and then tidied up: the only
        // file anywhere under the test root is the archive we planted.
        #expect(Self.files(under: root) == [archive.standardizedFileURL])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.pdf").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.pdf").path))
    }

    /// The check must not be so blunt that it rejects an ordinary archive that
    /// happens to have a folder in it.
    @Test func entriesInTheArchivesOwnSubdirectoriesAreFine() throws {
        let archive = try scratch.downloadDestination()
        try ZipFixture.archive(entries: [
            ("meta/notes.txt", Array("notes".utf8)),
            ("household-registration.pdf", Self.pdfBytes),
        ]).write(to: archive)

        #expect(try scratch.pdfData(fromArchiveAt: archive) == Data(Self.pdfBytes))
    }

    @Test(arguments: [
        "household-registration.pdf",
        "meta/notes.txt",
        "戶籍謄本.pdf",
        "a..b.pdf",
        "...pdf",
        "a/./b.pdf",
    ])
    func ordinaryEntryNamesAreAccepted(name: String) {
        #expect(MyDataScratch.isSafeEntryName(name))
    }

    /// An archive we cannot make sense of is refused rather than guessed at: the
    /// thing we are guarding against is precisely an archive that is not what it
    /// claims to be.
    @Test func anArchiveWhoseTableOfContentsCannotBeReadIsRefused() throws {
        let archive = try scratch.downloadDestination()
        try Data(repeating: 0x41, count: 4096).write(to: archive)

        #expect(throws: MyDataScratchError.unreadableArchive) {
            _ = try self.scratch.pdfData(fromArchiveAt: archive)
        }
    }

    @Test func anArchiveTooShortToHoldATableOfContentsIsRefused() {
        #expect(throws: MyDataScratchError.unreadableArchive) {
            _ = try MyDataScratch.entryNames(inArchive: Data("PK".utf8))
        }
    }

    @Test func aMissingArchiveIsRefused() {
        #expect(throws: MyDataScratchError.unreadableArchive) {
            _ = try MyDataScratch.entryNames(
                inArchiveAt: self.directory.appendingPathComponent("nothing-here.zip"))
        }
    }

    /// Entry names are read from the archive's central directory, which is at the
    /// end of the file behind a variable-length comment. A comment long enough to
    /// contain a decoy signature is the obvious way to confuse that scan.
    @Test func theEntryListIsFoundEvenBehindAnArchiveComment() throws {
        let decoy: [UInt8] = [0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 60)
        let data = ZipFixture.archive(
            entries: [("a.pdf", Self.pdfBytes), ("dir/b.txt", Array("b".utf8))],
            comment: decoy)

        #expect(try MyDataScratch.entryNames(inArchive: data) == ["a.pdf", "dir/b.txt"])
    }
}

// MARK: - Archive fixtures

/// Builds real ZIP archives, byte by byte, because the traversal cases under
/// test cannot be produced by any zip *writer*: an entry named `../escape.pdf`
/// is exactly what a well-behaved library refuses to emit.
///
/// Entries are stored uncompressed with a correct CRC-32, so the archives are
/// valid ones that the app's unzip library will actually open — a fixture that
/// only this file could read would prove nothing about the extraction path.
private enum ZipFixture {

    static func archive(entries: [(name: String, contents: [UInt8])],
                        comment: [UInt8] = []) -> Data {
        var payload: [UInt8] = []
        var central: [UInt8] = []

        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.contents)
            let size = UInt32(entry.contents.count)
            let offset = UInt32(payload.count)

            // Local file header, then the bytes themselves.
            payload += le32(0x04034b50)
            payload += le16(20)            // version needed to extract
            payload += le16(0x800)         // flags: bit 11 says the name is UTF-8
            payload += le16(0)             // method: stored
            payload += le16(0) + le16(0)   // modification time, date
            payload += le32(crc)
            payload += le32(size) + le32(size)
            payload += le16(name.count)
            payload += le16(0)             // extra field length
            payload += name
            payload += entry.contents

            // Central directory header. This is the table both minizip and
            // `MyDataScratch.entryNames` read.
            central += le32(0x02014b50)
            central += le16(20) + le16(20) // version made by, version needed
            central += le16(0x800) + le16(0)
            central += le16(0) + le16(0)
            central += le32(crc)
            central += le32(size) + le32(size)
            central += le16(name.count)
            central += le16(0) + le16(0)   // extra field, file comment
            central += le16(0)             // disk number
            central += le16(0)             // internal attributes
            central += le32(0)             // external attributes: no permissions
            central += le32(offset)
            central += name
        }

        var bytes = payload
        let centralOffset = UInt32(bytes.count)
        bytes += central

        // End of central directory record.
        bytes += le32(0x06054b50)
        bytes += le16(0) + le16(0)         // this disk, disk holding the directory
        bytes += le16(entries.count) + le16(entries.count)
        bytes += le32(UInt32(central.count))
        bytes += le32(centralOffset)
        bytes += le16(comment.count)
        bytes += comment

        return Data(bytes)
    }

    private static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff),
         UInt8((value >> 8) & 0xff),
         UInt8((value >> 16) & 0xff),
         UInt8((value >> 24) & 0xff)]
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Helpers

extension MyDataScratchTests {

    /// Every regular file anywhere beneath `url`, so a test can assert on what
    /// exists rather than on what it remembered to look for.
    static func files(under url: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }

        var found: [URL] = []
        for case let item as URL in walk {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                found.append(item.standardizedFileURL)
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
