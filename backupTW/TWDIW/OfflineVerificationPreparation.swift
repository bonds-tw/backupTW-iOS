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

    static func refreshTrust(session: URLSession = .shared,
                             progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Int {
        let issuers = try await TrustListFetcher(session: session).fetchAll()
        let results = try await TWDIWOnChainVerifier(session: session).verifyChecked(issuers, progress: progress)
        let snapshots = try snapshots(issuers: issuers, results: results)
        try Task.checkCancellation()
        try OfflineIssuerTrustStore().replaceRegistry(with: snapshots)
        IssuerNameBook.remember(issuers)
        return snapshots.count
    }

    /// Only known, local messages are displayed. Do not expose a server body,
    /// filesystem path or underlying error's arbitrary text in this screen.
    static func failureMessage(for error: Error) -> String {
        switch error {
        case TWDIWRegistryRequestError.badStatus(429):
            return NSLocalizedString("The blockchain service is limiting requests (HTTP 429). Wait a little, then save issuer trust again. Existing trust dates are unchanged.", comment: "offline preparation")
        case TWDIWRegistryRequestError.badStatus(let code):
            return String(format: NSLocalizedString("The blockchain service returned HTTP %d. Issuer trust was not updated. Try again later.", comment: "offline preparation"), code)
        case TWDIWRegistryRequestError.malformedReply:
            return NSLocalizedString("The blockchain reply was incomplete or invalid. Issuer trust was not updated. Try again later.", comment: "offline preparation")
        case TrustListFetcherError.badStatus(let code):
            return String(format: NSLocalizedString("The issuer registry returned HTTP %d. Issuer trust was not updated. Try again later.", comment: "offline preparation"), code)
        case TrustListFetcherError.emptyList:
            return NSLocalizedString("The issuer registry did not return a usable list. Issuer trust was not updated.", comment: "offline preparation")
        case TrustListFetcherError.network:
            return NSLocalizedString("The issuer registry could not be reached. Check the connection, then save issuer trust again.", comment: "offline preparation")
        case OfflineIssuerTrustStoreError.registryUnavailable:
            return NSLocalizedString("Not every issuer could be checked on the blockchain. Issuer trust was not updated. Try again later.", comment: "offline preparation")
        case let error as CircuitAssetError:
            return error.localizedDescription
        case let error as URLError where error.code == .timedOut:
            return NSLocalizedString("The blockchain check timed out. Issuer trust was not updated. Try again later.", comment: "offline preparation")
        case is URLError:
            return NSLocalizedString("The blockchain service could not be reached. Check the connection, then save issuer trust again.", comment: "offline preparation")
        default:
            return NSLocalizedString("The preparation files could not be saved. Keep the device unlocked and check its free storage before trying again.", comment: "offline preparation")
        }
    }
}
