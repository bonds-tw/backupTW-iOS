//
//  MyDataVaultArchiveTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
import UIKit
@testable import backupTW

/// Each test points the archive at its own temporary directory — never the real
/// Application Support location, which belongs to whoever runs the suite.
struct MyDataVaultArchiveTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeSource(_ bytes: Data, ext: String = "zip") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try bytes.write(to: url)
        return url
    }

    private func hex(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test func storesAndReadsBackTheOriginalWithItsHash() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        let bytes = Data("PK the raw income zip".utf8)
        let src = try writeSource(bytes)

        let entry = try archive.store(originalAt: src, id: "mydata-income", fileExtension: "zip")

        #expect(entry.fileExtension == "zip")
        #expect(entry.sha256 == hex(of: bytes))
        #expect(entry.importedAt != nil)
        #expect(archive.has(id: "mydata-income"))
        #expect(archive.entry(id: "mydata-income") == entry)
        let stored = try #require(archive.originalURL(id: "mydata-income"))
        #expect(try Data(contentsOf: stored) == bytes)
    }

    @Test func storesNormalizedPDFBytesWithAGenericDisplayName() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        let bytes = Data("%PDF normalized".utf8)
        let entry = try archive.store(data: bytes, id: "mydata-file-example",
                                      fileExtension: "pdf", displayName: "MyData 文件")

        #expect(entry.fileExtension == "pdf")
        #expect(entry.displayName == "MyData 文件")
        #expect(entry.sha256 == hex(of: bytes))
        #expect(try Data(contentsOf: #require(archive.originalURL(id: "mydata-file-example"))) == bytes)
    }

    @Test func officialIncomeNamesResolveToTheIncomeDocument() {
        #expect(MyDataDocumentRegistry.knownDocument(in: "個人所得資料表_20260901.pdf")?.id
                == "mydata-income")
        #expect(MyDataDocumentRegistry.knownDocument(in: "download_API.syWqjr4flJ.zip")?.id
                == "mydata-income")
        #expect(MyDataDocumentRegistry.knownDocument(in: "王小明的普通檔案.pdf") == nil)
    }

    @MainActor
    @Test func repairsAnOlderGenericIncomeTitleFromTheStoredPDF() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480))
        let pdf = renderer.pdfData { context in
            context.beginPage()
            ("個人所得資料表" as NSString).draw(
                at: CGPoint(x: 24, y: 24),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        try archive.store(data: pdf, id: "mydata-file-older",
                          fileExtension: "pdf", displayName: "MyData 文件")

        #expect(try archive.repairGenericDisplayNames() == 1)
        #expect(archive.entry(id: "mydata-file-older")?.displayName
                == MyDataDocumentRegistry.lookup(id: "mydata-income")?.title)
        #expect(try archive.repairGenericDisplayNames() == 0,
                "a repaired title should not re-open the PDF on every Home visit")
    }

    @Test func listsStoredOriginalsWithoutNeedingCredentialStoreRows() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        try archive.store(originalAt: try writeSource(Data("income".utf8)),
                          id: "mydata-income", fileExtension: "zip")
        try archive.store(originalAt: try writeSource(Data("land".utf8)),
                          id: "mydata-land", fileExtension: "pdf")

        let documents = try archive.documents()
        #expect(Set(documents.map(\.id)) == ["mydata-income", "mydata-land"])
        #expect(documents.allSatisfy { $0.entry != nil })
        #expect(documents.allSatisfy { $0.importedAt != nil })
    }

    @Test func anOriginalWithBrokenMetadataStaysVisibleAndDeletable() throws {
        let dir = tempDirectory()
        let archive = try MyDataVaultArchive(directory: dir)
        try archive.store(originalAt: try writeSource(Data("income".utf8)),
                          id: "mydata-income", fileExtension: "zip")
        let metadata = try #require(FileManager.default.contentsOfDirectory(at: dir,
                                                                             includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "meta" })
        try Data("not json".utf8).write(to: metadata)

        let document = try #require(archive.documents().first)
        #expect(document.id == "mydata-income")
        #expect(document.entry == nil)
        #expect(try archive.integrity(id: document.id) == .metadataMissing)

        try archive.delete(id: document.id)
        #expect(try archive.documents().isEmpty)
    }

    @Test func verifiesAndDetectsChangedOriginalBytes() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        try archive.store(originalAt: try writeSource(Data("original".utf8)),
                          id: "mydata-income", fileExtension: "pdf")
        #expect(try archive.integrity(id: "mydata-income") == .verified)

        let stored = try #require(archive.originalURL(id: "mydata-income"))
        try Data("changed".utf8).write(to: stored)
        #expect(try archive.integrity(id: "mydata-income") == .mismatch)
    }

    @Test func metadataFromTheFirstVaultVersionStillDecodes() throws {
        let dir = tempDirectory()
        let archive = try MyDataVaultArchive(directory: dir)
        try archive.store(originalAt: try writeSource(Data("old".utf8)),
                          id: "mydata-income", fileExtension: "zip")
        let metadata = try #require(FileManager.default.contentsOfDirectory(at: dir,
                                                                             includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "meta" })
        let legacy = "{\"sha256\":\"\(hex(of: Data("old".utf8)))\",\"fileExtension\":\"zip\"}"
        try Data(legacy.utf8).write(to: metadata)

        let document = try #require(archive.documents().first)
        #expect(document.entry?.fileExtension == "zip")
        #expect(document.entry?.importedAt == nil)
        #expect(document.importedAt != nil) // filesystem fallback
        #expect(try archive.integrity(id: document.id) == .verified)
    }

    @Test func storeReplacesAnEarlierOriginalUnderTheSameID() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        try archive.store(originalAt: try writeSource(Data("old".utf8)), id: "mydata-health-insurance", fileExtension: "zip")
        let newBytes = Data("new and different".utf8)
        let entry = try archive.store(originalAt: try writeSource(newBytes), id: "mydata-health-insurance", fileExtension: "pdf")

        #expect(entry.sha256 == hex(of: newBytes))
        #expect(entry.fileExtension == "pdf")
        let stored = try #require(archive.originalURL(id: "mydata-health-insurance"))
        #expect(try Data(contentsOf: stored) == newBytes)
    }

    @Test func keysAreIsolatedFromEachOther() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        try archive.store(originalAt: try writeSource(Data("income".utf8)), id: "mydata-income", fileExtension: "zip")
        try archive.store(originalAt: try writeSource(Data("land".utf8)), id: "mydata-land", fileExtension: "zip")

        #expect(try Data(contentsOf: #require(archive.originalURL(id: "mydata-income"))) == Data("income".utf8))
        #expect(try Data(contentsOf: #require(archive.originalURL(id: "mydata-land"))) == Data("land".utf8))
    }

    @Test func deleteRemovesTheOriginalAndItsMetadata() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        try archive.store(originalAt: try writeSource(Data("x".utf8)), id: "mydata-income", fileExtension: "zip")
        #expect(archive.has(id: "mydata-income"))

        try archive.delete(id: "mydata-income")

        #expect(!archive.has(id: "mydata-income"))
        #expect(archive.entry(id: "mydata-income") == nil)
        #expect(archive.originalURL(id: "mydata-income") == nil)
        // Idempotent.
        try archive.delete(id: "mydata-income")
    }

    @Test func purgeRemovesEverythingIncludingTheDirectory() throws {
        let dir = tempDirectory()
        let archive = try MyDataVaultArchive(directory: dir)
        try archive.store(originalAt: try writeSource(Data("a".utf8)), id: "mydata-income", fileExtension: "zip")
        try archive.store(originalAt: try writeSource(Data("b".utf8)), id: "mydata-land", fileExtension: "zip")

        try archive.purge()

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Purging an already-gone archive is fine.
        try archive.purge()
    }

    @Test func anAbsentIDReadsAsNothing() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        #expect(!archive.has(id: "mydata-income"))
        #expect(archive.originalURL(id: "mydata-income") == nil)
        #expect(archive.entry(id: "mydata-income") == nil)
    }

    @Test func anEmptyIdentifierIsRejected() throws {
        let archive = try MyDataVaultArchive(directory: tempDirectory())
        #expect(throws: MyDataVaultArchiveError.invalidIdentifier) {
            try archive.store(originalAt: try writeSource(Data("x".utf8)), id: "", fileExtension: "zip")
        }
    }
}
