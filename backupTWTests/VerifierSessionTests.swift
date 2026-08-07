//
//  VerifierSessionTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// `OfflineVerifier.verify` is a pure function and says so: it will return
/// `verified` for the same presentation as many times as it is asked, and
/// `verifyingTwiceDoesNotConsumeTheChallenge` over there pins that deliberately.
/// The half that turns a valid presentation into a *one-time* one lives here, so
/// these are the tests for the replay defence as a user experiences it rather
/// than as a signature check.
///
/// A `final class` for the same reason `DeviceKeyLifecycleTests` is one: the
/// end-to-end tests need a Keychain tag and a credential directory that no other
/// test can touch, and `deinit` has to be able to take them away.
final class VerifierSessionTests: @unchecked Sendable {

    private let tag: String
    private let installRecordName: String
    private let installRecord: UserDefaults
    private let root: URL

    init() throws {
        let unique = UUID().uuidString
        tag = "tw.bonds.backupTW.tests.verifierSession.\(unique)"
        installRecordName = "tw.bonds.backupTW.tests.verifierSession.install.\(unique)"
        installRecord = try #require(UserDefaults(suiteName: installRecordName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifierSessionTests-\(unique)", isDirectory: true)
    }

    deinit {
        try? DeviceKey.deleteKey(tag: tag, installRecord: installRecord)
        UserDefaults.standard.removePersistentDomain(forName: installRecordName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Signing needs a reachable Keychain, which a test bundle does not always
    /// have. Same reasoning — and the same shape — as `VerifiableCredentialTests`.
    static let deviceKeyIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.verifierSession.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)) != nil
    }()

    private static let purpose = "Identity check"
    private static let now = Date(timeIntervalSince1970: 1_754_400_000)

    // MARK: - Minting

    @Test func eachCheckGetsAChallengeNoOtherCheckHas() throws {
        let session = VerifierSession()
        var seen = Set<String>()
        for _ in 0..<64 {
            seen.insert(try session.beginCheck(purpose: Self.purpose).challenge)
        }
        #expect(seen.count == 64)
    }

    /// A second `beginCheck` replaces rather than adds. The set of live
    /// challenges a verifier is holding must be at most one — a verifier who
    /// taps 「重新查驗」 twice and leaves two acceptable challenges behind has a
    /// wider replay window than the one they can see on screen.
    @Test func mintingAgainRetiresThePreviousChallenge() throws {
        let session = VerifierSession()
        let first = try session.beginCheck(purpose: Self.purpose, now: Self.now)
        let second = try session.beginCheck(purpose: Self.purpose, now: Self.now)

        #expect(first.challenge != second.challenge)
        #expect(session.pendingRequest(now: Self.now)?.challenge == second.challenge)
    }

    @Test func nothingIsOutstandingBeforeTheFirstCheckBegins() {
        #expect(VerifierSession().pendingRequest(now: Self.now) == nil)
    }

    @Test func aChallengeNobodyAnsweredEventuallyStopsBeingAccepted() throws {
        let session = VerifierSession()
        _ = try session.beginCheck(purpose: Self.purpose, now: Self.now)

        let justInside = Self.now.addingTimeInterval(VerifierSession.pendingRequestLifetime - 1)
        #expect(session.pendingRequest(now: justInside) != nil)

        let justOutside = Self.now.addingTimeInterval(VerifierSession.pendingRequestLifetime + 1)
        #expect(session.pendingRequest(now: justOutside) == nil)
        #expect(session.check(presentationJWS: "irrelevant", now: justOutside) == .noPendingRequest)
    }

    // MARK: - Spending

    /// The distinction the UI depends on. Folding "we had nothing outstanding"
    /// into `challengeMismatch` would put a sentence accusing the holder of
    /// replaying an old presentation on screen for a state that is entirely about
    /// this device.
    @Test func checkingWithNothingOutstandingIsNotReportedAsAMismatch() {
        let session = VerifierSession()
        #expect(session.check(presentationJWS: "eyJ4IjoxfQ.e30.c2ln", now: Self.now) == .noPendingRequest)
    }

    /// The load-bearing one for refusals: a challenge is spent by being answered
    /// at all, not by being answered correctly. Keeping it alive after a refusal
    /// hands an attacker unlimited attempts against a live challenge — and the
    /// refusal this app expects to see most often is a *timing* one, where the
    /// same bytes were valid ninety seconds earlier.
    @Test func aRefusedPresentationStillSpendsTheChallenge() throws {
        let session = VerifierSession()
        _ = try session.beginCheck(purpose: Self.purpose, now: Self.now)

        let first = session.check(presentationJWS: "not a presentation", now: Self.now)
        guard case .checked(let outcome) = first else {
            Issue.record("expected the request to have been outstanding")
            return
        }
        #expect(!outcome.isVerified)

        #expect(session.pendingRequest(now: Self.now) == nil)
        #expect(session.check(presentationJWS: "not a presentation", now: Self.now) == .noPendingRequest)
    }

    @Test func leavingTheScreenRetiresTheChallenge() throws {
        let session = VerifierSession()
        _ = try session.beginCheck(purpose: Self.purpose, now: Self.now)

        session.cancel()

        #expect(session.pendingRequest(now: Self.now) == nil)
        #expect(session.check(presentationJWS: "anything", now: Self.now) == .noPendingRequest)
    }

    // MARK: - End to end

    /// The whole flow the two screens perform, with a real key, a real
    /// credential, real frames and a real scan: mint → present → shard →
    /// reassemble → verify. Every module was tested against a hand-built input by
    /// its own author; this is the one that fails if the *wiring* is wrong.
    @Test(.enabled(if: VerifierSessionTests.deviceKeyIsAvailable))
    func aPresentationBuiltForThisChallengeIsAcceptedOnceAndOnlyOnce() throws {
        let session = VerifierSession()
        let request = try session.beginCheck(purpose: Self.purpose, now: Self.now)

        let jws = try presentation(answering: request)

        // Through the transport, exactly as the scanner does it — reassembled
        // from frames rather than handed over as a string, so a shard/collect
        // defect shows up here rather than at a counter.
        let frames = try QRTransport.frames(for: Data(jws.utf8))
        let collector = FrameCollector()
        var reassembled: Data?
        for frame in frames {
            if case .completed(let payload) = try collector.accept(frame) { reassembled = payload }
        }
        let complete = try #require(reassembled)
        let scanned = try #require(String(data: complete, encoding: .utf8))
        #expect(scanned == jws)

        guard case .checked(let outcome) = session.check(presentationJWS: scanned, now: Self.now) else {
            Issue.record("expected the request to have been outstanding")
            return
        }
        guard case .verified(let verified) = outcome else {
            Issue.record("expected acceptance, got \(String(describing: outcome.failure))")
            return
        }
        #expect(verified.claims.contains(DisclosedClaim(term: "name", value: "王小明")))

        // The replay. Identical bytes, same clock, well inside the freshness
        // window — refused only because the challenge is gone.
        #expect(session.check(presentationJWS: scanned, now: Self.now) == .noPendingRequest)
    }

    /// A pass always carries the sentences a green tick does not say, so no UI
    /// can be built that shows acceptance without them. Asserted on the values
    /// the result screen actually reads, not on the enum's `allCases`.
    @Test(.enabled(if: VerifierSessionTests.deviceKeyIsAvailable))
    func anAcceptedPresentationAlwaysReportsWhatItDidNotEstablish() throws {
        let session = VerifierSession()
        let request = try session.beginCheck(purpose: Self.purpose, now: Self.now)
        let jws = try presentation(answering: request)

        guard case .checked(.verified(let verified)) = session.check(presentationJWS: jws, now: Self.now) else {
            Issue.record("expected acceptance")
            return
        }
        #expect(verified.caveats.contains(.revocationNotChecked))
        #expect(verified.caveats.contains(.selfIssuedByTheHolder))
        #expect(verified.caveats.contains(.identifierIsLinkable))
        #expect(verified.caveats.contains(.noNetworkQuery))
        // Every one of them has to have something to draw. A caveat with an empty
        // message is a caveat that occupies a row and says nothing.
        for caveat in verified.caveats {
            #expect(!caveat.message.isEmpty)
        }
    }

    /// Two different checks, both live in their own sessions: the presentation
    /// built for one must not satisfy the other. This is the property that makes
    /// a photograph of somebody else's screen worthless, and it is the reason the
    /// challenge exists at all.
    @Test(.enabled(if: VerifierSessionTests.deviceKeyIsAvailable))
    func aPresentationForAnotherCheckerIsRefused() throws {
        let mine = VerifierSession()
        let theirs = VerifierSession()
        _ = try mine.beginCheck(purpose: Self.purpose, now: Self.now)
        let theirRequest = try theirs.beginCheck(purpose: Self.purpose, now: Self.now)

        let jws = try presentation(answering: theirRequest)

        guard case .checked(.rejected(let failure)) = mine.check(presentationJWS: jws, now: Self.now) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure == .challengeMismatch)
    }

    // MARK: - Fixtures

    /// Builds a presentation the way `PresentCredentialViewController` does —
    /// through `HolderPresentation`, so the production assembly path is what is
    /// under test rather than a test-only reimplementation of it.
    private func presentation(answering request: PresentationRequest) throws -> String {
        let store = try CredentialStore(directory: root.appendingPathComponent("Credentials", isDirectory: true))
        let key = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let credential = VerifiableCredential.selfIssuedNationalID(
            NationalIDModel(nationality: "中華民國（臺灣）",
                            unifiedNo: "A123456789",
                            name: "王小明",
                            birthdate: "0700101",
                            addressOfHousehold: "臺北市中正區重慶南路一段122號"),
            issuerDID: did,
            validFrom: Self.now.addingTimeInterval(-3600))
        try store.save(jws: try credential.jwsCompactSerialization(signedBy: key, issuerDID: did),
                       id: "national-id")

        let holder = HolderPresentation(store: store, loadKey: { key })
        let frames = try holder.frames(answering: request, now: Self.now)
        let collector = FrameCollector()
        for frame in frames {
            if case .completed(let payload) = try collector.accept(frame) {
                let text = try #require(String(data: payload, encoding: .utf8))
                return text
            }
        }
        throw VerifiablePresentationError.malformedCredential
    }
}
