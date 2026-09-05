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
    case registryUnavailable
}

/// File-backed issuer snapshots. One JSON document per issuer DID, protected and
/// excluded from backup under the same policy as credentials.
final class OfflineIssuerTrustStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var registryURL: URL { directory.appendingPathComponent("registry.json") }

    /// A complete refresh is authoritative, including removal of issuers. Old
    /// per-card files remain readable only until the first complete refresh.
    func replaceRegistry(with snapshots: [OfflineIssuerTrustSnapshot]) throws {
        guard Set(snapshots.map(\.issuerDID)).count == snapshots.count else {
            throw OfflineIssuerTrustStoreError.corruptedSnapshot
        }
        lock.lock()
        defer { lock.unlock() }
        try writeRegistry(snapshots)
    }

    func registrySnapshots() throws -> [OfflineIssuerTrustSnapshot]? {
        lock.lock()
        defer { lock.unlock() }
        return try readRegistry()
    }

    private func readRegistry() throws -> [OfflineIssuerTrustSnapshot]? {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let values = try? decoder.decode([OfflineIssuerTrustSnapshot].self,
                                              from: Data(contentsOf: registryURL)),
              Set(values.map(\.issuerDID)).count == values.count else {
            throw OfflineIssuerTrustStoreError.corruptedSnapshot
        }
        return values
    }

    private func writeRegistry(_ snapshots: [OfflineIssuerTrustSnapshot]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(snapshots.sorted { $0.issuerDID < $1.issuerDID })
            .write(to: registryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

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
        if var registry = try readRegistry() {
            registry.removeAll { $0.issuerDID == snapshot.issuerDID }
            registry.append(snapshot)
            try writeRegistry(registry)
            return
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path)
    }

    func snapshot(for issuerDID: String) throws -> OfflineIssuerTrustSnapshot? {
        let url = try fileURL(for: issuerDID)
        lock.lock()
        defer { lock.unlock() }
        if let registry = try readRegistry() {
            return registry.first { $0.issuerDID == issuerDID }
        }
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
