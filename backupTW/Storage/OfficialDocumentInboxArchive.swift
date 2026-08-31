//
//  OfficialDocumentInboxArchive.swift
//  backupTW
//

import Foundation

/// An on-device store owned only by the electronic official-document feature.
///
/// It is separate from both `CredentialStore` and `MyDataVaultArchive`: an
/// official document is not a wallet credential, and its delivery evidence must
/// not be mixed with a MyData original. The first slice stores only the signed
/// prototype consent. Government envelopes and delivery receipts belong here
/// later, once an official G2C interface and test fixtures exist.
final class OfficialDocumentInboxArchive {
    let directory: URL

    private static let receiptFilename = "prototype-consent.json"

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? Self.defaultDirectory()
        try prepareDirectory()
    }

    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent("OfficialDocumentInbox", isDirectory: true)
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

    func receipt() throws -> OfficialDocumentInboxReceipt? {
        let url = directory.appendingPathComponent(Self.receiptFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(OfficialDocumentInboxReceipt.self,
                                        from: Data(contentsOf: url))
    }

    func store(_ receipt: OfficialDocumentInboxReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        try data.write(to: directory.appendingPathComponent(Self.receiptFilename),
                       options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func purge() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
