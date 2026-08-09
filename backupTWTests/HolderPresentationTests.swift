//
//  HolderPresentationTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// The holder's assembly path, and the one call inside it that can destroy an
/// identity if it is spelled wrong.
final class HolderPresentationTests: @unchecked Sendable {

    private let tag: String
    private let installRecordName: String
    private let installRecord: UserDefaults
    private let root: URL

    init() throws {
        let unique = UUID().uuidString
        tag = "tw.bonds.backupTW.tests.holderPresentation.\(unique)"
        installRecordName = "tw.bonds.backupTW.tests.holderPresentation.install.\(unique)"
        installRecord = try #require(UserDefaults(suiteName: installRecordName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HolderPresentationTests-\(unique)", isDirectory: true)
    }

    deinit {
        try? DeviceKey.deleteKey(tag: tag, installRecord: installRecord)
        UserDefaults.standard.removePersistentDomain(forName: installRecordName)
        try? FileManager.default.removeItem(at: root)
    }

    static let deviceKeyIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.holderPresentation.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)) != nil
    }()

    private static let now = Date(timeIntervalSince1970: 1_754_400_000)

    private func store() throws -> CredentialStore {
        try CredentialStore(directory: root.appendingPathComponent("Credentials", isDirectory: true))
    }

    private func makeRequest() throws -> PresentationRequest {
        try PresentationRequest(challenge: "AAAAAAAAAAAAAAAAAAAAAA",
                                purpose: "Identity check",
                                createdAt: Self.now)
    }

    // MARK: - DeviceKey.load

    /// The reason `DeviceKey.load` exists. `loadOrCreate` on this path would mint
    /// an identity for a device that holds none — at a counter, for a user who
    /// tapped 「出示證件」 and has nothing to show.
    @Test(.enabled(if: HolderPresentationTests.deviceKeyIsAvailable))
    func loadingAKeyThatDoesNotExistDoesNotCreateOne() throws {
        #expect(try DeviceKey.load(tag: tag, installRecord: installRecord) == nil)
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)
    }

    @Test(.enabled(if: HolderPresentationTests.deviceKeyIsAvailable))
    func loadingReturnsTheKeyThisInstallAlreadyHas() throws {
        let created = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        let loaded = try #require(try DeviceKey.load(tag: tag, installRecord: installRecord))
        #expect(loaded.publicKeyX963 == created.publicKeyX963)
    }

    /// A key left behind by a previous install is reported absent, exactly as
    /// `loadOrCreate` treats it — but it is *left alone* rather than replaced,
    /// because a screen that reads state must not rewrite it.
    @Test(.enabled(if: HolderPresentationTests.deviceKeyIsAvailable))
    func aKeyFromAPreviousInstallIsNeitherReturnedNorDestroyed() throws {
        let orphaned = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        let reinstalledName = installRecordName + ".reinstalled"
        let reinstalled = try #require(UserDefaults(suiteName: reinstalledName))
        defer { UserDefaults.standard.removePersistentDomain(forName: reinstalledName) }

        #expect(try DeviceKey.load(tag: tag, installRecord: reinstalled) == nil)

        // Untouched: the original install's marker still resolves to the same key.
        let stillThere = try #require(try DeviceKey.load(tag: tag, installRecord: installRecord))
        #expect(stillThere.publicKeyX963 == orphaned.publicKeyX963)
    }

    // MARK: - Refusals

    @Test func aDeviceWithNoCredentialHasNothingToPresent() throws {
        let holder = HolderPresentation(store: try store(), loadKey: { nil })
        let request = try makeRequest()
        #expect(try holder.storedCredentialID() == nil)
        #expect(throws: HolderPresentationError.noCredentialStored) {
            _ = try holder.frames(answering: request, now: Self.now)
        }
    }

    /// Credential present, key gone — the state an identity reset leaves if the
    /// credentials survive it, and the state a crash between key generation and
    /// the install marker's flush produces. Reported as its own case so the user
    /// is told to create the document again, not that they never had one.
    @Test func aCredentialWithoutItsKeyIsReportedAsALostIdentity() throws {
        let store = try store()
        try store.save(jws: "eyJhbGciOiJFUzI1NiJ9.e30.c2ln", id: "national-id")
        let holder = HolderPresentation(store: store, loadKey: { nil })
        let request = try makeRequest()

        #expect(throws: HolderPresentationError.identityUnavailable) {
            _ = try holder.frames(answering: request, now: Self.now)
        }
    }

    /// Both refusals reach the screen as a sentence. An error whose
    /// `errorDescription` is nil renders as Foundation's "The operation couldn't
    /// be completed", which is what this app's failure screens must never say.
    @Test func everyRefusalHasSomethingToShowTheUser() {
        #expect(HolderPresentationError.noCredentialStored.errorDescription?.isEmpty == false)
        #expect(HolderPresentationError.identityUnavailable.errorDescription?.isEmpty == false)
    }

    // MARK: - Assembly

    /// The frames carry the exact signed bytes and nothing else. Deflation,
    /// base45 and sharding all happen in between, and any of them mangling a byte
    /// would leave a presentation that reassembles into an invalid signature at
    /// the far end — where it would look like a forgery.
    @Test(.enabled(if: HolderPresentationTests.deviceKeyIsAvailable))
    func theFramesReassembleIntoThePresentationThatWasSigned() throws {
        let (holder, key) = try holderWithCredential()
        let request = try makeRequest()

        let frames = try holder.frames(answering: request, now: Self.now)
        #expect(!frames.isEmpty)

        let collector = FrameCollector()
        var payload: Data?
        // Reversed, because the carousel does not guarantee the verifier sees
        // frame 0 first and `FrameCollector` is order-free by design.
        for frame in frames.reversed() {
            if case .completed(let complete) = try collector.accept(frame) { payload = complete }
        }
        let complete = try #require(payload)
        let jws = try #require(String(data: complete, encoding: .utf8))

        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let outcome = OfflineVerifier.verify(presentationJWS: jws, against: request, now: Self.now)
        guard case .verified(let verified) = outcome else {
            Issue.record("expected acceptance, got \(String(describing: outcome.failure))")
            return
        }
        #expect(verified.holder == did)
    }

    /// The presentation is stamped with the holder's clock, so signing it at a
    /// different instant has to produce different bytes — otherwise a
    /// presentation could be replayed a day later and still look fresh.
    @Test(.enabled(if: HolderPresentationTests.deviceKeyIsAvailable))
    func presentingLaterProducesADifferentDocument() throws {
        let (holder, _) = try holderWithCredential()
        let request = try makeRequest()

        let early = try holder.frames(answering: request, now: Self.now)
        let late = try holder.frames(answering: request, now: Self.now.addingTimeInterval(120))
        #expect(early != late)
    }

    /// Key and credential from two different identities. The check belongs to
    /// `VerifiablePresentation.create`, and this asserts that this type routes
    /// through it rather than signing whatever it was handed — a presentation
    /// that binds someone else's credential to this device's key is the exact
    /// attack holder binding exists to stop.
    @Test(.enabled(if: HolderPresentationTests.deviceKeyIsAvailable))
    func aCredentialIssuedToSomebodyElseIsNotPresented() throws {
        let store = try store()
        let key = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        // The W3C-CCG published P-256 test vector — a real did:key that this
        // device certainly does not hold the private half of.
        let strangerDID = "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv"
        let credential = VerifiableCredential.nationalID(
            NationalIDModel(nationality: "中華民國（臺灣）", unifiedNo: "A123456789",
                            name: "王小明", birthdate: "0700101", addressOfHousehold: "臺北市"),
            issuerDID: strangerDID,
            validFrom: Self.now.addingTimeInterval(-3600))
        try store.save(jws: try credential.jwsCompactSerialization(signedBy: key, issuerDID: strangerDID),
                       id: "national-id")

        let holder = HolderPresentation(store: store, loadKey: { key })
        let request = try makeRequest()
        #expect(throws: VerifiablePresentationError.credentialSubjectMismatch) {
            _ = try holder.frames(answering: request, now: Self.now)
        }
    }

    // MARK: - Fixtures

    private func holderWithCredential() throws -> (HolderPresentation, DeviceKey) {
        let store = try store()
        let key = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let credential = VerifiableCredential.nationalID(
            NationalIDModel(nationality: "中華民國（臺灣）",
                            unifiedNo: "A123456789",
                            name: "王小明",
                            birthdate: "0700101",
                            addressOfHousehold: "臺北市中正區重慶南路一段122號"),
            issuerDID: did,
            validFrom: Self.now.addingTimeInterval(-3600))
        try store.save(jws: try credential.jwsCompactSerialization(signedBy: key, issuerDID: did),
                       id: "national-id")
        return (HolderPresentation(store: store, loadKey: { key }), key)
    }
}
