import Foundation
import Testing
@testable import backupTW

struct OfflinePreparationTests {
    private func issuer(_ id: String) -> TWDIWIssuer {
        TWDIWIssuer(did: id, displayName: "Synthetic issuer", displayNameEnglish: "",
                    taxID: "", issuerMetadataBaseURL: nil, serviceBaseURL: nil, reportsOnChainAnchor: true)
    }

    @Test func unavailableRegistryDoesNotBecomeTrustedOrEmpty() throws {
        let entry = issuer("did:key:test")
        #expect(throws: OfflineIssuerTrustStoreError.registryUnavailable) {
            try OfflineVerificationPreparation.snapshots(issuers: [entry], results: [:])
        }
        #expect(throws: OfflineIssuerTrustStoreError.registryUnavailable) {
            try OfflineVerificationPreparation.snapshots(issuers: [entry], results: [entry.did: .unavailable])
        }
        let mismatched = try OfflineVerificationPreparation.snapshots(
            issuers: [entry], results: [entry.did: .mismatch])
        #expect(mismatched.isEmpty)
    }

    @Test func fullRefreshRemovesOldIssuerAndNeverFallsBackToCollectionFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OfflineIssuerTrustStore(directory: directory)
        let entry = issuer("did:key:test")
        let snapshot = OfflineIssuerTrustSnapshot(issuer: entry, blockNumber: "0x1",
                                                  transactionHash: "0x2", verifiedAt: Date(timeIntervalSince1970: 100))
        try store.save(snapshot)
        #expect(try store.snapshot(for: entry.did) == snapshot)
        try store.replaceRegistry(with: [])
        #expect(try store.snapshot(for: entry.did) == nil)
        try store.save(snapshot) // A newly verified collection updates the registry.
        #expect(try store.snapshot(for: entry.did) == snapshot)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("registry.json"))
        #expect(throws: OfflineIssuerTrustStoreError.corruptedSnapshot) {
            try store.snapshot(for: entry.did)
        }
    }

    @Test func onlyIndependentMatchesAreSavedAndDuplicatesCannotTrap() throws {
        let a = issuer("did:key:a"), b = issuer("did:key:b")
        let now = Date(timeIntervalSince1970: 100)
        let snapshots = try OfflineVerificationPreparation.snapshots(
            issuers: [a, a, b], results: [a.did: .verified(blockNumber: "1", transactionHash: "2"),
                                       b.did: .developmentSandbox], now: now)
        #expect(snapshots.map(\.issuerDID) == [a.did])
        #expect(snapshots.first?.verifiedAt == now)
    }

    @Test func missingOfflineKeysFailBeforeAnyDownloadOrRepair() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparer = try AgePredicateCircuitAssetPreparer(directory: directory)
        await #expect(throws: AgePredicateProofError.offlineAssetsMissing) {
            try await preparer.prepare(.verifier, allowDownloads: false)
        }
    }

    @Test func requestFreshnessIsRecheckedAtVerificationTime() throws {
        let now = Date(timeIntervalSince1970: 1_788_600_000)
        let request = try AgePredicateProofRequest(purpose: "test", credentialSource: .selfIssued, now: now)
        try request.validateFreshness(now: now.addingTimeInterval(AgePredicateProofRequest.lifetime))
        #expect(throws: AgePredicateProofError.staleRequest) {
            try request.validateFreshness(now: now.addingTimeInterval(AgePredicateProofRequest.lifetime + 1))
        }
    }
}
