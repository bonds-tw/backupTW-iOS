//
//  MyDataVaultArchiveTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
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
        #expect(archive.has(id: "mydata-income"))
        #expect(archive.entry(id: "mydata-income") == entry)
        let stored = try #require(archive.originalURL(id: "mydata-income"))
        #expect(try Data(contentsOf: stored) == bytes)
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
