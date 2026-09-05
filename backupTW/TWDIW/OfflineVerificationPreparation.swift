import Foundation

/// Only public issuer-wide material is fetched; no card or holder identifier
/// is needed on the verifier. A transport outage cannot become an empty list.
enum OfflineVerificationPreparation {
    static func snapshots(issuers: [TWDIWIssuer],
                          results: [String: TWDIWOnChainVerification],
                          now: Date = Date()) throws -> [OfflineIssuerTrustSnapshot] {
        guard !issuers.isEmpty else { throw OfflineIssuerTrustStoreError.registryUnavailable }
        var snapshots: [OfflineIssuerTrustSnapshot] = []
        var seen = Set<String>()
        for issuer in issuers where seen.insert(issuer.did).inserted {
            guard let result = results[issuer.did], result != .unavailable else {
                throw OfflineIssuerTrustStoreError.registryUnavailable
            }
            if case let .verified(block, transaction) = result {
                snapshots.append(OfflineIssuerTrustSnapshot(
                    issuer: issuer, blockNumber: block, transactionHash: transaction, verifiedAt: now))
            }
        }
        return snapshots
    }

    static func refreshTrust(session: URLSession = .shared) async throws -> Int {
        let issuers = try await TrustListFetcher(session: session).fetchAll()
        let results = await TWDIWOnChainVerifier(session: session).verify(issuers)
        let snapshots = try snapshots(issuers: issuers, results: results)
        try Task.checkCancellation()
        try OfflineIssuerTrustStore().replaceRegistry(with: snapshots)
        IssuerNameBook.remember(issuers)
        return snapshots.count
    }
}
