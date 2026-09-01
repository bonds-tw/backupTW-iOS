//
//  OfficialDocumentInboxArchive.swift
//  backupTW
//

import Foundation

enum OfficialDocumentInboxArchiveError: Error, Equatable {
    case invalidIdentifier
    case conflictingApplicationID(String)
    case packageMissing
    case consentAlreadySigned
    case physicalCardRequestMissing
    case physicalCardResponseMissing
}

extension OfficialDocumentInboxArchiveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return NSLocalizedString("The electronic official document identifier is invalid.", comment: "official document inbox")
        case .conflictingApplicationID:
            return NSLocalizedString("A package with the same application ID but different bytes is already stored. The new package was refused.", comment: "official document inbox")
        case .packageMissing:
            return NSLocalizedString("This electronic official document is no longer stored on this phone.", comment: "official document inbox")
        case .consentAlreadySigned:
            return NSLocalizedString("A verified prototype consent is already stored. Review or remove it before starting another signing request.", comment: "official document inbox")
        case .physicalCardRequestMissing:
            return NSLocalizedString("Create a new physical-card signing request on this iPhone first.", comment: "official document inbox")
        case .physicalCardResponseMissing:
            return NSLocalizedString("The Mac has not returned a physical-card signing result to this iPhone yet.", comment: "official document inbox")
        }
    }
}

/// An on-device store owned only by the electronic official-document feature.
///
/// It is separate from both `CredentialStore` and `MyDataVaultArchive`: an
/// official document is not a wallet credential, and its delivery evidence must
/// not be mixed with a MyData original. This phase also stores synthetic source
/// packages for end-to-end product testing; official exchange envelopes and
/// delivery receipts still require a government G2C interface and test fixtures.
final class OfficialDocumentInboxArchive {
    typealias ReceiptVerifier = (OfficialDocumentInboxReceipt) throws -> Void

    let directory: URL
    private let verifyReceipt: ReceiptVerifier

    private static let receiptFilename = "prototype-consent.json"
    private static let physicalCardRequestFilename = "physical-card-request.json"
    private static let physicalCardResponseFilename = "physical-card-response.json"
    private static let packagesDirectoryName = "packages"
    private static let metadataFilename = "metadata.json"
    private static let envelopeFilename = "source.en"
    private static let documentFilename = "source.di"
    private static let encryptedSwitchFilename = "source.esw"
    private static let maximumIdentifierUTF8Count = 256

    init(directory: URL? = nil,
         verifyReceipt: @escaping ReceiptVerifier = { try $0.verify() }) throws {
        self.directory = try directory ?? Self.defaultDirectory()
        self.verifyReceipt = verifyReceipt
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
        let receipt = try JSONDecoder().decode(OfficialDocumentInboxReceipt.self,
                                               from: Data(contentsOf: url))
        try verifyReceipt(receipt)
        return receipt
    }

    func store(_ receipt: OfficialDocumentInboxReceipt) throws {
        // A UI or future transport must not be able to bypass the receipt
        // factory and make arbitrary decoded JSON appear as signed evidence.
        try verifyReceipt(receipt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        try data.write(to: directory.appendingPathComponent(Self.receiptFilename),
                       options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Removes only the on-device prototype certificate and signature. No
    /// official inbox exists in this phase, and this method deliberately does
    /// not claim to revoke a Ministry of the Interior service record or a future
    /// government receiving address.
    func removeReceipt() throws {
        let url = directory.appendingPathComponent(Self.receiptFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try removePhysicalCardSigningArtifacts()
    }

    // MARK: - Development physical-card signing hand-off

    /// Writes a fresh identity-free request into Application Support so the
    /// development Mac helper can pull it over the paired-device USB channel.
    /// No Files/iCloud export and no national ID number are involved.
    @discardableResult
    func preparePhysicalCardSigningRequest() throws
        -> OfficialDocumentPhysicalCardSigningRequest {
        guard try receipt() == nil else {
            throw OfficialDocumentInboxArchiveError.consentAlreadySigned
        }
        try removePhysicalCardSigningArtifacts()
        let request = OfficialDocumentPhysicalCardSigningRequest(
            consent: try OfficialDocumentInboxConsent.make())
        try writeJSON(request, filename: Self.physicalCardRequestFilename)
        return request
    }

    func physicalCardSigningRequest() throws
        -> OfficialDocumentPhysicalCardSigningRequest? {
        let url = directory.appendingPathComponent(Self.physicalCardRequestFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = try JSONDecoder().decode(
            OfficialDocumentPhysicalCardSigningRequest.self,
            from: Data(contentsOf: url))
        _ = try request.validatedConsent(at: Date())
        return request
    }

    var hasPhysicalCardSigningResponse: Bool {
        FileManager.default.fileExists(atPath: directory
            .appendingPathComponent(Self.physicalCardResponseFilename).path)
    }

    /// Imports only a response for the exact pending request, then performs the
    /// same MOICA G3 chain and RSA signature verification as the mobile route.
    /// The response is never accepted merely because JSON decoding succeeded.
    @discardableResult
    func importPhysicalCardSigningResponse(
        makeReceipt: OfficialDocumentPhysicalCardSigningResponse.ReceiptFactory = {
            consent, certificate, signature, signedAt in
            try OfficialDocumentInboxReceipt.issue(
                consent: consent,
                certificate: certificate,
                signature: signature,
                signingChannel: .physicalNaturalPersonCertificate,
                now: signedAt)
        })
        throws -> OfficialDocumentInboxReceipt {
        guard try receipt() == nil else {
            throw OfficialDocumentInboxArchiveError.consentAlreadySigned
        }
        guard let request = try physicalCardSigningRequest() else {
            throw OfficialDocumentInboxArchiveError.physicalCardRequestMissing
        }
        let responseURL = directory.appendingPathComponent(Self.physicalCardResponseFilename)
        guard FileManager.default.fileExists(atPath: responseURL.path) else {
            throw OfficialDocumentInboxArchiveError.physicalCardResponseMissing
        }
        let response = try JSONDecoder().decode(
            OfficialDocumentPhysicalCardSigningResponse.self,
            from: Data(contentsOf: responseURL))
        let receipt = try response.issueReceipt(matching: request,
                                                makeReceipt: makeReceipt)
        try store(receipt)
        try removePhysicalCardSigningArtifacts()
        return receipt
    }

    func removePhysicalCardSigningArtifacts() throws {
        for filename in [Self.physicalCardRequestFilename,
                         Self.physicalCardResponseFilename] {
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(
            to: directory.appendingPathComponent(filename),
            options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    // MARK: - Synthetic EN / DI / ESW packages

    /// The only import path in this phase. Naming it `importSynthetic` prevents
    /// a caller from accidentally treating parser success as official G2C
    /// sender authentication or a legally effective receipt.
    @discardableResult
    func importSynthetic(_ payload: OfficialDocumentImportPayload,
                         checkedAt: Date = Date()) throws -> OfficialDocumentPackage {
        let package = try OfficialDocumentPackageParser.parseSynthetic(payload,
                                                                        checkedAt: checkedAt)
        if let existing = try packages().first(where: {
            $0.envelope.applicationID == package.envelope.applicationID
        }) {
            guard existing.integrity.envelopeDigest == package.integrity.envelopeDigest else {
                throw OfficialDocumentInboxArchiveError.conflictingApplicationID(
                    package.envelope.applicationID)
            }
            // The exchange requirements call for identical repeated receipts to
            // stop here. Preserve the first receive/view timestamps.
            return existing
        }

        let target = try packageDirectory(id: package.id)
        let packages = packagesDirectory
        try FileManager.default.createDirectory(
            at: packages,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        let temporary = packages.appendingPathComponent(".incoming-\(UUID().uuidString)",
                                                        isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        defer { try? FileManager.default.removeItem(at: temporary) }

        try payload.envelope.data.write(
            to: temporary.appendingPathComponent(Self.envelopeFilename),
            options: [.atomic, .completeFileProtectionUnlessOpen])
        if let document = payload.document {
            try document.data.write(
                to: temporary.appendingPathComponent(Self.documentFilename),
                options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        if let encryptedSwitch = payload.encryptedSwitch {
            try encryptedSwitch.data.write(
                to: temporary.appendingPathComponent(Self.encryptedSwitchFilename),
                options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        try writeMetadata(package, in: temporary)
        try FileManager.default.moveItem(at: temporary, to: target)
        return package
    }

    func packages() throws -> [OfficialDocumentPackage] {
        guard FileManager.default.fileExists(atPath: packagesDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        return try urls.compactMap { url in
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                return nil
            }
            return try readMetadata(in: url)
        }.sorted { left, right in
            if left.receivedAt != right.receivedAt { return left.receivedAt > right.receivedAt }
            return left.id < right.id
        }
    }

    func package(id: String) throws -> OfficialDocumentPackage? {
        let url = try packageDirectory(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readMetadata(in: url)
    }

    @discardableResult
    func markViewed(id: String, at date: Date = Date()) throws -> OfficialDocumentPackage {
        let url = try packageDirectory(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OfficialDocumentInboxArchiveError.packageMissing
        }
        let updated = try readMetadata(in: url).markingViewed(at: date)
        try writeMetadata(updated, in: url)
        return updated
    }

    /// Test/audit hook for proving the exact source survives import. Nothing in
    /// the UI exposes these URLs to Files, Quick Look, or a share sheet.
    func sourceData(id: String, fileExtension: String) throws -> Data? {
        let filename: String
        switch fileExtension.lowercased() {
        case "en": filename = Self.envelopeFilename
        case "di": filename = Self.documentFilename
        case "esw": filename = Self.encryptedSwitchFilename
        default: return nil
        }
        let url = try packageDirectory(id: id).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private var packagesDirectory: URL {
        directory.appendingPathComponent(Self.packagesDirectoryName, isDirectory: true)
    }

    private func packageDirectory(id: String) throws -> URL {
        let bytes = Data(id.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumIdentifierUTF8Count else {
            throw OfficialDocumentInboxArchiveError.invalidIdentifier
        }
        let encoded = bytes.map { String(format: "%02x", $0) }.joined()
        return packagesDirectory.appendingPathComponent(encoded, isDirectory: true)
    }

    private func readMetadata(in directory: URL) throws -> OfficialDocumentPackage {
        try JSONDecoder().decode(
            OfficialDocumentPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent(Self.metadataFilename)))
    }

    private func writeMetadata(_ package: OfficialDocumentPackage, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(package).write(
            to: directory.appendingPathComponent(Self.metadataFilename),
            options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func purge() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
