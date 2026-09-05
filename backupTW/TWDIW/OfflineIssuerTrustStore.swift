//
//  OfflineIssuerTrustStore.swift
//  backupTW
//
//  Privacy-safe evidence retained when a government card is collected.
//

import Foundation

/// The minimum evidence an offline verifier needs to decide that a third-party
/// issuer was accepted previously by both independent trust channels.
///
/// No credential identifier, holder DID, disclosure or subject field is stored
/// here. It is issuer-wide public registry material. This lets an iPad verify a
/// government card without making a request that reveals who is standing in
/// front of it, while still failing closed for an arbitrary `did:key` issuer.
struct OfflineIssuerTrustSnapshot: Codable, Equatable, Sendable {
    let issuerDID: String
    let displayName: String
    let taxID: String
    let apiUpdatedAt: Date?
    let verifiedAt: Date
    let network: String
    let contractAddress: String
    let blockNumber: String
    let transactionHash: String

    init(issuer: TWDIWIssuer,
         blockNumber: String,
         transactionHash: String,
         verifiedAt: Date) {
        issuerDID = issuer.did
        displayName = issuer.displayName
        taxID = issuer.taxID
        apiUpdatedAt = issuer.apiUpdatedAt
        self.verifiedAt = verifiedAt
        network = TWDIWOnChainVerifier.network
        contractAddress = TWDIWOnChainVerifier.registryContract
        self.blockNumber = blockNumber
        self.transactionHash = transactionHash
    }
}

enum OfflineIssuerTrustStoreError: Error, Equatable {
    case invalidIssuer
    case corruptedSnapshot
}

/// File-backed issuer snapshots. One JSON document per issuer DID, protected and
/// excluded from backup under the same policy as credentials.
final class OfflineIssuerTrustStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            self.directory = base.appendingPathComponent("OfflineIssuerTrust", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = self.directory
        try mutableDirectory.setResourceValues(values)
    }

    func save(_ snapshot: OfflineIssuerTrustSnapshot) throws {
        let url = try fileURL(for: snapshot.issuerDID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path)
    }

    func snapshot(for issuerDID: String) throws -> OfflineIssuerTrustSnapshot? {
        let url = try fileURL(for: issuerDID)
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(OfflineIssuerTrustSnapshot.self, from: data),
              snapshot.issuerDID == issuerDID else {
            throw OfflineIssuerTrustStoreError.corruptedSnapshot
        }
        return snapshot
    }

    private func fileURL(for issuerDID: String) throws -> URL {
        guard !issuerDID.isEmpty, issuerDID.utf8.count <= 4_096 else {
            throw OfflineIssuerTrustStoreError.invalidIssuer
        }
        let name = Data(issuerDID.utf8).base64URLEncodedString()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}

/// Injectable read boundary used by the pure verifier. Production reads the
/// local store; tests can provide one snapshot without touching disk.
struct OfflineIssuerTrustLookup: @unchecked Sendable {
    let find: (String) -> OfflineIssuerTrustSnapshot?

    static let unavailable = OfflineIssuerTrustLookup { _ in nil }

    static func installed() -> OfflineIssuerTrustLookup {
        guard let store = try? OfflineIssuerTrustStore() else { return .unavailable }
        return OfflineIssuerTrustLookup { did in try? store.snapshot(for: did) }
    }
}
