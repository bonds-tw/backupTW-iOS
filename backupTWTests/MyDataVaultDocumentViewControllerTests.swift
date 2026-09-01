//
//  MyDataVaultDocumentViewControllerTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct MyDataVaultDocumentViewControllerTests {

    private func archive() throws -> MyDataVaultArchive {
        try MyDataVaultArchive(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDataVaultDetailTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func source(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    @Test func directPDFPreviewReturnsTheStoredBytes() throws {
        let archive = try archive()
        let pdf = Data("%PDF-1.4 test\n%%EOF\n".utf8)
        try archive.store(originalAt: try source(pdf, ext: "pdf"),
                          id: "mydata-income", fileExtension: "pdf")

        #expect(try MyDataVaultDocumentViewController.previewPDFData(
            id: "mydata-income", archive: archive) == pdf)
    }

    @Test func unsupportedOriginalIsKeptButNotPretendedToBePreviewable() throws {
        let archive = try archive()
        try archive.store(originalAt: try source(Data("{}".utf8), ext: "json"),
                          id: "mydata-income", fileExtension: "json")

        #expect(throws: MyDataVaultPreviewError.unsupportedFormat("json")) {
            try MyDataVaultDocumentViewController.previewPDFData(id: "mydata-income", archive: archive)
        }
        #expect(archive.has(id: "mydata-income"))
    }

    @Test func everyIntegrityStateHasAnHonestDistinctSentence() {
        let states: [MyDataVaultArchive.Integrity] = [.verified, .mismatch, .metadataMissing, .fileMissing]
        let messages = states.map(MyDataVaultDocumentViewController.integrityMessage)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == states.count)
        #expect(messages[1].localizedCaseInsensitiveContains("warning")
                || messages[1].contains("警告"))
    }

    @Test func exportedFilenamesCannotEscapeTheTemporaryDirectory() {
        #expect(MyDataVaultDocumentViewController.safeExportName("../../所得/資料") == "所得資料")
        #expect(MyDataVaultDocumentViewController.safeExportName("///") == "MyData-document")
        #expect(MyDataVaultDocumentViewController.safeFileExtension("PDF") == "pdf")
        #expect(MyDataVaultDocumentViewController.safeFileExtension("../zip") == "zip")
        #expect(MyDataVaultDocumentViewController.safeFileExtension(nil) == "data")
    }
}
